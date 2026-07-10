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
require_relative "open_mutator/operators/call_swap"
require_relative "open_mutator/operators/negation_removal"
require_relative "open_mutator/mutation"
require_relative "open_mutator/analysis"
require_relative "open_mutator/engine"
require_relative "open_mutator/coverage_map"
require_relative "open_mutator/baseline"
require_relative "open_mutator/inserter"
require_relative "open_mutator/worker"
require_relative "open_mutator/result"
require_relative "open_mutator/work_item"
require_relative "open_mutator/scheduler"
require_relative "open_mutator/reporter/terminal"
require_relative "open_mutator/reporter/json"
