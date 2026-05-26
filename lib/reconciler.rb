# frozen_string_literal: true

require_relative "metadata"

module ImportmapUpdate
  # Diffs the planner's desired state against the set of currently-open
  # PRs to decide what GitHub operations the action should perform.
  #
  # This module is the "destructive logic" — get it wrong and you nuke
  # PRs that shouldn't be closed, or force-push PRs that didn't need
  # touching. Every decision in here is unit-testable because the input
  # is pure data: a Plan from step 3, and an array of ExistingPR structs
  # that step 5's GitHub client will populate. The reconciler itself
  # never calls GitHub.
  #
  # Output is a list of Action records the executor consumes in order:
  #
  #   :open        — branch and PR don't exist; create them.
  #   :force_push  — branch and PR exist, but the package set changed.
  #                  Update the branch in place and edit the PR title/body.
  #   :close       — PR exists but is no longer in the plan (e.g. all its
  #                  packages were merged, or are no longer outdated).
  #                  Close with a comment explaining why.
  #   :noop        — PR matches the plan exactly. Leave it alone.
  #
  # Foreign PRs (branches matching our prefix but lacking a recognizable
  # metadata block) are skipped entirely — never touched, never reported.
  # A human who hand-creates a PR on a `importmap-updates/*` branch should
  # not have their work clobbered.
  class Reconciler
    # Input describing an open PR that GitHub returned. Step 5's client
    # will fill these in from the list-PRs API call.
    ExistingPR = Data.define(:number, :branch, :body, :title)

    Action = Struct.new(:type, :pr_spec, :existing_pr, :reason, keyword_init: true) do
      def open?
        type == :open
      end

      def force_push?
        type == :force_push
      end

      def close?
        type == :close
      end

      def noop?
        type == :noop
      end
    end

    Result = Data.define(:actions, :ignored) do
      def opens
        actions.select(&:open?)
      end

      def force_pushes
        actions.select(&:force_push?)
      end

      def closes
        actions.select(&:close?)
      end

      def noops
        actions.select(&:noop?)
      end
    end

    def initialize(plan:, existing_prs:)
      @plan = plan
      @existing_prs = existing_prs
    end

    def call
      actions = []
      ignored = []

      # Partition existing PRs into "ours" (have our metadata block) and
      # "foreign" (any other PR on a matching branch — leave alone).
      ours, foreign = @existing_prs.partition { |pr| Metadata.ours?(pr.body) }
      ignored.concat(foreign)

      ours_by_branch = ours.each_with_object({}) { |pr, h| h[pr.branch] = pr }
      seen_branches = []

      @plan.pr_specs.each do |spec|
        seen_branches << spec.branch
        existing = ours_by_branch[spec.branch]

        actions << if existing.nil?
          Action.new(type: :open, pr_spec: spec, existing_pr: nil)
        elsif same_package_set?(existing, spec)
          Action.new(type: :noop, pr_spec: spec, existing_pr: existing)
        else
          Action.new(
            type: :force_push, pr_spec: spec, existing_pr: existing,
            reason: change_summary(existing, spec)
          )
        end
      end

      # Any of our PRs that didn't appear in the plan should be closed.
      # That means their packages were merged elsewhere, dropped from
      # the importmap, or are no longer outdated.
      ours.each do |pr|
        next if seen_branches.include?(pr.branch)
        actions << Action.new(
          type: :close, pr_spec: nil, existing_pr: pr,
          reason: "No matching plan entry for branch #{pr.branch}; packages may have been merged or are no longer outdated."
        )
      end

      Result.new(actions: actions.freeze, ignored: ignored.freeze)
    end

    private

    # Two PRs describe the same package set iff their (name, from, to)
    # triples, sorted by name, are identical. We deliberately don't
    # compare severity or semver_kind: those are derived from the bump
    # and don't change without name/from/to changing too. (If a package
    # gains a CVE between runs, its `to` version typically also moves,
    # so it'll force-push and reclassify naturally.)
    def same_package_set?(existing_pr, spec)
      existing_meta = Metadata.extract(existing_pr.body)
      return false unless existing_meta.is_a?(Hash)
      normalized_existing = normalize_packages(existing_meta["packages"])
      normalized_planned = normalize_packages(spec.packages.map { |p|
        {"name" => p.name, "from" => p.from, "to" => p.to}
      })
      normalized_existing == normalized_planned
    end

    def normalize_packages(packages)
      return [] unless packages.is_a?(Array)
      packages
        .map { |p| {name: p["name"], from: p["from"], to: p["to"]} }
        .sort_by { |p| p[:name].to_s }
    end

    def change_summary(existing_pr, spec)
      old = Metadata.extract(existing_pr.body)
      old_names = (old && old["packages"] || []).map { |p| "#{p["name"]}@#{p["to"]}" }
      new_names = spec.packages.map { |p| "#{p.name}@#{p.to}" }
      added = new_names - old_names
      removed = old_names - new_names
      parts = []
      parts << "added: #{added.join(", ")}" if added.any?
      parts << "removed: #{removed.join(", ")}" if removed.any?
      parts.empty? ? "package versions changed" : parts.join("; ")
    end
  end
end
