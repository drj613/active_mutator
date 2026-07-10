require "prism"

require_relative "open_mutator/version"

module OpenMutator
  Error = Class.new(StandardError)
  BaselineFailed = Class.new(Error)
end

require_relative "open_mutator/edit"
require_relative "open_mutator/splicer"
require_relative "open_mutator/subject"
require_relative "open_mutator/subject_finder"
require_relative "open_mutator/operators/base"
require_relative "open_mutator/operators/conditional_boundary"
require_relative "open_mutator/operators/condition_forcing"
require_relative "open_mutator/operators/logical_operator"
require_relative "open_mutator/operators/literal"
require_relative "open_mutator/operators/statement_deletion"
require_relative "open_mutator/operators/early_return"
