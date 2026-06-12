# frozen_string_literal: true

require_relative "test_helper"
require "commands"

class CommandsTest < Minitest::Test
  Commands = ImportmapUpdate::Commands

  def test_shell_runner_captures_stdout
    result = Commands::ShellRunner.new.run("echo", "hello world")
    assert_equal "hello world\n", result.output
    assert_predicate result, :success?
    assert_equal 0, result.exit_code
  end

  def test_shell_runner_captures_stderr_and_failure
    result = Commands::ShellRunner.new.run("sh", "-c", "echo oops 1>&2; exit 3")
    assert_equal "oops\n", result.output
    assert_equal 3, result.exit_code
    refute_predicate result, :success?
  end
end
