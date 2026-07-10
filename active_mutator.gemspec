require_relative "lib/active_mutator/version"

Gem::Specification.new do |spec|
  spec.name = "active_mutator"
  spec.version = ActiveMutator::VERSION
  spec.summary = "Mutation testing for Ruby, built on Prism"
  spec.description = "Open-source mutation testing with source-span mutations, coverage-based test selection, and a fork-pool kill pipeline. Rails-first."
  spec.authors = ["Daniel John"]
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"
  spec.files = Dir["lib/**/*.rb", "exe/*", "LICENSE*", "README*"]
  spec.bindir = "exe"
  spec.executables = ["active_mutator"]
  spec.add_dependency "prism", ">= 0.30"
  spec.add_dependency "rspec-core", ">= 3.12" # worker + baseline_hooks require it at runtime
  spec.add_development_dependency "rspec", "~> 3.13"
end
