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
      parser.on( '--config [PATH]', 'Path to settings yaml' ) do |config|
        options.config = config
        options.args.instance_variable_set(:@config,config)
      end

      options.statefile = nil
      options.name = nil
      parser.on( '--name NAME', 'Name of the cron job to run' ) do |name|
        options.name = name
        options.args.instance_variable_set(:@name,name)
      end

      parser.on( '--statefile PATH', 'Path to state file yaml' ) do |statefile|
        options.statefile = statefile
        options.args.instance_variable_set(:@statefile,statefile)
      end

      options.reset = false
      parser.on( '--reset', 'Do not use state file if it exists' ) { |reset| options.reset = true }

      parser.on( '--args ARGS,', 'extra args for interpolation as arg1=val1[,arg2=val2[]]' ) do |a|
        a.split(',').each do |x|
          arg,val = x.split('=')
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
        puts opts
        exit 1 
      end

      options
    end

  end

end
