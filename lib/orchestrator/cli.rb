require 'formatador'
require 'optparse'
require 'ostruct'

module Orchestrator

  class Cli

    def self.parse(args)
      options = OpenStruct.new
      options.args = Object.new

      parser = OptionParser.new
      parser.banner = "Usage: #{$0} [options]"

      options.config = Orchestrator::Settings
      parser.on( '--config PATH', String, 'Path to settings yaml' ) do |config|
        options.config = config
        options.args.instance_variable_set(:@config,config)
      end

      options.name = nil
      parser.on( '--name NAME', 'Name of the cron job to run' ) do |name|
        options.name = name
        options.args.instance_variable_set(:@name,name)
      end

      options.statefile = nil
      parser.on( '--statefile PATH', String, 'Path to state file yaml' ) do |statefile|
        options.statefile = statefile
        options.args.instance_variable_set(:@statefile,statefile)
      end

      options.reset = false
      parser.on( '--reset', 'Delete state file if it exists' ) { options.reset = true }

      options.resume = false
      parser.on( '--resume', 'Resume from statefile if it exists' ) { options.resume = true }

      options.kill = false
      parser.on( '--kill', 'Kill running task based on statefile pid then lock can not be acquired' ) { options.kill = true }

      options.wait = false
      parser.on( '--wait', 'Wait until already running task based on statefile pid finish running' ) { options.wait = true }

      parser.on( '--args ARGS,', Array, 'extra args for interpolation as arg1=val1,arg2=val2,...]' ) do |extra_args|
        extra_args.each do |extra_arg|
          arg,val = extra_arg.split('=')
          options.args.instance_variable_set("@#{arg}".to_sym,val)
        end
      end

      options.verbose = false
      parser.on( '--verbose') { options.verbose = true }

      options.email = true
      parser.on( '--no-email') { options.email = false }

      options.sms = true
      parser.on( '--no-sms') { options.sms = false }

      parser.on( '-h', '--help', 'Display this screen' ) { puts parser; exit }

      parser.parse!(args)

      unless options.name
        puts parser
        exit 1 
      end

      if options.reset && options.resume
        Formatador.display_line("[red]ERROR[/]: --resume or --reset options are mutualy exclusive")
        exit 1
      end

      if options.wait && options.kill
        Formatador.display_line("[red]ERROR[/]: --wait or --kill options are mutualy exclusive")
        exit 1
      end

      options
    end

  end

end
