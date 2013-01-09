require 'popen4'
require 'pony'
require 'yaml'
require 'timeout'
require 'formatador'
require 'fileutils'

module Orchestrator

  class Task

    def initialize(options)
      @mutex = Mutex.new
      Thread.abort_on_exception = true
      @log = ''

      @options = options

      invalid("config file #{config} does not exists") unless File.exist?(@options.config)

      @settings = YAML.load_file(@options.config)
      invalid("no task job #{@options.name} is defined in settings file") unless @settings['orchestrator'].has_key?(@options.name)

      invalid("no statedir is defined in settings file") if @settings['orchestrator'][@options.name]['save'] && !@settings['orchestrator'].has_key?('statedir')
      unless @options.statefile
        if @settings['orchestrator'][@options.name]['save']
          @options.statefile = @settings['orchestrator']['statedir'] + "/" + @options.name
          FileUtils.mkdir_p(@settings['orchestrator']['statedir'])
        end
      end
      @state = (@options.statefile && File.exist?(@options.statefile) && !@options.reset) ? YAML.load_file(@options.statefile) : @settings['orchestrator'][@options.name]

      @options.email = false unless @state.has_key?('email')
      @options.email_on_success = (@options.email and @state['email'].has_key?('on_success')) ? @state['email']['on_success'] : true

      @options.sms = false unless @state.has_key?('sms')
      @options.sms_on_success = (@options.sms and @state['sms'].has_key?('on_success')) ? @state['sms']['on_success'] : false
    end

    def invalid(reason)
      Formatador.display_line("[red]ERROR[/]: #{reason}")
      exit 1
    end

    def save_state
      if @options.statefile
        @mutex.synchronize do
          File.open(@options.statefile, "w") {|f| YAML.dump(@state, f)}
        end
      end
    end

    def interpolate_command(command)
      command.gsub(/:::([^:]*):::/) do
        match = $1
        case match
        when /^ENV\./
          env = match["ENV.".length..-1]
          invalid("command interpolation failed no such env variable - #{env}") unless ENV[env]
          ENV[env]
        when /^ARG\./
          arg = match["ARG.".length..-1]
          invalid("command interpolation failed no such arg - #{arg}") unless @options.args.instance_variable_defined?("@#{arg}".to_sym)
          @options.args.instance_variable_get("@#{arg}".to_sym)
        when /^EXEC\./
          exec = match["EXEC.".length..-1]
          result = nil
          begin
            result = IO.popen(exec)
          rescue
            invalid("command interpolation failed to exec - #{exec}")
          end
          invalid("command interpolation exec exit with non zero status - #{exec}") unless $?.to_i == 0
          result.readline.delete("\n")
        else
          invalid("command interpolation failed not valid parameter - :::#{match}:::")
        end
      end
    end

    def validate_command(command,error_prefix)
      if command.is_a?(String)
         command = { 'command' => interpolate_command(command) }
      elsif command.is_a?(Hash)
        invalid(error_prefix + " command is invalid") unless command.has_key?('command') && command['command'].is_a?(String)
        command['command'] = interpolate_command(command['command'])
      else
        invalid(error_prefix + " is invalid")
      end
      command
    end

    def validate_config
      @state['failure_handler'] = validate_command(@state['failure_handler'], 'task failure handler') if @state.has_key?('failure_handler')
      if @state.has_key?('email')
        invalid("config email recipients is missing or invalid") unless @state['email'].has_key?('recipients') && @state['email']['recipients'].is_a?(String) || @state['email']['recipients'].is_a?(Array)
        invalid("config email from is missing or invalid") unless @state['email'].has_key?('from') && @state['email']['from'].is_a?(String)
      end
      if @state.has_key?('sms')
        invalid("task sms recipients is missing") unless @state['sms'].has_key?('recipients') && @state['sms']['recipients'].is_a?(String) || @state['sms']['recipients'].is_a?(Array)
        invalid("task sms from is missing") unless @state['sms'].has_key?('from') && @state['sms']['from'].is_a?(String)
      end
      invalid("task description is missing or invalid") unless @state.has_key?('description') && @state['description'].is_a?(String)
      invalid("task save must be boolean") if @state.has_key?('save') && !!@state['save'] != @state['save']
      @state['save'] = false unless @state.has_key?('save')
      invalid("task steps is missing") unless @state.has_key?('steps')
      invalid("task steps must be array") unless @state['steps'].is_a?(Array)
      @state['steps'].each do |step|
        invalid("task step is not hash") unless step.is_a?(Hash)
        invalid("task step has no type") unless step.has_key?('type') && step['type'].is_a?(String)
        invalid("task step type #{step['type']} is invalid") unless [:parallel,:sequential].find_index(step['type'].to_sym)
        invalid("task step scripts is missing or invalid") unless step.has_key?('scripts') && step['scripts'].is_a?(Array)
        step['failure_handler'] = validate_command(step['failure_handler'], 'task failure handler') if step.has_key?('failure_handler')
        step['scripts'].each_index do |index|
          step['scripts'][index] = validate_command(step['scripts'][index], 'task step script')
        end
      end
    end

    def fail
      run_script(@failure_handler) if @failure_handler
      run_script(@state['failure_handler']) if @state.has_key?('failure_handler')

      Pony.mail(
        :to => @state['email']['recipients'],
        :from => @state['email']['from'],
        :subject => "#{@state['description']} - [FAILED]",
        :body => @log
      ) if @options.email

      Pony.mail(
        :to => @state['sms']['recipients'],
        :from => @state['sms']['from'],
        :subject => "#{@state['description']} - [FAILED]",
       :body => @state['sms']['auth']
      ) if @options.sms

      exit 1
    end

    def notify
      Pony.mail(
        :to => @state['email']['recipients'],
        :from => @state['email']['from'],
        :subject => "#{@state['description']} - [OK]",
        :body => @log
      ) if @options.email and @options.email_on_success

      Pony.mail(
        :to => @state['sms']['recipients'],
        :from => @state['sms']['from'],
        :subject => "#{@state['description']} - [OK]",
        :body => @state['sms']['auth']
      ) if @options.sms and @options.sms_on_success
    end

    def run_script(script)
      result = ""
      error = ""

      timeout = script.has_key?('timeout') ? script['timeout'].to_i : @timeout

      script['status'] = 'STARTED'
      save_state

      #  start = Time.now

      begin
        Timeout::timeout(timeout) do
          status = POpen4::popen4(script['command']) do |stdout, stderr, stdin, pid|
            result = stdout.read.strip
            error = stderr.read.strip
          end
          script['status'] = (status.nil? or status.exitstatus != 0) ? 'FAILED' : 'OK'
        end
      rescue Timeout::Error
        script['status'] = 'TIMEOUT'
      end

      save_state

      #  runtime = Time.now - start
      #  runtime = runtime > 60 ? runtime/60 : runtime

      @mutex.synchronize do
        output = <<-EOF

