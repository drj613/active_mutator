require "prism"

require_relative "open_mutator/version"

module OpenMutator
  Error = Class.new(StandardError)
  BaselineFailed = Class.new(Error)
end

require_relative "open_mutator/edit"
require_relative "open_mutator/splicer"
