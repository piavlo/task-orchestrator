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

      @children = {}

      @options = options

      @defaults = {}
      @defaults[:envs] = Object.new
      @defaults[:args] = Object.new

      bail("config file #{config} does not exists") unless File.exist?(@options.config)

      @settings = YAML.load_file(@options.config)
      bail("no task job #{@options.name} is defined in settings file") unless @settings['orchestrator'].has_key?(@options.name)

      bail("no statedir is defined in settings file") if @settings['orchestrator'][@options.name]['save'] && !@settings['orchestrator'].has_key?('statedir')
      unless @options.statefile
        if @settings['orchestrator'][@options.name]['save']
          @options.statefile = @settings['orchestrator']['statedir'] + "/" + @options.name
          FileUtils.mkdir_p(@settings['orchestrator']['statedir'])
        end
      end

      if @options.statefile
        if File.exist?(@options.statefile)
          File.open(@options.statefile, "r") do |file|
            @got_lock = file.flock( File::LOCK_NB | File::LOCK_EX )
          end
          unless @got_lock
            if @options.kill
              @state = YAML.load_file(@options.statefile)
              begin
                Process.kill("TERM", @state['pid']) if @state.has_key?('pid')
              rescue Errno::ESRCH
              end
              sleep 0.1
              File.open(@options.statefile, "r") do |file|
                @got_lock = file.flock( File::LOCK_NB | File::LOCK_EX )
              end
            end
            unless @got_lock
              unless @options.wait
                bail("The state file #{@options.statefile} is already locked by other process")
              else
                Formatador.display_line("[yellow]WARN[/]: Blocking until already running process ends")
                File.open(@options.statefile, "r") do |file|
                  @got_lock = file.flock( File::LOCK_EX )
                end
              end
            end
          end
        end

        if File.exist?(@options.statefile)
          if @options.reset
            @state = @settings['orchestrator'][@options.name]
          elsif @options.resume
            @state = YAML.load_file(@options.statefile)
          else
            Formatador.display_line("[red]ERROR[/]: statefile #{@options.statefile} already exists, use --resume or --reset")
            exit 1
          end
        else
          @state = @settings['orchestrator'][@options.name]
        end

        @state['pid'] = Process.pid

        @statefile_handle = File.open(@options.statefile, "w")
        @statefile_handle.flock( File::LOCK_NB | File::LOCK_EX )
        @statefile_handle.sync = true
        ### @statefile_handle.close_on_exec = true
        Signal.trap("TERM") do
          @children.each do |pid, command|
            begin
              Process.kill("TERM", pid)
              puts "KILLED #{pid}: #{command}\n" if @options.verbose
              @log += "KILLED #{pid}: #{command}\n"
            rescue Errno::ESRCH
            end
          end
          puts "KILLED ORCHESTRATOR\n" if @options.verbose
          @log += "KILLED ORCHESTRATOR\n"
          fail
        end
      else
        @state = @settings['orchestrator'][@options.name]
      end

      @options.email = false unless @state.has_key?('email')
      @options.email_on_success = (@options.email and @state['email'].has_key?('on_success')) ? @state['email']['on_success'] : true

      @options.sms = false unless @state.has_key?('sms')
      @options.sms_on_success = (@options.sms and @state['sms'].has_key?('on_success')) ? @state['sms']['on_success'] : false
    end

    def bail(reason)
      Formatador.display_line("[red]ERROR[/]: #{reason}")
      exit 1
    end

    def invalid(reason)
      Formatador.display_line("[red]ERROR[/]: #{reason}")
      FileUtils.rm_f(@options.statefile) if @options.statefile
      exit 1
    end

    def save_state
      if @options.statefile
        @mutex.synchronize do
          unless File.exist?(@options.statefile)
            @statefile_handle.close
            @statefile_handle = File.open(@options.statefile, "w")
            @statefile_handle.flock( File::LOCK_NB | File::LOCK_EX )
            @statefile_handle.sync = true
          end
          @statefile_handle.rewind
          YAML.dump(@state, @statefile_handle)
          @statefile_handle.truncate(@statefile_handle.pos)
        end
      end
    end

    def interpolate_command(command,pattern=/^(ENV|ARG|EXEC)\./)
      command = command.to_s if command.is_a?(Integer)
      command.gsub(/:::([^:]*):::/) do
        match = $1
        invalid("interpolation type is not valid in this context - :::#{match}:::") if match !~ pattern and match =~ /^(ENV|ARG|EXEC)\./

        case match
        when /^LOOP\.\d$/
          require 'pp'
          invalid("command interpolation failed not nested loop type step") unless @nested_loop_param
          i = match.match(/^LOOP\.(\d)$/)[1].to_i
          @nested_loop_param[i] ? @nested_loop_param[i] : invalid("command interpolation failed unexisting nesting #{match}")
        when /^LOOP$/
          invalid("command interpolation failed not loop type step") unless @loop_param
          @loop_param
        when /^ENV\./
          env = match["ENV.".length..-1]
          invalid("command interpolation failed no such env variable - #{env}") if !ENV[env] and !@defaults[:envs].instance_variable_defined?("@#{env}")
          ENV[env] ? ENV[env] : @defaults[:envs].instance_variable_get("@#{env}")
        when /^ARG\./
          arg = match["ARG.".length..-1]
          invalid("command interpolation failed no such arg - #{arg}") if !@options.args.instance_variable_defined?("@#{arg}") and !@defaults[:args].instance_variable_defined?("@#{arg}")
          @options.args.instance_variable_defined?("@#{arg}") ? @options.args.instance_variable_get("@#{arg}") : @defaults[:args].instance_variable_get("@#{arg}")
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
        invalid(error_prefix + " is missing command attribute") unless command.has_key?('command')
        ['command', 'ok_handler', 'failure_handler', 'retry_handler', 'condition'].each do |attribute|
          if command.has_key?(attribute)
            invalid(error_prefix + " #{attribute} attribute is invalid") unless command[attribute].is_a?(String)
            command[attribute] = interpolate_command(command[attribute])
          end
        end
      else
        invalid(error_prefix + " has invalid format")
      end
      command
    end

    def validate_config
      @state['ok_handler'] = validate_command(@state['ok_handler'], 'task success handler') if @state.has_key?('ok_handler')
      @state['failure_handler'] = validate_command(@state['failure_handler'], 'task failure handler') if @state.has_key?('failure_handler')
      if @state.has_key?('email')
        invalid("config email recipients is missing or invalid") unless @state['email'].has_key?('recipients') && @state['email']['recipients'].is_a?(String) || @state['email']['recipients'].is_a?(Array)
        invalid("config email from is missing or invalid") unless @state['email'].has_key?('from') && @state['email']['from'].is_a?(String)
        @state['email']['from'] = interpolate_command(@state['email']['from'])
      end
      if @state.has_key?('sms')
        invalid("task sms recipients is missing") unless @state['sms'].has_key?('recipients') && @state['sms']['recipients'].is_a?(String) || @state['sms']['recipients'].is_a?(Array)
        invalid("task sms from is missing") unless @state['sms'].has_key?('from') && @state['sms']['from'].is_a?(String)
        @state['sms']['from'] = interpolate_command(@state['sms']['from'])
      end
      if @state.has_key?('defaults')
        invalid("defaults must be hash") unless @state['defaults'].is_a?(Hash)
        [:envs, :args].each do |type|
          if @state['defaults'].has_key?(type.to_s)
            invalid("default envs must be hash") unless @state['defaults'][type.to_s].is_a?(Hash)
            @state['defaults'][type.to_s].each do|key,value|
              value = '' unless value
              if not value.is_a?(String) and not value.is_a?(Integer)
                invalid("default value for #{type} #{key} is invalid")
              end
              @defaults[type].instance_variable_set("@#{key}",interpolate_command(value,/^EXEC\./))
            end
          end
        end
      end
      invalid("task description is missing or invalid") unless @state.has_key?('description') && @state['description'].is_a?(String)
      @state['description'] = interpolate_command(@state['description'])
      invalid("task save must be boolean") if @state.has_key?('save') && !!@state['save'] != @state['save']
      @state['save'] = false unless @state.has_key?('save')
      invalid("task steps is missing") unless @state.has_key?('steps')
      invalid("task steps must be array") unless @state['steps'].is_a?(Array)
      @state['steps'].each do |step|
        invalid("task step is not hash") unless step.is_a?(Hash)
        invalid("task step has no type") unless step.has_key?('type') && step['type'].is_a?(String)
        invalid("task step type #{step['type']} is invalid") unless [:parallel,:sequential].find_index(step['type'].to_sym)
        invalid("task step scripts is missing or invalid") unless step.has_key?('scripts') && step['scripts'].is_a?(Array)
        if step.has_key?('loop')
          invalid("task step loop is not array") unless step['loop'].is_a?(Array)
          scripts = []
          step['loop'].each do |item|
            @loop_param = item
            step['scripts'].each_index do |index|
              script = Marshal.load(Marshal.dump(step['scripts'][index]))
              scripts << validate_command(script, 'task step looped script')
            end
            @loop_param = nil
          end
          step['scripts'] = scripts
          step.delete('loop')
        elsif step.has_key?('nested_loop')
          invalid("task step nested loop is not array") unless step['nested_loop'].is_a?(Array)
          step['nested_loop'].each do |loop|
            invalid("task step nested loop is not array of arrays") unless loop.is_a?(Array)
          end
          scripts = []
          loops = step['nested_loop'].inject([[]]) do |tuples, array|
            tuples.inject([]) do |agg, tuple|
              array.each do |x|
                agg << [*tuple, x]
              end
              agg
            end
          end
          loops.each do |item|
            @nested_loop_param = item
            step['scripts'].each_index do |index|
              script = Marshal.load(Marshal.dump(step['scripts'][index]))
              scripts << validate_command(script, 'task step nested loop script')
            end
            @nested_loop_param = nil
          end
          step['scripts'] = scripts
          step.delete('nested_loop')
        else
          step['scripts'].each_index do |index|
            step['scripts'][index] = validate_command(step['scripts'][index], 'task step script')
          end
        end
        step['failure_handler'] = validate_command(step['failure_handler'], 'task failure handler') if step.has_key?('failure_handler')
        step['retry_handler'] = validate_command(step['retry_handler'], 'task retry handler') if step.has_key?('retry_handler')
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
      run_script(@state['ok_handler']) if @state.has_key?('ok_handler')
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

    def run_command(command,timeout)
      result = ""
      error = ""

      #  start = Time.now
      
      status = 'STARTED'
      child = nil
      begin
        Timeout::timeout(timeout) do
          status = POpen4::popen4(command) do |stdout, stderr, stdin, pid|
            @children[pid] = command
            child = pid
            result = stdout.read.strip
            error = stderr.read.strip
          end
          status = (status.nil? or status.exitstatus != 0) ? 'FAILED' : 'OK'
        end
      rescue Timeout::Error
        status = 'TIMEOUT'
        if child
          begin
            `/bin/ps --ppid #{child} -o pid=`.split(/\n/).each{|p| Process.kill("TERM", p)}
            Process.kill("TERM", child)
            result += "\nKILLED #{child}: #{command}\n"
          rescue Errno::ESRCH
          end
        end
      end

      #  runtime = Time.now - start
      #  runtime = runtime > 60 ? runtime/60 : runtime

      @mutex.synchronize do
        @children.delete(child) if child

        output = <<-EOF

