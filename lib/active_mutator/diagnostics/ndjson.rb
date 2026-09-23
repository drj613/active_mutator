require "json"

module ActiveMutator
  module Diagnostics
    # --events FILE: every event as one JSON object per line. The public,
    # versioned contract (docs/guides/diagnostics.md): new fields may appear
    # under v1; a rename or removal bumps VERSION. The IO is sync, so each
    # line reaches the OS as it's written and a SIGKILLed run still leaves
    # everything up to the kill.
    class Ndjson
      VERSION = 1

      def initialize(io)
        @io = io
        @io.sync = true
      end

      def call(event)
        line = { "v" => VERSION, "event" => event.type.to_s,
                 "t" => event.at.utc.strftime("%Y-%m-%dT%H:%M:%S.%LZ"), "elapsed" => event.elapsed.round(3) }
        @io.write("#{JSON.generate(line.merge(event.fields.transform_keys(&:to_s)))}\n")
      end
    end
  end
end
