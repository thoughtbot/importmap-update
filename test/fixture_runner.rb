# frozen_string_literal: true

require "commands"

module Importmap
  module Update
    module Commands
      class FixtureRunner
        Fixture = Struct.new(:pattern, :result, keyword_init: true)

        def initialize(fixtures = [])
          @fixtures = fixtures
          @calls = []
        end

        attr_reader :calls

        def add(pattern:, stdout: "", stderr: "", exit_code: 0)
          @fixtures << Fixture.new(
            pattern: pattern,
            result: Result.new(stdout: stdout, stderr: stderr, exit_code: exit_code)
          )
        end

        def run(*argv)
          @calls << argv
          match = @fixtures.find { |f| pattern_matches?(f.pattern, argv) }
          if match.nil?
            raise "No fixture matched argv: #{argv.inspect}.\nRegistered patterns: #{@fixtures.map(&:pattern).inspect}"
          end
          match.result
        end

        def run!(*argv)
          result = run(*argv)
          raise CommandError.new(argv, result) unless result.success?
          result
        end

        private

        def pattern_matches?(pattern, argv)
          return false unless pattern.is_a?(Array)
          return false unless pattern.size == argv.size
          pattern.zip(argv).all? do |pat, arg|
            case pat
            when Regexp then pat.match?(arg)
            else pat == arg
            end
          end
        end
      end
    end
  end
end
