lib = File.expand_path('../lib/', __FILE__)
$:.unshift lib unless $:.include?(lib)

require "orchestrator/version"
 
Gem::Specification.new do |s|
  s.name        = "task-orchestrator.gemspec"
  s.version     = Orchestrator::VERSION
  s.platform    = Gem::Platform::RUBY
  s.authors     = ["Alexander Piavlo"]
  s.email       = ["lolitushka@gmail.com"]
  s.homepage    = "http://github.com/piavlo/task-orchestrator"
  s.summary     = "Simple task orchestration framework"
  s.description = "Simple task orchestration framework driven by Yaml config files"
  s.license     = 'MIT'
  s.has_rdoc    = false 


  s.add_dependency('pony')
  s.add_dependency('popen4')
  s.add_dependency('formatador')

  s.add_development_dependency('rake')

  s.files         = Dir.glob("{bin,lib,examples}/**/*") + %w(task-orchestrator.gemspec LICENSE README.md)
  s.executables   = Dir.glob('bin/**/*').map { |file| File.basename(file) }
  s.test_files    = nil
  s.require_paths = ['lib']
end
