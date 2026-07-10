require_relative "lib/active_mutator/version"

Gem::Specification.new do |spec|
  spec.name = "active_mutator"
  spec.version = ActiveMutator::VERSION
  spec.summary = "Mutation testing for Ruby, built on Prism"
  spec.description = "Mutation testing for Ruby and Rails. Uses Prism-based source-span " \
                      "mutations (no unparser), coverage-mapped test selection, and a " \
                      "fork-per-mutant kill pipeline. Scopes to changed methods for a fast " \
                      "dev loop, or to a diff for CI. Includes an incremental coverage " \
                      "baseline and a committed acceptance ledger for equivalent mutants."
  spec.authors = ["Daniel John"]
  spec.license = "MIT"
  spec.homepage = "https://github.com/drj613/active_mutator"
  spec.required_ruby_version = ">= 3.2"
  spec.files = Dir["lib/**/*.rb", "exe/*", "LICENSE*", "README*"]
  spec.bindir = "exe"
  spec.executables = ["active_mutator"]
  spec.metadata = {
    "rubygems_mfa_required" => "true",
    "homepage_uri" => "https://github.com/drj613/active_mutator",
    "source_code_uri" => "https://github.com/drj613/active_mutator",
    "changelog_uri" => "https://github.com/drj613/active_mutator/blob/main/CHANGELOG.md",
    "bug_tracker_uri" => "https://github.com/drj613/active_mutator/issues"
  }
  spec.add_dependency "prism", ">= 0.30"
  spec.add_dependency "rspec-core", ">= 3.12" # worker + baseline_hooks require it at runtime
  spec.add_development_dependency "rspec", "~> 3.13"
end
