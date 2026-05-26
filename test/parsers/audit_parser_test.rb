# frozen_string_literal: true

require_relative "../test_helper"
require "parsers/audit_parser"

class AuditParserTest < Minitest::Test
  Parser = ImportmapUpdate::Parsers::AuditParser

  def test_parses_basic_audit_output
    result = Parser.parse(fixture("audit_basic.txt"))

    assert_equal 2, result.size

    lodash = result[0]
    assert_equal "lodash", lodash.name
    assert_equal "high", lodash.severity.to_s
    assert_equal "<4.17.21", lodash.vulnerable_versions
    assert_equal "Prototype Pollution in lodash", lodash.advisory

    stimulus = result[1]
    assert_equal "@hotwired/stimulus", stimulus.name
    assert_equal "moderate", stimulus.severity.to_s
  end

  def test_parses_single_critical
    result = Parser.parse(fixture("audit_critical.txt"))
    assert_equal 1, result.size
    assert_equal "critical", result[0].severity.to_s
    assert_equal "evil-pkg", result[0].name
  end

  def test_empty_output_returns_empty_array
    assert_empty Parser.parse(fixture("audit_empty.txt"))
  end

  def test_blank_input_returns_empty_array
    assert_empty Parser.parse("")
    assert_empty Parser.parse(nil)
  end
end
