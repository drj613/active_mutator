module ActiveMutator
  # Tiny subject-expression grammar for --subject:
  #   Foo::Bar#baz  exact          Foo::Bar   all methods of the constant
  #   Foo::Bar*     namespace      Foo::Bar#* instance-only   Foo::Bar.* singleton-only
  class SubjectMatcher
    def initialize(expression)
      @regexp = compile(expression)
    end

    def match?(name) = @regexp.match?(name)

    private

    def compile(expr)
      case expr
      when /\A(.+)([#.])\*\z/ then /\A#{Regexp.escape($1)}#{Regexp.escape($2)}[^#.]+\z/
      when /\A(.+)\*\z/       then /\A#{Regexp.escape($1)}/
      when /[#.]/             then /\A#{Regexp.escape(expr)}\z/
      else                         /\A#{Regexp.escape(expr)}[#.][^#.]+\z/
      end
    end
  end
end