Running: #{command} - #{status}
============ STDOUT ============
#{result}
============ STDERR ============
#{error}
================================
EOF

        @log += output
        puts output if @options.verbose
      end

      return status
    end

    def run_post_script_handlers(script,status)
      handler = nil
      if status
        handler = 'ok_handler' if script.has_key?('ok_handler')
      else
        handler = 'failure_handler' if script.has_key?('failure_handler')
      end
      if handler
        timeout = script.has_key?('timeout') ? script['timeout'].to_i : @timeout
        run_command(script[handler],timeout)
      end
    end

    def run_script(script)
      timeout = script.has_key?('timeout') ? script['timeout'].to_i : @timeout

      script['status'] = 'STARTED'
      save_state
      script['status'] = run_command(script['command'],timeout)
      save_state
    
      return script['status'] == 'OK'
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
        if script.has_key?('retry_handler')
          timeout = script.has_key?('timeout') ? script['timeout'].to_i : @timeout
          run_command(script['retry_handler'],timeout)
        end
        sleep @retry_delay
      end

      @threads.delete(i)
      run_post_script_handlers(script,@statuses[i])
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
            next if step['scripts'][index].has_key?('status') and ['OK','SKIPED'].find_index(step['scripts'][index]['status'])
            if step['scripts'][index].has_key?('condition') and 'OK' != run_command(step['scripts'][index]['condition'], 0)
              step['scripts'][index]['status'] = "SKIPED"
              save_state
              next
            end
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
            next if step['scripts'][index].has_key?('status') and ['OK','SKIPED'].find_index(step['scripts'][index]['status'])
            if step['scripts'][index].has_key?('condition') and 'OK' != run_command(step['scripts'][index]['condition'], 0)
              step['scripts'][index]['status'] = "SKIPED"
              save_state
              next
            end
            loop do
              @statuses[index] = run_script(step['scripts'][index])
              break if @statuses[index]
              failures += 1
              break if failures > @retries
              if step['scripts'][index].has_key?('retry_handler')
                timeout = step['scripts'][index].has_key?('timeout') ? step['scripts'][index]['timeout'].to_i : @timeout
                run_command(step['scripts'][index]['retry_handler'],timeout)
              end
              sleep @retry_delay
            end
            run_post_script_handlers(step['scripts'][index],@statuses[index])
            fail if not @statuses[index] and @on_failure == :die
          end
          fail if @on_failure != :ignore and @statuses.find_index(false)
        end
      end

      @statefile_handle.close unless @statefile_handle.closed?
      FileUtils.rm_f(@options.statefile) if @options.statefile
      notify
    end

  end

end
