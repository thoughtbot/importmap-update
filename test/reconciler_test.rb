# frozen_string_literal: true

require_relative "test_helper"
require "reconciler"
require "planner"
require "metadata"
require "config"

class ReconcilerTest < Minitest::Test
  Reconciler = Importmap::Update::Reconciler
  Planner = Importmap::Update::Planner
  Metadata = Importmap::Update::Metadata
  Config = Importmap::Update::Config
  ExistingPR = Reconciler::ExistingPR

  # ---- builder helpers ----

  def package_bump(name, from, to, kind: :patch, severity: nil)
    advisory = severity ? {severity: severity, vulnerable_versions: "<#{to}", description: "..."} : nil
    Planner::PackageBump.new(name: name, from: from, to: to, semver_kind: kind, advisory: advisory)
  end

  def spec(branch:, packages:, kind: :patch, title: "spec title")
    Planner::PRSpec.new(
      kind: kind,
      packages: packages,
      branch: branch,
      title: title,
      metadata: {
        tool: "importmap-update",
        kind: kind,
        packages: packages.map { |p|
          entry = {name: p.name, from: p.from, to: p.to, semver_kind: p.semver_kind}
          entry[:severity] = p.advisory[:severity] if p.advisory
          entry
        }
      }
    )
  end

  def plan_with(specs)
    Planner::Plan.new(pr_specs: specs, warnings: [])
  end

  # Build a PR body with our metadata block reflecting the given package
  # triples. Mirrors what step 5 will eventually write to GitHub.
  def existing_pr(number:, branch:, packages:, title: "old title")
    metadata = {
      tool: "importmap-update",
      kind: :patch,
      packages: packages.map { |(name, from, to)| {name: name, from: from, to: to, semver_kind: :patch} }
    }
    body = "Description.\n\n" + Metadata.render(metadata)
    ExistingPR.new(number: number, branch: branch, body: body, title: title)
  end

  def reconcile(plan_specs:, existing_prs: [])
    Reconciler.new(plan: plan_with(plan_specs), existing_prs: existing_prs).call
  end

  # ---- :open ----

  def test_opens_pr_when_no_existing_branch_matches
    s = spec(
      branch: "importmap-updates/patch",
      packages: [package_bump("lodash", "4.17.20", "4.17.21")]
    )
    result = reconcile(plan_specs: [s])

    assert_equal 1, result.opens.size
    assert_equal s, result.opens.first.pr_spec
    assert_nil result.opens.first.existing_pr
    assert_empty result.closes
    assert_empty result.force_pushes
    assert_empty result.noops
  end

  # ---- :noop ----

  def test_noop_when_existing_pr_has_identical_package_set
    pkg = package_bump("lodash", "4.17.20", "4.17.21")
    s = spec(branch: "importmap-updates/patch", packages: [pkg])
    existing = existing_pr(
      number: 42,
      branch: "importmap-updates/patch",
      packages: [["lodash", "4.17.20", "4.17.21"]]
    )

    result = reconcile(plan_specs: [s], existing_prs: [existing])

    assert_equal 1, result.noops.size
    assert_equal 42, result.noops.first.existing_pr.number
    assert_empty result.opens
    assert_empty result.force_pushes
    assert_empty result.closes
  end

  def test_noop_when_package_order_differs_but_set_is_equal
    # Existing PR lists [axios, lodash]; plan lists [lodash, axios].
    # Same package set, no force-push required.
    packages = [
      package_bump("lodash", "4.17.20", "4.17.21"),
      package_bump("axios", "1.7.0", "1.7.1")
    ]
    s = spec(branch: "importmap-updates/patch", packages: packages)
    existing = existing_pr(
      number: 7,
      branch: "importmap-updates/patch",
      packages: [["axios", "1.7.0", "1.7.1"], ["lodash", "4.17.20", "4.17.21"]]
    )
    result = reconcile(plan_specs: [s], existing_prs: [existing])
    assert_equal 1, result.noops.size
  end

  # ---- :force_push ----

  def test_force_pushes_when_a_new_package_was_added_to_the_bucket
    # Existing patch PR has just lodash; this run, axios also has a patch.
    s = spec(
      branch: "importmap-updates/patch",
      packages: [
        package_bump("lodash", "4.17.20", "4.17.21"),
        package_bump("axios", "1.7.0", "1.7.1")
      ]
    )
    existing = existing_pr(
      number: 7,
      branch: "importmap-updates/patch",
      packages: [["lodash", "4.17.20", "4.17.21"]]
    )

    result = reconcile(plan_specs: [s], existing_prs: [existing])

    assert_equal 1, result.force_pushes.size
    action = result.force_pushes.first
    assert_equal 7, action.existing_pr.number
    assert_includes action.reason, "added: axios@1.7.1"
  end

  def test_force_pushes_when_a_version_target_moved
    # axios bumped from 1.7.1 (existing PR target) to 1.7.2 (new latest).
    # The branch is the same; the package set is not. Update in place.
    s = spec(
      branch: "importmap-updates/patch",
      packages: [package_bump("axios", "1.7.0", "1.7.2")]
    )
    existing = existing_pr(
      number: 12,
      branch: "importmap-updates/patch",
      packages: [["axios", "1.7.0", "1.7.1"]]
    )

    result = reconcile(plan_specs: [s], existing_prs: [existing])

    assert_equal 1, result.force_pushes.size
    reason = result.force_pushes.first.reason
    assert_includes reason, "added: axios@1.7.2"
    assert_includes reason, "removed: axios@1.7.1"
  end

  def test_force_pushes_when_a_package_was_removed_from_the_bucket
    # Existing PR had two packages; lodash was merged independently, so the
    # new plan has only axios. Update the branch to reflect that.
    s = spec(
      branch: "importmap-updates/patch",
      packages: [package_bump("axios", "1.7.0", "1.7.1")]
    )
    existing = existing_pr(
      number: 22,
      branch: "importmap-updates/patch",
      packages: [
        ["axios", "1.7.0", "1.7.1"],
        ["lodash", "4.17.20", "4.17.21"]
      ]
    )

    result = reconcile(plan_specs: [s], existing_prs: [existing])

    assert_equal 1, result.force_pushes.size
    assert_includes result.force_pushes.first.reason, "removed: lodash@4.17.21"
  end

  # ---- :close ----

  def test_closes_existing_pr_when_no_matching_plan_entry
    # We have an open patch PR for lodash, but on this run lodash isn't
    # outdated anymore (someone merged the PR, or pinned manually). The
    # planner emits an empty plan, and the reconciler closes the orphan.
    existing = existing_pr(
      number: 99,
      branch: "importmap-updates/patch",
      packages: [["lodash", "4.17.20", "4.17.21"]]
    )

    result = reconcile(plan_specs: [], existing_prs: [existing])

    assert_equal 1, result.closes.size
    assert_equal 99, result.closes.first.existing_pr.number
    assert_includes result.closes.first.reason, "no longer outdated"
  end

  # ---- foreign PRs ----

  def test_does_not_touch_pr_on_matching_branch_without_metadata_block
    # A human (or other tool) opened a PR on a branch that looks like ours,
    # but it has no metadata block. We must not close, edit, or force-push it.
    foreign = ExistingPR.new(
      number: 50,
      branch: "importmap-updates/patch",
      body: "Hand-written PR. No metadata.",
      title: "Manual patch fixes"
    )

    result = reconcile(plan_specs: [], existing_prs: [foreign])

    assert_empty result.actions
    assert_equal [foreign], result.ignored
  end

  def test_treats_pr_with_wrong_tool_marker_as_foreign
    body = <<~BODY
      <!-- importmap-update:metadata
      schema_version: 1
      tool: some-other-bot
      packages:
        - { name: lodash, from: 4.17.20, to: 4.17.21 }
      -->
    BODY
    foreign = ExistingPR.new(number: 60, branch: "importmap-updates/patch", body: body, title: "...")
    result = reconcile(plan_specs: [], existing_prs: [foreign])

    assert_empty result.actions
    assert_equal 1, result.ignored.size
  end

  def test_foreign_pr_on_branch_we_want_still_creates_our_new_pr
    # Edge case: someone manually opened a foreign PR on importmap-updates/patch,
    # AND we have a plan to open one. The reconciler should leave theirs alone
    # AND emit an :open action — even though that may collide at the GitHub
    # level (step 5 will surface the API error). That's better than silently
    # not opening a security fix because someone squatted the branch name.
    foreign = ExistingPR.new(
      number: 51,
      branch: "importmap-updates/patch",
      body: "Manual PR with no metadata.",
      title: "Squatted"
    )
    s = spec(
      branch: "importmap-updates/patch",
      packages: [package_bump("lodash", "4.17.20", "4.17.21")]
    )
    result = reconcile(plan_specs: [s], existing_prs: [foreign])

    assert_equal [foreign], result.ignored
    assert_equal 1, result.opens.size
  end

  # ---- multi-PR scenarios ----

  def test_handles_a_realistic_mixed_run
    # One security PR (existing, unchanged): noop
    # One patch group (existing, but axios was added): force_push
    # One major PR (no existing): open
    # One orphan minor PR (in existing, not in plan): close
    # One foreign PR on our prefix: ignored

    security_spec = spec(
      branch: "importmap-updates/security-lodash",
      kind: :security,
      packages: [package_bump("lodash", "4.17.20", "4.17.21", kind: :patch, severity: "high")]
    )
    patch_spec = spec(
      branch: "importmap-updates/patch",
      packages: [
        package_bump("axios", "1.7.0", "1.7.1"),
        package_bump("stimulus", "3.2.1", "3.2.2")
      ]
    )
    major_spec = spec(
      branch: "importmap-updates/major-react",
      kind: :major,
      packages: [package_bump("react", "18.2.0", "19.0.0", kind: :major)]
    )

    existing_security = existing_pr(
      number: 100,
      branch: "importmap-updates/security-lodash",
      packages: [["lodash", "4.17.20", "4.17.21"]]
    )
    existing_patch = existing_pr(
      number: 101,
      branch: "importmap-updates/patch",
      packages: [["stimulus", "3.2.1", "3.2.2"]]   # axios will be added
    )
    orphan_minor = existing_pr(
      number: 102,
      branch: "importmap-updates/minor",
      packages: [["zog", "1.1.0", "1.2.0"]]
    )
    foreign = ExistingPR.new(
      number: 103,
      branch: "importmap-updates/security-something",
      body: "No metadata block.",
      title: "Hand-rolled"
    )

    result = reconcile(
      plan_specs: [security_spec, patch_spec, major_spec],
      existing_prs: [existing_security, existing_patch, orphan_minor, foreign]
    )

    assert_equal 1, result.noops.size
    assert_equal 100, result.noops.first.existing_pr.number

    assert_equal 1, result.force_pushes.size
    assert_equal 101, result.force_pushes.first.existing_pr.number
    assert_includes result.force_pushes.first.reason, "axios"

    assert_equal 1, result.opens.size
    assert_equal "importmap-updates/major-react", result.opens.first.pr_spec.branch

    assert_equal 1, result.closes.size
    assert_equal 102, result.closes.first.existing_pr.number

    assert_equal [foreign], result.ignored
  end

  # ---- defensive: existing PR with present-but-broken metadata ----

  def test_treats_pr_with_unparseable_metadata_block_as_foreign
    body = <<~BODY
      <!-- importmap-update:metadata
      not: valid: yaml: at: all
        : :
      -->
    BODY
    pr = ExistingPR.new(number: 70, branch: "importmap-updates/patch", body: body, title: "...")
    result = reconcile(plan_specs: [], existing_prs: [pr])

    # Better to leave it alone than to misinterpret and close it.
    assert_empty result.actions
    assert_equal 1, result.ignored.size
  end
end
