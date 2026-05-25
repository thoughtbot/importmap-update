# frozen_string_literal: true

require "open3"
require "json"

module Importmap
  module Update
    # Abstracts execution of external commands (bin/importmap) so the rest
    # of the codebase doesn't shell out directly. This is the seam tests hook
    # into — production code runs commands for real, tests inject a
    # FixtureRunner that replays pre-recorded (argv → stdout, exit) tuples.
    #
    # The interface deliberately mirrors what Open3.capture3 returns:
    #
    #   runner.run("bin/importmap", "outdated")
    #     # => Result(stdout: "...", stderr: "...", success: true, exit: 0)
    #
    # Commands are passed as an argv array, not a shell string. That's both
    # safer (no shell-injection surprises from package names) and easier to
    # match against fixture keys.
    module Commands
      Result = Data.define(:stdout, :stderr, :exit_code) do
        def success?
          exit_code == 0
        end
      end

      class CommandError < StandardError
        attr_reader :argv, :result

        def initialize(argv, result)
          @argv = argv
          @result = result
          super("`#{argv.join(" ")}` exited #{result.exit_code}: #{result.stderr.strip}")
        end
      end

      # Production runner: actually executes the command.
      class ShellRunner
        # @param cwd [String, nil] working directory (defaults to current)
        def initialize(cwd: nil)
          @cwd = cwd
        end

        def run(*argv)
          opts = {}
          opts[:chdir] = @cwd if @cwd
          Bundler.with_unbundled_env do
            stdout, stderr, status = Open3.capture3(*argv, opts)
            Result.new(stdout:, stderr:, exit_code: status.exitstatus)
          end
        end

        # Raises on non-zero exit. Use when you have no recovery strategy
        # and just want to surface the error to the caller.
        def run!(*argv)
          result = run(*argv)
          raise CommandError.new(argv, result) unless result.success?
          result
        end
      end
    end
  end
end
