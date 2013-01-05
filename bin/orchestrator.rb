#!/usr/bin/env ruby

unless $:.include?(File.dirname(__FILE__) + '/../lib/')
  $: << File.dirname(__FILE__) + '/../lib'
end

require 'orchestrator'

options = Orchestrator::Cli.parse(ARGV)
task = Orchestrator::Task.new(options)
task.run
