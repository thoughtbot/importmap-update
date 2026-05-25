# frozen_string_literal: true

module Importmap
  module Update
    module Parsers
      # Parses the text output of `bin/importmap outdated`.
      #
      # Expected format (see importmap-rails lib/importmap/commands.rb#outdated):
      #
      #   | Package | Current | Latest |
      #   |---------|---------|--------|
      #   | lodash  | 4.17.20 | 4.17.21 |
      #    1 outdated package found
      #
      # When no outdated packages exist, the command prints only:
      #
      #   No outdated packages found
      #
      # The "Latest" column can also contain an error string (e.g. an HTTP
      # status from a failed lookup) when latest_version is nil on the
      # underlying OutdatedPackage. Those rows are returned with `error: ...`
      # set and `latest: nil`, so callers can decide whether to skip them.
      class OutdatedParser
        OutdatedPackage = Data.define(:name, :current, :latest, :error) do
          def parseable?
            !latest.nil?
          end
        end

        EMPTY_MESSAGE = "No outdated packages found"
        DIVIDER_RE = /\A\|[-|]+\|\z/
        # Cheap shape check for "looks like a version" — we don't need full
        # SemVer parsing here, just enough to decide "is this a version or
        # an error message?". Pre-release tags and `v` prefixes are allowed.
        VERSION_SHAPE_RE = /\Av?\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?\z/

        def self.parse(output)
          new(output).parse
        end

        def initialize(output)
          @output = output.to_s
        end

        def parse
          lines = @output.each_line.map(&:chomp)
          return [] if lines.any? { |l| l.strip == EMPTY_MESSAGE }

          header_idx = lines.index { |l| l.start_with?("|") && l.include?("Package") }
          return [] unless header_idx

          rows = []
          lines[(header_idx + 1)..].each do |line|
            break unless line.start_with?("|")
            next if DIVIDER_RE.match?(line)
            cells = split_row(line)
            next unless cells.size >= 3
            rows << build_row(cells)
          end
          rows
        end

        private

        # `| a | b | c |` → ["a", "b", "c"]
        # We drop the empty strings produced by the leading and trailing pipes.
        def split_row(line)
          line.split("|").map(&:strip).reject(&:empty?)
        end

        def build_row(cells)
          name, current, latest_or_error = cells[0], cells[1], cells[2]
          if VERSION_SHAPE_RE.match?(latest_or_error)
            OutdatedPackage.new(name:, current:, latest: latest_or_error, error: nil)
          else
            OutdatedPackage.new(name:, current:, latest: nil, error: latest_or_error)
          end
        end
      end
    end
  end
end
