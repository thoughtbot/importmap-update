# frozen_string_literal: true

require "yaml"

module ImportmapUpdate
  # Serializes and parses the metadata block that the action embeds in
  # every PR body it creates. The block is what makes the reconciler
  # possible: on the next run, we read it back out and compare against
  # the freshly-built plan to decide whether to leave the PR alone,
  # force-push it, or close it.
  #
  # The on-the-wire format is YAML inside an HTML comment, fenced by
  # literal start/end markers. HTML comments don't render in the PR
  # body so this is invisible to reviewers, but easy for both the action
  # and a curious human to grep for.
  #
  # Example block (formatted for readability):
  #
  #   <!-- importmap-update:metadata
  #   schema_version: 1
  #   tool: importmap-update
  #   kind: patch
  #   packages:
  #     - { name: lodash, from: 4.17.20, to: 4.17.21, semver_kind: patch }
  #     - { name: axios,  from: 1.7.0,   to: 1.7.1,   semver_kind: patch }
  #   -->
  #
  # Schema versioning is forward-looking: when the structure changes in
  # a future release, old blocks can be either upgraded or refused.
  module Metadata
    SCHEMA_VERSION = 1

    START_MARKER = "<!-- importmap-update:metadata"
    END_MARKER = "-->"

    # Regex finds the block anywhere in a PR body, tolerates surrounding
    # text, and captures the YAML payload between the markers.
    BLOCK_RE = /
      #{Regexp.escape(START_MARKER)}\s*\n
      (.*?)
      \n\s*#{Regexp.escape(END_MARKER)}
    /xm

    # Renders a planner-emitted metadata hash into the comment block.
    # Symbols are converted to strings so the YAML is round-trippable
    # through `YAML.safe_load` without `permitted_classes: [Symbol]`.
    def self.render(metadata)
      payload = stringify(metadata.merge(schema_version: SCHEMA_VERSION))
      "#{START_MARKER}\n#{payload.to_yaml.sub(/\A---\n/, "")}#{END_MARKER}"
    end

    # Extracts and parses the metadata block from a PR body. Returns
    # nil if the block is missing or unparseable — both cases mean
    # "treat as a foreign PR, leave it alone".
    def self.extract(body)
      return nil if body.nil?
      match = BLOCK_RE.match(body)
      return nil unless match
      parse_yaml(match[1])
    end

    # True iff a PR body contains a recognizable, parseable, current-
    # schema metadata block. This is what the reconciler uses to decide
    # whether a PR is "one of ours".
    def self.ours?(body)
      meta = extract(body)
      return false unless meta.is_a?(Hash)
      meta["tool"] == "importmap-update" &&
        meta["schema_version"] == SCHEMA_VERSION
    end

    # Embeds a rendered metadata block into a PR body. If the body
    # already contains a block, replaces it in place. Otherwise appends
    # the block at the end with a blank line separator.
    def self.embed(body, metadata)
      block = render(metadata)
      body ||= ""
      if BLOCK_RE.match?(body)
        body.sub(BLOCK_RE, block)
      else
        [body.rstrip, block].reject(&:empty?).join("\n\n")
      end
    end

    # ---- helpers ----

    def self.parse_yaml(yaml_string)
      # `aliases: false` to keep YAML bombs from being a concern when
      # reading PR bodies, even though they're inherently low-trust.
      YAML.safe_load(yaml_string, permitted_classes: [], aliases: false)
    rescue Psych::SyntaxError
      nil
    end

    def self.stringify(value)
      case value
      when Hash
        value.each_with_object({}) { |(k, v), acc| acc[k.to_s] = stringify(v) }
      when Array
        value.map { |v| stringify(v) }
      when Symbol
        value.to_s
      else
        value
      end
    end
  end
end
