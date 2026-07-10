require "active_mutator"

Dir[File.join(__dir__, "support", "**", "*.rb")].sort.each { |f| require f }

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.order = :random
  # Slow suites are opt-in:
  config.filter_run_excluding :integration unless ENV["ACTIVE_MUTATOR_INTEGRATION"]
  config.filter_run_excluding :e2e unless ENV["ACTIVE_MUTATOR_E2E"]
  config.filter_run_excluding :rails_e2e unless ENV["ACTIVE_MUTATOR_RAILS_E2E"]
end
