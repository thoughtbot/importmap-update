# frozen_string_literal: true

require_relative "test_helper"
require "config"
require "tempfile"

class ConfigTest < Minitest::Test
  Config = Importmap::Update::Config

  # ---- defaults ----

  def test_default_returns_the_baked_in_defaults
    config = Config.default
    assert_equal 1, config.version
    assert_equal 10, config.open_pull_requests_limit
    assert_equal "importmap-updates", config.branch_prefix
    assert_equal "", config.commit_message.prefix
    assert_equal %w[dependencies javascript importmap], config.labels
    assert_empty config.reviewers
  end

  def test_default_grouping_buckets_are_present_with_correct_strategies
    g = Config.default.grouping
    assert_equal :individual, g[:security].strategy
    assert_equal :grouped, g[:patch].strategy
    assert_equal :grouped, g[:minor].strategy
    assert_equal :individual, g[:major].strategy
  end

  def test_bucket_predicate_methods
    g = Config.default.grouping
    assert_predicate g[:patch], :grouped?
    refute_predicate g[:patch], :individual?
    assert_predicate g[:major], :individual?
    refute_predicate g[:major], :grouped?
  end

  def test_missing_file_returns_defaults
    config = Config.load("/nonexistent/path/config.yml")
    assert_equal Config.default.to_h, config.to_h
  end

  def test_nil_path_returns_defaults
    config = Config.load(nil)
    assert_equal Config.default.to_h, config.to_h
  end

  def test_empty_file_returns_defaults
    # `YAML.safe_load_file` returns nil on empty files; we treat nil as {}.
    Tempfile.create(["empty", ".yml"]) do |f|
      f.flush
      config = Config.load(f.path)
      assert_equal Config.default.to_h, config.to_h
    end
  end

  # ---- merge behavior ----

  def test_minimal_config_deep_merges_into_defaults
    config = Config.load(fixture_path("config_minimal.yml"))
    # User changed only patch; the other buckets should keep their defaults.
    assert_equal :individual, config.grouping[:patch].strategy
    assert_equal :grouped, config.grouping[:minor].strategy
    assert_equal :individual, config.grouping[:security].strategy
    assert_equal :individual, config.grouping[:major].strategy
    # Other top-level fields unchanged.
    assert_equal 10, config.open_pull_requests_limit
    assert_equal "importmap-updates", config.branch_prefix
  end

  def test_full_config_overrides_every_field
    config = Config.load(fixture_path("config_full.yml"))
    assert_equal 5, config.open_pull_requests_limit
    assert_equal %w[deps js], config.labels
    assert_equal %w[thoughtbot/web], config.reviewers
    assert_equal "chore(js-deps)", config.commit_message.prefix
    assert_equal "js-deps", config.branch_prefix
  end

  def test_dashed_keys_are_normalized_to_underscored
    # Dependabot users will reflexively write `open-pull-requests-limit`.
    # Accept both styles.
    config = Config.load(fixture_path("config_dashed_keys.yml"))
    assert_equal 3, config.open_pull_requests_limit
    assert_equal "ipm-updates", config.branch_prefix
    assert_equal "deps", config.commit_message.prefix
  end

  # ---- validation: top-level shape ----

  def test_rejects_unknown_top_level_key
    err = assert_raises(Config::ConfigError) do
      load_inline("version: 1\nnonsense: true\n")
    end
    assert_includes err.message, "unknown top-level key"
    assert_includes err.message, "nonsense"
  end

  def test_rejects_non_mapping_root
    err = assert_raises(Config::ConfigError) do
      load_inline("- just\n- a\n- list\n")
    end
    assert_includes err.message, "must be a mapping"
  end

  def test_rejects_wrong_version
    err = assert_raises(Config::ConfigError) do
      load_inline("version: 2\n")
    end
    assert_includes err.message, "version must be 1"
  end

  # ---- validation: grouping ----

  def test_rejects_unknown_grouping_bucket
    err = assert_raises(Config::ConfigError) do
      load_inline(<<~YAML)
        version: 1
        grouping:
          patch:
            strategy: grouped
          urgent:
            strategy: individual
      YAML
    end
    assert_includes err.message, "urgent"
    assert_includes err.message, "Valid buckets"
  end

  def test_rejects_typoed_strategy_value
    err = assert_raises(Config::ConfigError) do
      load_inline(<<~YAML)
        version: 1
        grouping:
          patch:
            strategy: groupedd
      YAML
    end
    assert_includes err.message, "grouping.patch.strategy"
    assert_includes err.message, "grouped, individual"
  end

  def test_rejects_unknown_key_inside_bucket
    err = assert_raises(Config::ConfigError) do
      load_inline(<<~YAML)
        version: 1
        grouping:
          patch:
            strategy: grouped
            interval: weekly
      YAML
    end
    assert_includes err.message, "grouping.patch"
    assert_includes err.message, "interval"
  end

  # ---- validation: limit, labels, reviewers, branch, commit prefix ----

  def test_rejects_zero_pull_request_limit
    err = assert_raises(Config::ConfigError) do
      load_inline("version: 1\nopen_pull_requests_limit: 0\n")
    end
    assert_includes err.message, "positive integer"
  end

  def test_rejects_non_integer_pull_request_limit
    err = assert_raises(Config::ConfigError) do
      load_inline("version: 1\nopen_pull_requests_limit: \"ten\"\n")
    end
    assert_includes err.message, "positive integer"
  end

  def test_rejects_non_string_in_labels
    err = assert_raises(Config::ConfigError) do
      load_inline(<<~YAML)
        version: 1
        labels:
          - ok
          - 123
      YAML
    end
    assert_includes err.message, "labels"
  end

  def test_accepts_empty_commit_message_prefix
    config = load_inline(<<~YAML)
      version: 1
      commit_message:
        prefix: ""
    YAML
    assert_equal "", config.commit_message.prefix
  end

  def test_rejects_branch_prefix_with_spaces
    err = assert_raises(Config::ConfigError) do
      load_inline("version: 1\nbranch_prefix: \"has spaces\"\n")
    end
    assert_includes err.message, "branch_prefix"
  end

  def test_constructor_is_private
    # Force callers through Config.load / Config.default so validation always runs.
    assert_raises(NoMethodError) { Config.new({}) }
  end

  # ---- helpers ----

  private

  def fixture_path(name)
    File.join(TestHelpers::FIXTURE_DIR, name)
  end

  def load_inline(yaml_string)
    Tempfile.create(["config", ".yml"]) do |f|
      f.write(yaml_string)
      f.flush
      return Config.load(f.path)
    end
  end
end
