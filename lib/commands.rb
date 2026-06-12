# frozen_string_literal: true

require "open3"
require "json"

module ImportmapUpdate
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

    class ShellRunner
      def initialize(cwd: nil, open3: Open3)
        @cwd = cwd
        @open3 = open3
      end

      def run(*argv)
        opts = {}
        opts[:chdir] = @cwd if @cwd
        Bundler.with_unbundled_env do
          stdout, stderr, status = @open3.capture3(*argv, **opts)
          Result.new(stdout:, stderr:, exit_code: status.exitstatus)
        end
      end
    end
  end
end