Running: #{script['command']} - #{script['status']}
============ STDOUT ============
#{result}
============ STDERR ============
#{error}
================================
EOF

        @log += output
        puts output if @options.verbose
      end

      script['status'] == 'OK'
    end

    def thread_wrapper(i,script)
      failures = 0

      loop do
        begin
          @statuses[i] = run_script(script)
        rescue Exception => e
          script['status'] = 'EXCEPTION'
          save_state
          @statuses[i] = false
          @mutex.synchronize do
            output = <<-EOF

Thread - (#{script['command']})
Died due to following exception:
#{e.inspect}
#{e.backtrace}
EOF
            @log += output
            puts output if @options.verbose
          end
        end

        break if @statuses[i]

        failures += 1
        break if @retries < failures
        sleep @retry_delay
      end

      @threads.delete(i)
      fail if @on_failure == :die and not @statuses[i]
    end

    def run
      validate_config
      save_state

      @state['steps'].each do |step|
        @statuses = Array.new

        @timeout = step.has_key?('timeout') ? step['timeout'].to_i : 0
        @retries = step.has_key?('retries') ? step['retries'].to_i : 0
        @retry_delay = step.has_key?('retry_delay') ? step['retry_delay'] : 0
        @on_week_days = step.has_key?('on_week_days') ? step['on_week_days'].map{|d| "#{d}?".downcase.to_sym} : [ :sunday?, :monday?, :tuesday?, :wednesday?, :thursday?, :friday?, :saturday? ]
        @on_month_days = step.has_key?('on_month_days') ? step['on_month_days'] : (1..31).to_a
        @failure_handler = step.has_key?('failure_handler') ? step['failure_handler'] : nil

        if step['type'].to_sym == :parallel and @on_week_days.map {|d| Time.now.send(d) }.find_index(true) and @on_month_days.find_index(Time.now.mday)
          #Parallel
          interval = step.has_key?('sleep') ? step['sleep'] : 1
          parallel_factor = step.has_key?('parallel') ? step['parallel'] : 1
          @on_failure = step.has_key?('on_failure') ? step['on_failure'].to_sym : :finish

          @threads = Hash.new
          index = 0
          running_threads = 0

          step['scripts'].each_index do |index|
            next if step['scripts'][index].has_key?('status') and step['scripts'][index]['status'] == 'OK'
            loop do
              @mutex.synchronize do
                running_threads = @threads.length
              end
              break if @on_failure == :wait and @statuses.find_index(false)
              if parallel_factor > running_threads
                @threads[index] = Thread.new { thread_wrapper(index, step['scripts'][index]) }
                break
              end
              sleep interval
            end
          end
          loop do
            @mutex.synchronize do
              running_threads = @threads.length
            end
            break if running_threads == 0
            sleep interval
          end
          fail if @on_failure != :ignore and @statuses.find_index(false)

        elsif step['type'].to_sym == :sequential and @on_week_days.map {|d| Time.now.send(d) }.find_index(true) and @on_month_days.find_index(Time.now.mday)
          #Sequential
          @on_failure = step.has_key?('on_failure') ? step['on_failure'].to_sym : :die

          step['scripts'].each_index do |index|
            failures = 0
            next if step['scripts'][index].has_key?('status') and step['scripts'][index]['status'] == 'OK'
            loop do
              @statuses[index] = run_script(step['scripts'][index])
              break if @statuses[index]
              failures += 1
              break if failures > @retries
              sleep @retry_delay
            end
            fail if not @statuses[index] and @on_failure == :die
          end
          fail if @on_failure != :ignore and @statuses.find_index(false)
        end
      end

      FileUtils.rm_f(@options.statefile) if @options.statefile
      notify
    end

  end

end
