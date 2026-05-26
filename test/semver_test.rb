# frozen_string_literal: true

require_relative "test_helper"
require "semver"

class SemverTest < Minitest::Test
  include ImportmapUpdate

  # ---- happy paths

  def test_patch_bump
    assert_equal :patch, Semver.classify("4.17.20", "4.17.21")
  end

  def test_minor_bump
    assert_equal :minor, Semver.classify("3.2.1", "3.3.0")
  end

  def test_major_bump
    assert_equal :major, Semver.classify("18.2.0", "19.0.0")
  end

  # ---- 0.x.y npm-convention behavior (we *don't* treat all 0.x bumps as major)

  def test_zero_dot_x_patch_is_patch
    assert_equal :patch, Semver.classify("0.5.1", "0.5.2")
  end

  def test_zero_dot_x_minor_is_minor
    assert_equal :minor, Semver.classify("0.5.1", "0.6.0")
  end

  def test_zero_to_one_is_major
    assert_equal :major, Semver.classify("0.9.0", "1.0.0")
  end

  # ---- prefixes and metadata

  def test_v_prefix_is_tolerated_on_both_sides
    assert_equal :patch, Semver.classify("v1.2.3", "v1.2.4")
  end

  def test_v_prefix_mixed_with_bare
    assert_equal :minor, Semver.classify("1.2.3", "v1.3.0")
  end

  def test_build_metadata_is_ignored_for_classification
    # +build is metadata per SemVer; it doesn't shift the bump category.
    assert_equal :patch, Semver.classify("1.2.3", "1.2.3+build.1")
  end

  # ---- pre-releases

  def test_bump_into_prerelease_of_same_core_is_patch
    # User installed 1.2.3 stable, now there's 1.2.3-rc.1 of the *same*
    # core version — treat as patch (lowest-risk classification).
    assert_equal :patch, Semver.classify("1.2.3", "1.2.3-rc.1")
  end

  def test_prerelease_on_both_sides_compares_cores
    assert_equal :minor, Semver.classify("1.2.3-beta.1", "1.3.0-beta.2")
  end

  # ---- garbage in

  def test_unparseable_from_returns_nil
    assert_nil Semver.classify("not-a-version", "1.2.3")
  end

  def test_unparseable_to_returns_nil
    assert_nil Semver.classify("1.2.3", "Response code: 404")
  end

  def test_nil_input_returns_nil
    assert_nil Semver.classify(nil, "1.2.3")
    assert_nil Semver.classify("1.2.3", nil)
  end

  def test_whitespace_is_tolerated
    assert_equal :patch, Semver.classify("  1.2.3  ", "1.2.4")
  end

  # ---- parse() exposed for the planner

  def test_parse_returns_structured_components
    parsed = Semver.parse("v1.2.3-rc.1+build.5")
    assert_equal({major: 1, minor: 2, patch: 3, prerelease: "rc.1"}, parsed)
  end

  def test_parse_returns_nil_for_garbage
    assert_nil Semver.parse("totally-broken")
  end
end
