# frozen_string_literal: true

require_relative "test_helper"
require "metadata"

class MetadataTest < Minitest::Test
  Metadata = ImportmapUpdate::Metadata

  PLAN_META = {
    tool: "importmap-update",
    kind: :patch,
    packages: [
      {name: "lodash", from: "4.17.20", to: "4.17.21", semver_kind: :patch},
      {name: "axios", from: "1.7.0", to: "1.7.1", semver_kind: :patch}
    ]
  }.freeze

  # ---- render ----

  def test_render_produces_a_fenced_yaml_block
    block = Metadata.render(PLAN_META)
    assert block.start_with?("<!-- importmap-update:metadata")
    assert block.end_with?("-->")
  end

  def test_render_includes_schema_version
    block = Metadata.render(PLAN_META)
    assert_match(/schema_version: 1/, block)
  end

  def test_render_writes_symbols_as_strings
    # The YAML must be parseable without permitted_classes: [Symbol].
    block = Metadata.render(PLAN_META)
    refute_match(/:patch\b/, block, "should not embed Ruby symbol literals")
    assert_match(/kind: patch/, block)
  end

  # ---- extract ----

  def test_extract_returns_the_payload_as_a_hash
    body = "Hello\n\n" + Metadata.render(PLAN_META) + "\n\nMore text"
    meta = Metadata.extract(body)
    assert_equal "importmap-update", meta["tool"]
    assert_equal "patch", meta["kind"]
    assert_equal 2, meta["packages"].size
    assert_equal "lodash", meta["packages"].first["name"]
  end

  def test_extract_returns_nil_when_block_is_missing
    assert_nil Metadata.extract("Just a PR body, no metadata here.")
    assert_nil Metadata.extract("")
    assert_nil Metadata.extract(nil)
  end

  def test_extract_returns_nil_on_unparseable_yaml
    # Synthesised malformed block; defensible behavior is "treat as foreign".
    body = <<~BODY
      Some preamble.
      <!-- importmap-update:metadata
      this is: not: valid: yaml
        - oops
      -->
    BODY
    assert_nil Metadata.extract(body)
  end

  def test_extract_finds_block_anywhere_in_body
    body = "Top\n\n#{Metadata.render(PLAN_META)}\n\nBottom"
    assert Metadata.extract(body)
  end

  # ---- round-trip ----

  def test_render_then_extract_round_trips_the_payload
    body = Metadata.render(PLAN_META)
    parsed = Metadata.extract(body)
    expected = {
      "schema_version" => 1,
      "tool" => "importmap-update",
      "kind" => "patch",
      "packages" => [
        {"name" => "lodash", "from" => "4.17.20", "to" => "4.17.21", "semver_kind" => "patch"},
        {"name" => "axios", "from" => "1.7.0", "to" => "1.7.1", "semver_kind" => "patch"}
      ]
    }
    assert_equal expected, parsed
  end

  # ---- ours? ----

  def test_ours_is_true_for_a_well_formed_current_schema_block
    body = "Body\n\n" + Metadata.render(PLAN_META)
    assert Metadata.ours?(body)
  end

  def test_ours_is_false_when_block_is_missing
    refute Metadata.ours?("Hello.")
    refute Metadata.ours?(nil)
  end

  def test_ours_is_false_for_a_block_with_wrong_tool_name
    body = <<~BODY
      <!-- importmap-update:metadata
      schema_version: 1
      tool: some-other-bot
      -->
    BODY
    refute Metadata.ours?(body)
  end

  def test_ours_is_false_for_a_future_schema_version
    # Belt and suspenders: when we bump the schema in a future release,
    # older deployments of the action MUST NOT treat new-schema PRs as
    # theirs, lest they overwrite or close them.
    body = <<~BODY
      <!-- importmap-update:metadata
      schema_version: 99
      tool: importmap-update
      -->
    BODY
    refute Metadata.ours?(body)
  end

  # ---- embed ----

  def test_embed_appends_block_to_body_with_separator
    body = "Description of the change."
    final = Metadata.embed(body, PLAN_META)
    assert final.start_with?("Description of the change.")
    assert final.include?(Metadata::START_MARKER)
    assert Metadata.ours?(final)
  end

  def test_embed_into_empty_body_yields_just_the_block
    final = Metadata.embed("", PLAN_META)
    refute final.empty?
    assert Metadata.ours?(final)
  end

  def test_embed_into_nil_body_does_not_crash
    final = Metadata.embed(nil, PLAN_META)
    assert Metadata.ours?(final)
  end

  def test_embed_replaces_an_existing_block_in_place
    # Sequence the writer in step 5 will perform: take an existing PR body,
    # swap out the old metadata, leave the surrounding text alone.
    original_body = "User-visible description.\n\n" + Metadata.render(PLAN_META) + "\n\nFooter"
    updated_meta = PLAN_META.merge(packages: PLAN_META[:packages] + [
      {name: "newcomer", from: "1.0.0", to: "1.0.1", semver_kind: :patch}
    ])

    final = Metadata.embed(original_body, updated_meta)

    # Surrounding text preserved.
    assert_includes final, "User-visible description."
    assert_includes final, "Footer"

    # Only one block ends up in the body.
    assert_equal 1, final.scan(Metadata::START_MARKER).size

    # And the block reflects the new metadata.
    assert_equal 3, Metadata.extract(final)["packages"].size
  end
end
