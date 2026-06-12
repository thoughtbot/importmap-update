# frozen_string_literal: true

require "open3"
require "json"

module ImportmapUpdate
  module Commands
    Result = Data.define(:output, :exit_code) do
      def success?
        exit_code == 0
      end
    end

    class CommandError < StandardError
      attr_reader :argv, :result

      def initialize(argv, result)
        @argv = argv
        @result = result
        super("`#{argv.join(" ")}` exited #{result.exit_code}: #{result.output.strip}")
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
          output, status = @open3.capture2e(*argv, **opts)
          Result.new(output:, exit_code: status.exitstatus)
        end
      end
    end
  end
end
