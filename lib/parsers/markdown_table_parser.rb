# frozen_string_literal: true

module ImportmapUpdate
  module Parsers
    class MarkdownTableParser
      def self.parse(output)
        new(output).parse
      end

      def initialize(output)
        @output = output.to_s
      end

      def parse
        lines = @output.each_line.map(&:strip).select { _1.start_with?("|") }.reject { _1.start_with?("|-") }

        return [] if lines.empty?

        header = lines.shift.split("|")[1..].map { symbolize(_1) }
        body = lines.map { |l| l.split("|")[1..].map(&:strip) }

        body.map { |row| header.zip(row).to_h }
      end

      private

      def symbolize(string)
        string.strip.downcase.gsub(/\s+/, "_").to_sym
      end
    end
  end
end
