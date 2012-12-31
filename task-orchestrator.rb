#!/usr/bin/env ruby

require 'rubygems'
require 'yaml'
require 'pony'
require 'popen4'
require 'formatador'
require 'optparse'
require 'pp'

config = File.dirname(__FILE__) + '/../.settings'
$name = nil
$email = true
$email_on_success = true
$sms = true
$sms_on_success = false
$verbose = false
$log = String.new

opts = OptionParser.new
opts.banner = "Usage: #{$0} [options]"
opts.on( '--name NAME', 'Name of the cron job to run' ) { |n| $name = n }
opts.on( '--config PATH', 'Path to settings yaml' ) { |c| config = c }
opts.on( '--verbose') { $verbose = true }
opts.on( '--no-email') { $email = false }
opts.on( '--no-sms') { $sms = false }
opts.on( '-h', '--help', 'Display this screen' ) { puts opts; exit }
opts.parse!

if $name.nil?
  puts opts
  exit 1
end

$settings = YAML.load_file(config)
unless $settings['orchestrator'].has_key?($name)
 Formatador.display_line("[red]ERROR[/]: no task job #{$name} is defined in settings file")
 exit 1
end

$email = false unless $settings['orchestrator'][$name].has_key?('email')
$email_on_success = false if $email and $settings['orchestrator'][$name]['email'].has_key?('on_success') and not $settings['orchestrator'][$name]['email']['on_success']

$sms = false unless $settings['orchestrator'][$name].has_key?('sms')
$sms_on_success = true if $sms and $settings['orchestrator'][$name]['sms'].has_key?('on_success') and $settings['orchestrator'][$name]['sms']['on_success']

def fail
  system "#{$settings['orchestrator'][$name]['failure_handler']} #{$settings['orchestrator'][$name]['failure_handler_args']}" if $settings['orchestrator'][$name].has_key?('failure_handler')

  Pony.mail(
    :to => $settings['orchestrator'][$name]['email']['recipients'],
    :from => $settings['orchestrator'][$name]['email']['from'],
    :subject => "#{$settings['orchestrator'][$name]['name']} - [FAILED]",
    :body => $log
  ) if $email

  Pony.mail(
    :to => $settings['orchestrator'][$name]['sms']['recipients'],
    :from => $settings['orchestrator'][$name]['sms']['from'],
    :subject => "#{$settings['orchestrator'][$name]['name']} - [FAILED]",
    :body => $settings['orchestrator'][$name]['sms']['auth']
  ) if $sms

  exit 1
end

$mutex = Mutex.new
Thread.abort_on_exception = true

def run_script(script)
  result = ""
  error = ""

  start = Time.now

  status = POpen4::popen4(script) do |stdout, stderr, stdin, pid|
    result = stdout.read.strip
    error = stderr.read.strip
  end

  runtime = Time.now - start
  runtime = runtime > 60 ? runtime/60 : runtime

  summary = "OK"  
  summary = "FAILED" if status.nil? or status.exitstatus != 0

  $mutex.synchronize do
    
    output = <<-EOF

Runing: #{script} - #{summary}
============ STDOUT ============
#{result}
============ STDERR ============
#{error}
================================
EOF
    $log += output
    puts output if $verbose
  end

  return false if status.nil? or status.exitstatus != 0
  return true
end

def thread_wrapper(i,script)
  failures = 0

  loop do
    begin
      $statuses[i] = run_script(script)
    rescue Exception => e
      $statuses[i] = false
      $mutex.synchronize do
        output = <<-EOF

Thread - (#{script})
Died due to following exception:
#{e.inspect}
#{e.backtrace}
EOF
        $log += output
        puts output if $verbose
      end
    end

    break if $statuses[i]

    failures += 1
    break if $retries < failures
    sleep $retry_delay
  end

  $threads.delete(i)
  fail if $on_failure == :die and not $statuses[i]
end

$settings['orchestrator'][$name]['steps'].each do |step|
  if step.is_a?(Hash) and step.has_key?('type')
    $statuses = Array.new

    step.has_key?('retries') ? $retries = step['retries'].to_i : $retries = 0
    step.has_key?('retry_delay') ? $retry_delay = step['retry_delay'] : $retry_delay = 0
    step.has_key?('on_week_days') ? $on_week_days = step['on_week_days'].map{|d| "#{d}?".downcase.to_sym} : $on_week_days = [ :sunday?, :monday?, :tuesday?, :wednesday?, :thursday?, :friday?, :saturday? ]
    step.has_key?('on_month_days') ? $on_month_days = step['on_month_days'] : $on_month_days = x=(1..31).to_a

    if step['type'].to_sym == :parallel and step.has_key?('scripts') and $on_week_days.map {|d| Time.now.send(d) }.find_index(true) and $on_month_days.find_index(Time.now.mday)
      #Parallel

      step.has_key?('sleep') ? interval = step['sleep'] : interval = 1
      step.has_key?('on_failure') ? $on_failure = step['on_failure'].to_sym : $on_failure = :finish
      step.has_key?('parallel') ? parallel_factor = step['parallel'] : parallel_factor = 1

      $threads = Hash.new
      index = 0
      running_threads = 0

      step['scripts'].each_index do |index|
        loop do
          $mutex.synchronize do
            running_threads = $threads.length
          end
          break if $on_failure == :wait and $statuses.find_index(false)
          if parallel_factor > running_threads
            $threads[index] = Thread.new { thread_wrapper(index,step['scripts'][index]) }
            break
          end
          sleep interval
        end
      end
      loop do
        $mutex.synchronize do
            running_threads = $threads.length
        end
        break if running_threads == 0
        sleep interval
      end
      fail if $on_failure != :ignore and $statuses.find_index(false)
    elsif step['type'].to_sym == :sequential and step.has_key?('scripts') and $on_week_days.map {|d| Time.now.send(d) }.find_index(true) and $on_month_days.find_index(Time.now.mday)
      #Sequential

      step.has_key?('on_failure') ? $on_failure = step['on_failure'].to_sym : $on_failure = :die

      step['scripts'].each_index do |index|
        failures = 0
        loop do
          $statuses[index] = run_script(step['scripts'][index])
          break if $statuses[index]
          failures += 1
          break if failures > $retries
          sleep $retry_delay
        end
        fail if not $statuses[index] and $on_failure == :die
      end
      fail if $on_failure != :ignore and $statuses.find_index(false)
    end
  end
end

Pony.mail(
  :to => $settings['orchestrator'][$name]['email']['recipients'],
  :from => $settings['orchestrator'][$name]['email']['from'],
  :subject => "#{$settings['orchestrator'][$name]['name']} - [OK]",
  :body => $log
) if $email and $email_on_success

Pony.mail(
  :to => $settings['orchestrator'][$name]['sms']['recipients'],
  :from => $settings['orchestrator'][$name]['sms']['from'],
  :subject => "#{$settings['orchestrator'][$name]['name']} - [OK]",
  :body => $settings['orchestrator'][$name]['sms']['auth']
) if $sms and $sms_on_success

