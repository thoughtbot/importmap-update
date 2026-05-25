# frozen_string_literal: true

require "yaml"

module Importmap
  module Update
    # Loads and validates the YAML config file for the action.
    #
    # Usage:
    #
    #   config = Config.load(".github/importmap-updates.yml")
    #   config.grouping.fetch(:patch).strategy   # => :grouped
    #   config.open_pull_requests_limit          # => 10
    #
    # If the file doesn't exist, the baked-in defaults are returned —
    # users can drop the action into a repo with zero config and get
    # sensible behavior.
    #
    # Validation is strict on shape (unknown keys raise, so typos like
    # `strategy: groupedd` are caught early) but lenient on missing keys
    # (every field falls back to a default).
    class Config
      ConfigError = Class.new(StandardError)

      VALID_STRATEGIES = %i[grouped individual].freeze

      Bucket = Data.define(:strategy) do
        def grouped?
          strategy == :grouped
        end

        def individual?
          strategy == :individual
        end
      end

      CommitMessage = Data.define(:prefix)

      attr_reader :version,
        :grouping,
        :open_pull_requests_limit,
        :labels,
        :reviewers,
        :commit_message,
        :branch_prefix

      # ---- public construction ----

      def self.load(path)
        raw = if path && File.exist?(path)
          YAML.safe_load_file(path, permitted_classes: [], aliases: false) || {}
        else
          {}
        end
        raise ConfigError, "config root must be a mapping, got #{raw.class}" unless raw.is_a?(Hash)
        new(deep_merge(DEFAULTS, symbolize(raw)))
      end

      def self.default
        new(DEFAULTS)
      end

      def to_h
        {
          version: version,
          grouping: grouping.transform_values { |b| {strategy: b.strategy} },
          open_pull_requests_limit: open_pull_requests_limit,
          labels: labels,
          reviewers: reviewers,
          commit_message: {prefix: commit_message.prefix},
          branch_prefix: branch_prefix
        }
      end

      # ---- defaults (the source of truth) ----

      BUCKET_NAMES = %i[security patch minor major].freeze

      DEFAULTS = {
        version: 1,
        grouping: {
          security: {strategy: :individual},
          patch: {strategy: :grouped},
          minor: {strategy: :grouped},
          major: {strategy: :individual}
        },
        open_pull_requests_limit: 10,
        labels: %w[dependencies javascript importmap],
        reviewers: [],
        commit_message: {prefix: ""},
        branch_prefix: "importmap-updates"
      }.freeze

      private_class_method :new

      def initialize(hash)
        validate!(hash)
        @version = hash[:version]
        @grouping = hash[:grouping].transform_values { |b| Bucket.new(strategy: b[:strategy]) }
        @open_pull_requests_limit = hash[:open_pull_requests_limit]
        @labels = hash[:labels].dup.freeze
        @reviewers = hash[:reviewers].dup.freeze
        @commit_message = CommitMessage.new(prefix: hash[:commit_message][:prefix])
        @branch_prefix = hash[:branch_prefix]
      end

      # ---- validation ----

      ALLOWED_TOP_LEVEL_KEYS = DEFAULTS.keys.freeze

      def validate!(hash)
        unknown = hash.keys - ALLOWED_TOP_LEVEL_KEYS
        raise ConfigError, "unknown top-level key(s): #{unknown.join(", ")}" if unknown.any?

        unless hash[:version] == 1
          raise ConfigError, "version must be 1, got #{hash[:version].inspect}"
        end

        validate_grouping!(hash[:grouping])
        validate_limit!(hash[:open_pull_requests_limit])
        validate_string_array!(hash[:labels], "labels")
        validate_string_array!(hash[:reviewers], "reviewers")
        validate_commit_message!(hash[:commit_message])
        validate_branch_prefix!(hash[:branch_prefix])
      end

      def validate_grouping!(grouping)
        raise ConfigError, "grouping must be a mapping" unless grouping.is_a?(Hash)

        unknown_buckets = grouping.keys - BUCKET_NAMES
        if unknown_buckets.any?
          raise ConfigError, "unknown grouping bucket(s): #{unknown_buckets.join(", ")}. " \
                             "Valid buckets are: #{BUCKET_NAMES.join(", ")}"
        end

        grouping.each do |bucket_name, bucket|
          path = "grouping.#{bucket_name}"
          raise ConfigError, "#{path} must be a mapping" unless bucket.is_a?(Hash)

          unknown_keys = bucket.keys - [:strategy]
          raise ConfigError, "#{path} has unknown key(s): #{unknown_keys.join(", ")}" if unknown_keys.any?

          strategy = bucket[:strategy]
          unless VALID_STRATEGIES.include?(strategy)
            raise ConfigError, "#{path}.strategy must be one of #{VALID_STRATEGIES.join(", ")}, " \
                               "got #{strategy.inspect}"
          end
        end
      end

      def validate_limit!(limit)
        unless limit.is_a?(Integer) && limit >= 1
          raise ConfigError, "open_pull_requests_limit must be a positive integer, got #{limit.inspect}"
        end
      end

      def validate_string_array!(value, name)
        raise ConfigError, "#{name} must be an array" unless value.is_a?(Array)
        bad = value.reject { |v| v.is_a?(String) }
        raise ConfigError, "#{name} must contain only strings; got non-string #{bad.first.inspect}" if bad.any?
      end

      def validate_commit_message!(cm)
        raise ConfigError, "commit_message must be a mapping" unless cm.is_a?(Hash)
        unknown = cm.keys - [:prefix]
        raise ConfigError, "commit_message has unknown key(s): #{unknown.join(", ")}" if unknown.any?
        unless cm[:prefix].is_a?(String)
          raise ConfigError, "commit_message.prefix must be a string"
        end
      end

      def validate_branch_prefix!(prefix)
        unless prefix.is_a?(String) && !prefix.empty? && !prefix.include?(" ")
          raise ConfigError, "branch_prefix must be a non-empty string without spaces, got #{prefix.inspect}"
        end
      end

      # ---- helpers ----

      # Recursively converts string keys to symbols. Values are left as-is
      # except: strings under :grouping.*.strategy are converted to symbols
      # (so users write `strategy: grouped`, not `strategy: :grouped`).
      def self.symbolize(value)
        case value
        when Hash
          value.each_with_object({}) do |(k, v), acc|
            sym_key = k.is_a?(String) ? k.tr("-", "_").to_sym : k
            acc[sym_key] = case sym_key
            when :grouping
              symbolize_grouping(v)
            when :commit_message
              symbolize(v)
            else
              v
            end
          end
        else
          value
        end
      end

      def self.symbolize_grouping(grouping)
        return grouping unless grouping.is_a?(Hash)
        grouping.each_with_object({}) do |(bucket_name, bucket), acc|
          bucket_sym = bucket_name.is_a?(String) ? bucket_name.to_sym : bucket_name
          acc[bucket_sym] = if bucket.is_a?(Hash)
            bucket.each_with_object({}) do |(k, v), inner|
              key_sym = k.is_a?(String) ? k.to_sym : k
              # strategy values come in as strings from YAML; turn them into symbols
              # so the rest of the codebase can pattern-match cleanly.
              inner[key_sym] = (key_sym == :strategy && v.is_a?(String)) ? v.to_sym : v
            end
          else
            bucket
          end
        end
      end

      def self.deep_merge(base, override)
        base.merge(override) do |_key, base_val, override_val|
          if base_val.is_a?(Hash) && override_val.is_a?(Hash)
            deep_merge(base_val, override_val)
          else
            override_val
          end
        end
      end
    end
  end
end
