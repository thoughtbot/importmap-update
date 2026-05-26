# frozen_string_literal: true

module Importmap
  module Update
    module Parsers
      # Parses the text output of `bin/importmap audit`.
      #
      # Expected format (see importmap-rails lib/importmap/commands.rb#audit):
      #
      #   | Package | Severity | Vulnerable versions | Vulnerability        |
      #   |---------|----------|---------------------|----------------------|
      #   | lodash  | high     | <4.17.21            | Prototype Pollution  |
      #    2 vulnerabilities found: 1 high, 1 moderate
      #
      # When no vulnerabilities exist:
      #
      #   No vulnerable packages found
      #
      # The Vulnerability column comes from the npm advisory database and is
      # free-form text. If it ever contains a literal `|`, we rejoin the
      # overflow cells so the description survives intact.
      class AuditParser
        Vulnerability = Data.define(:name, :severity, :vulnerable_versions, :advisory)

        SEVERITIES = %w[low moderate high critical].freeze

        EMPTY_MESSAGE = "No vulnerable packages found"
        DIVIDER_RE = /\A\|[-|]+\|\z/

        def self.parse(output)
          new(output).parse
        end

        def initialize(output)
          @output = output.to_s
        end

        def parse
          lines = @output.each_line.map(&:chomp)
          return [] if lines.any? { |l| l.strip == EMPTY_MESSAGE }

          header_idx = lines.index { |l| l.start_with?("|") && l.include?("Severity") }
          return [] unless header_idx

          rows = []
          lines[(header_idx + 1)..].each do |line|
            break unless line.start_with?("|")
            next if DIVIDER_RE.match?(line)
            cells = split_row(line)
            next unless cells.size >= 4
            rows << build_row(cells)
          end
          rows
        end

        private

        def split_row(line)
          line.split("|").map(&:strip).reject(&:empty?)
        end

        # If a description contained a `|`, cells.size will be >4. Rejoin the
        # tail into the advisory column so we don't lose information.
        def build_row(cells)
          name, severity, vulnerable_versions, *advisory_parts = cells
          Vulnerability.new(
            name:,
            severity:,
            vulnerable_versions:,
            advisory: advisory_parts.join(" | ")
          )
        end
      end
    end
  end
end
