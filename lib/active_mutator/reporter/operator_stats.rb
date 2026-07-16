module ActiveMutator
  module Reporter
    # Per-operator noise signal (issue #20): equivalent_rate =
    # survived / (killed + survived). Every :survived result is covered by
    # construction (uncovered mutants never reach the scheduler), so this is
    # the covered-survivor rate. It deliberately conflates true equivalents
    # with weak assertions — it is an aggregate signal, not a score.
    module OperatorStats
      def self.call(results)
        results.group_by { |r| r.mutation.edit.operator }.to_h do |operator, group|
          killed = group.count { |r| r.status == :killed }
          survived = group.count { |r| r.status == :survived }
          denominator = killed + survived
          rate = denominator.zero? ? 0.0 : (survived.to_f / denominator).round(3)
          [operator, { "killed" => killed, "survived" => survived, "equivalent_rate" => rate }]
        end
      end
    end
  end
end
