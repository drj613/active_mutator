module ActiveMutator
  # RSpec example ids look like "./spec/a_spec.rb[1:2:3]": the file, then the
  # scoped path of the example. The first number is the top-level group, and a
  # shared example adds a second bracket. Anything else parses to nil, so a bad
  # id is never mistaken for a group.
  module ExampleId
    PATTERN = /\A(?<file>.+?)(?<scope>\[(?<top>\d+)(?::\d+)*\](?:\[\d+(?::\d+)*\])*)\z/

    # [absolute file, top-level group number], or nil. ./spec/a_spec.rb,
    # spec/a_spec.rb, and its absolute path all name the same file.
    def self.group_key(id)
      match = PATTERN.match(id) if id.is_a?(String)
      [File.expand_path(match[:file]), match[:top]] if match
    end

    # The id with its file made absolute, for comparing spellings; or nil.
    def self.normalize(id)
      match = PATTERN.match(id) if id.is_a?(String)
      "#{File.expand_path(match[:file])}#{match[:scope]}" if match
    end
  end
end
