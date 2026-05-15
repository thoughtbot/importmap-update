# frozen_string_literal: true

require_relative "../test_helper"
require "parsers/audit_parser"

class AuditParserTest < Minitest::Test
  Parser = Importmap::Update::Parsers::AuditParser

  def test_parses_basic_audit_output
    result = Parser.parse(fixture("audit_basic.txt"))

    assert_equal 2, result.size

    lodash = result[0]
    assert_equal "lodash", lodash.name
    assert_equal "high", lodash.severity
    assert_equal "<4.17.21", lodash.vulnerable_versions
    assert_equal "Prototype Pollution in lodash", lodash.advisory

    stimulus = result[1]
    assert_equal "@hotwired/stimulus", stimulus.name
    assert_equal "moderate", stimulus.severity
  end

  def test_parses_single_critical
    result = Parser.parse(fixture("audit_critical.txt"))
    assert_equal 1, result.size
    assert_equal "critical", result[0].severity
    assert_equal "evil-pkg", result[0].name
  end

  def test_empty_output_returns_empty_array
    assert_empty Parser.parse(fixture("audit_empty.txt"))
  end

  def test_blank_input_returns_empty_array
    assert_empty Parser.parse("")
    assert_empty Parser.parse(nil)
  end

  def test_advisory_with_embedded_pipe_is_preserved
    # Synthesised: if npm ever returns a description with a literal `|`,
    # we want to keep the description intact rather than truncating it
    # or treating it as a parse error.
    output = <<~OUT
      | Package | Severity | Vulnerable versions | Vulnerability                           |
      |---------|----------|---------------------|-----------------------------------------|
      | x       | high     | <1.0.0              | CVE-2024-1234 | command injection in x  |
       1 vulnerability found: 1 high
    OUT
    result = Parser.parse(output)
    assert_equal 1, result.size
    assert_includes result[0].advisory, "CVE-2024-1234"
    assert_includes result[0].advisory, "command injection in x"
  end

  def test_known_severities_constant_is_ordered_low_to_critical
    # The planner will sort vulnerabilities by severity; lock this order in
    # here so a change to it is a deliberate, test-flagged change.
    assert_equal %w[low moderate high critical], Parser::SEVERITIES
  end
end
