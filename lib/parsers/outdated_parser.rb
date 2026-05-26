# frozen_string_literal: true

require_relative "markdown_table_parser"

module ImportmapUpdate
  module Parsers
    class OutdatedParser
      VERSION_SHAPE_RE = /\Av?\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?\z/

      OutdatedPackage = Data.define(:name, :current, :latest_or_error) do
        def latest
          return nil unless VERSION_SHAPE_RE.match?(latest_or_error)

          latest_or_error
        end

        def error
          return nil if VERSION_SHAPE_RE.match?(latest_or_error)

          latest_or_error
        end

        def parseable?
          !latest.nil?
        end
      end

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
          OutdatedPackage.new(
            name: row[:package],
            current: row[:current],
            latest_or_error: row[:latest]
          )
        end
      end
    end
  end
end
