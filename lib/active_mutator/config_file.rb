require "yaml"

module ActiveMutator
  # Project config file, layered UNDER CLI flags: CLI.parse seeds its option
  # defaults from this before OptionParser runs, so any flag given on the
  # command line wins. Strict on unknown keys and types — a typo silently
  # ignored would be a config that silently doesn't apply.
  class ConfigFile
    FILENAME = ".active_mutator.yml"

    FORMATS = %w[terminal json stryker-json github].freeze

    KEYS = {
      "jobs" => :integer,
      "format" => :format,
      "timeout_factor" => :number,
      "timeout_floor" => :number,
      "browser_boot_seconds" => :number,
      "fail_at" => :number,
      "exclude" => :string_list,
      "serial_patterns" => :string_list,
      "requires" => :string_list,
      "preload_helper" => :preload_helper
    }.freeze

    def self.load(root)
      path = File.join(root, FILENAME)
      return {} unless File.exist?(path)

      data = parse(path)
      return {} if data.nil?
      raise Error, "#{FILENAME}: top level must be a mapping" unless data.is_a?(Hash)

      data.to_h do |key, value|
        validator = KEYS[key]
        raise Error, "#{FILENAME}: unknown config key: #{key}" unless validator

        [key.to_sym, coerce(key, validator, value)]
      end
    end

    def self.parse(path)
      YAML.safe_load_file(path)
    rescue Psych::SyntaxError => e
      raise Error, "#{FILENAME}: #{e.message}"
    end

    def self.coerce(key, validator, value)
      case validator
      when :integer
        raise Error, "#{FILENAME}: #{key} must be an integer" unless value.is_a?(Integer)
        value
      when :number
        raise Error, "#{FILENAME}: #{key} must be a number" unless value.is_a?(Numeric)
        value.to_f
      when :format
        unless FORMATS.include?(value)
          raise Error, "#{FILENAME}: format must be one of #{FORMATS.join(", ")}"
        end
        value.tr("-", "_").to_sym
      when :string_list
        unless value.is_a?(Array) && value.all?(String)
          raise Error, "#{FILENAME}: #{key} must be a list of strings"
        end
        value
      when :preload_helper
        return :none if value == false
        raise Error, "#{FILENAME}: preload_helper must be a path or false" unless value.is_a?(String)
        value
      end
    end
  end
end
