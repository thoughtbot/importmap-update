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
        lines = @output.each_line.map(&:strip).select { it.start_with?("|") }.reject { it.start_with?("|-") }
        header = lines.shift.split("|")[1..-1].map(&:strip).map(&:downcase).map { |h| h.gsub(/\s+/, "_").to_sym }
        body = lines.map { |l| l.split("|")[1..-1].map(&:strip) }

        body.map { |row| Hash[header.zip(row)] }
      end
    end
  end
end
