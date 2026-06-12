# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "minitest/autorun"

module TestHelpers
  FIXTURE_DIR = File.expand_path("fixtures", __dir__)

  def fixture(name)
    File.read(File.join(FIXTURE_DIR, name))
  end
end

Minitest::Test.include(TestHelpers)
