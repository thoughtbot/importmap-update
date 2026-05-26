# frozen_string_literal: true

require_relative "markdown_table_parser"

module ImportmapUpdate
  module Parsers
    class AuditParser
      SEVERITIES = %w[low moderate high critical].freeze
      DEFAULT_SEVERITY_LEVEL = 0

      SeverityLevel = Data.define(:level) do
        def self.from_name(name)
          level = SEVERITIES.index(name) || DEFAULT_SEVERITY_LEVEL

          new(level)
        end

        def to_s = SEVERITIES[level]

        def inspect = "SeverityLevel(#{self})"
      end

      Vulnerability = Data.define(:name, :severity, :vulnerable_versions, :advisory)

      def self.parse(output)
        new(output).parse
      end

      def initialize(output)
        @output = output.to_s
      end

      def parse
        table = MarkdownTableParser.parse(@output)
        return [] if table.empty?

        table.map do |row|
          Vulnerability.new(
            name: row[:package],
            severity: SeverityLevel.from_name(row[:severity]),
            vulnerable_versions: row[:vulnerable_versions],
            advisory: row[:vulnerability]
          )
        end
      end
    end
  end
end
