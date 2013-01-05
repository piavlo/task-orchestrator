$LOAD_PATH.unshift File.expand_path("../lib", __FILE__)
require "orchestrator/version"
 
task :build do
  system "gem build task-orchestrator.gemspec"
end
 
task :release => :build do
  system "gem push task-orchestrator-#{Orchestrator::VERSION}"
end
