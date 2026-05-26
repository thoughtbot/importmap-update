# frozen_string_literal: true

require_relative "../test_helper"
require "parsers/markdown_table_parser"

class MarkdownTableParserTest < Minitest::Test
  Parser = ImportmapUpdate::Parsers::MarkdownTableParser

  def test_parses_audit_markdown_table
    table = <<~MARKDOWN
      | Package            | Severity | Vulnerable versions | Vulnerability                 |
      |--------------------|----------|---------------------|-------------------------------|
      | lodash             | high     | <4.17.21            | Prototype Pollution in lodash |
      | @hotwired/stimulus | moderate | <3.2.2              | ReDoS in stimulus router      |
      2 vulnerabilities found: 1 high, 1 moderate
    MARKDOWN

    result = Parser.parse(table)

    expected = [
      {package: "lodash", severity: "high", vulnerable_versions: "<4.17.21", vulnerability: "Prototype Pollution in lodash"},
      {package: "@hotwired/stimulus", severity: "moderate", vulnerable_versions: "<3.2.2", vulnerability: "ReDoS in stimulus router"}
    ]

    assert_equal expected, result
  end

  def test_parses_outdated_markdown_table
    table = <<~MARKDOWN
      | Package            | Current | Latest  |
      |--------------------|---------|---------|
      | @hotwired/stimulus | 3.2.1   | 3.2.2   |
      | lodash             | 4.17.20 | 4.17.21 |
      | react              | 18.2.0  | 19.0.0  |
      3 outdated packages found
    MARKDOWN

    result = Parser.parse(table)

    expected = [
      {package: "@hotwired/stimulus", current: "3.2.1", latest: "3.2.2"},
      {package: "lodash", current: "4.17.20", latest: "4.17.21"},
      {package: "react", current: "18.2.0", latest: "19.0.0"}
    ]

    assert_equal expected, result
  end
end
