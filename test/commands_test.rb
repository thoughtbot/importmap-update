# frozen_string_literal: true

require_relative "test_helper"
require "commands"

class CommandsTest < Minitest::Test
  Commands = Importmap::Update::Commands

  # ---- ShellRunner ----

  def test_shell_runner_captures_stdout
    result = Commands::ShellRunner.new.run("echo", "hello world")
    assert_equal "hello world\n", result.stdout
    assert_predicate result, :success?
    assert_equal 0, result.exit_code
  end

  def test_shell_runner_captures_stderr_and_failure
    # `sh -c` lets us write to stderr cleanly without depending on a
    # specific binary's behavior.
    result = Commands::ShellRunner.new.run("sh", "-c", "echo oops 1>&2; exit 3")
    assert_equal "oops\n", result.stderr
    assert_equal 3, result.exit_code
    refute_predicate result, :success?
  end

  def test_shell_runner_bang_raises_on_non_zero_exit
    err = assert_raises(Commands::CommandError) do
      Commands::ShellRunner.new.run!("sh", "-c", "echo nope 1>&2; exit 1")
    end
    assert_equal 1, err.result.exit_code
    assert_includes err.message, "exited 1"
    assert_includes err.message, "nope"
  end

  def test_shell_runner_argv_is_safe_from_shell_metacharacters
    # argv-style invocation must not interpret `;` as a command separator.
    # If it did, this test would attempt to delete a file.
    result = Commands::ShellRunner.new.run("echo", "a; rm -rf /b")
    assert_equal "a; rm -rf /b\n", result.stdout
  end

  # ---- FixtureRunner: literal matching ----

  def test_fixture_runner_returns_recorded_result_for_exact_argv_match
    runner = Commands::FixtureRunner.new
    runner.add(
      pattern: ["bin/importmap", "outdated"],
      stdout: "| Package | Current | Latest |\n"
    )
    result = runner.run("bin/importmap", "outdated")
    assert_equal "| Package | Current | Latest |\n", result.stdout
    assert_predicate result, :success?
  end

  def test_fixture_runner_records_calls_in_order
    runner = Commands::FixtureRunner.new
    runner.add(pattern: ["bin/importmap", "outdated"], stdout: "")
    runner.add(pattern: ["bin/importmap", "audit"], stdout: "")
    runner.run("bin/importmap", "outdated")
    runner.run("bin/importmap", "audit")
    assert_equal [
      ["bin/importmap", "outdated"],
      ["bin/importmap", "audit"]
    ], runner.calls
  end

  def test_fixture_runner_first_matching_pattern_wins
    # Order matters: if you register a fallback first, it'll swallow more
    # specific patterns. This test pins the behavior so callers know to
    # register specific patterns before general ones.
    runner = Commands::FixtureRunner.new
    runner.add(pattern: ["bin/importmap", "pin", "lodash@4.17.21"], stdout: "first\n")
    runner.add(pattern: ["bin/importmap", "pin", "lodash@4.17.21"], stdout: "second\n")
    assert_equal "first\n", runner.run("bin/importmap", "pin", "lodash@4.17.21").stdout
  end

  # ---- FixtureRunner: regex matching ----

  def test_fixture_runner_supports_regex_elements_in_patterns
    # Package versions change; the pattern uses a regex to allow any semver.
    runner = Commands::FixtureRunner.new
    runner.add(
      pattern: ["bin/importmap", "pin", /\Alodash@\d+\.\d+\.\d+\z/],
      stdout: "Pinned lodash\n"
    )
    assert_equal "Pinned lodash\n", runner.run("bin/importmap", "pin", "lodash@4.17.21").stdout
  end

  def test_fixture_runner_regex_must_match_exactly_at_position
    runner = Commands::FixtureRunner.new
    runner.add(pattern: ["bin/importmap", "pin", /\Alodash@/], stdout: "ok\n")
    err = assert_raises(RuntimeError) do
      runner.run("bin/importmap", "pin", "axios@1.7.0")
    end
    assert_match(/No fixture matched/, err.message)
  end

  # ---- FixtureRunner: misses and errors ----

  def test_fixture_runner_raises_clearly_when_no_pattern_matches
    runner = Commands::FixtureRunner.new
    runner.add(pattern: ["bin/importmap", "outdated"], stdout: "")
    err = assert_raises(RuntimeError) { runner.run("bin/importmap", "audit") }
    assert_includes err.message, "No fixture matched"
    assert_includes err.message, "audit"
  end

  def test_fixture_runner_argv_size_mismatch_does_not_match
    # A 2-element pattern must not match a 3-element call.
    runner = Commands::FixtureRunner.new
    runner.add(pattern: ["bin/importmap", "outdated"], stdout: "ok\n")
    assert_raises(RuntimeError) { runner.run("bin/importmap", "outdated", "--verbose") }
  end

  def test_fixture_runner_bang_raises_command_error_on_recorded_failure
    runner = Commands::FixtureRunner.new
    runner.add(
      pattern: ["bin/importmap", "pin", "lodash@4.17.21"],
      stderr: "network error",
      exit_code: 1
    )
    err = assert_raises(Commands::CommandError) { runner.run!("bin/importmap", "pin", "lodash@4.17.21") }
    assert_equal 1, err.result.exit_code
    assert_includes err.message, "network error"
  end
end
