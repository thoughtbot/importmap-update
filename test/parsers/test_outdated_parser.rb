# frozen_string_literal: true

require_relative "../test_helper"
require "parsers/outdated_parser"

class OutdatedParserTest < Minitest::Test
  Parser = Importmap::Update::Parsers::OutdatedParser

  def test_parses_basic_three_package_output
    result = Parser.parse(fixture("outdated_basic.txt"))

    assert_equal 3, result.size

    stimulus = result[0]
    assert_equal "@hotwired/stimulus", stimulus.name
    assert_equal "3.2.1", stimulus.current
    assert_equal "3.2.2", stimulus.latest
    assert_nil stimulus.error
    assert_predicate stimulus, :parseable?

    lodash = result[1]
    assert_equal "lodash", lodash.name
    assert_equal "4.17.20", lodash.current
    assert_equal "4.17.21", lodash.latest

    react = result[2]
    assert_equal "react", react.name
    assert_equal "18.2.0", react.current
    assert_equal "19.0.0", react.latest
  end

  def test_parses_single_package_output
    result = Parser.parse(fixture("outdated_single.txt"))
    assert_equal 1, result.size
    assert_equal "lodash", result[0].name
  end

  def test_empty_output_returns_empty_array
    assert_empty Parser.parse(fixture("outdated_empty.txt"))
  end

  def test_blank_input_returns_empty_array
    assert_empty Parser.parse("")
    assert_empty Parser.parse(nil)
  end

  def test_error_in_latest_column_is_captured_separately
    result = Parser.parse(fixture("outdated_with_error.txt"))
    assert_equal 2, result.size

    broken = result.find { |p| p.name == "broken-pkg" }
    refute_nil broken
    assert_nil broken.latest
    assert_equal "Response code: 404", broken.error
    refute_predicate broken, :parseable?
  end

  def test_ignores_trailing_footer_text
    # The "N outdated packages found" line must not be parsed as a row.
    result = Parser.parse(fixture("outdated_basic.txt"))
    refute(result.any? { |p| p.name.include?("outdated") })
  end

  def test_handles_extra_blank_lines_between_table_and_footer
    output = <<~OUT
      | Package | Current | Latest  |
      |---------|---------|---------|
      | lodash  | 4.17.20 | 4.17.21 |

       1 outdated package found
    OUT
    result = Parser.parse(output)
    assert_equal 1, result.size
    assert_equal "lodash", result[0].name
  end
end
