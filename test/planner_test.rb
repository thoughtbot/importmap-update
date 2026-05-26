# frozen_string_literal: true

require_relative "test_helper"
require "planner"
require "config"
require "parsers/outdated_parser"
require "parsers/audit_parser"

class PlannerTest < Minitest::Test
  Planner = ImportmapUpdate::Planner
  Config = ImportmapUpdate::Config
  Outdated = ImportmapUpdate::Parsers::OutdatedParser::OutdatedPackage
  Vuln = ImportmapUpdate::Parsers::AuditParser::Vulnerability

  # ---- helpers ----

  def outdated(name, from, to, error: nil)
    Outdated.new(name:, current: from, latest: to, error:)
  end

  def vuln(name, severity, vulnerable: "<#{name}", advisory: "Vulnerability in #{name}")
    Vuln.new(name:, severity:, vulnerable_versions: vulnerable, advisory:)
  end

  def plan_with(outdated:, vulnerabilities: [], config: Config.default)
    Planner.new(outdated:, vulnerabilities:, config:).call
  end

  # ---- happy paths: grouping ----

  def test_groups_patch_bumps_into_a_single_pr_by_default
    plan = plan_with(outdated: [
      outdated("lodash", "4.17.20", "4.17.21"),
      outdated("axios", "1.7.0", "1.7.1")
    ])

    assert_equal 1, plan.pr_specs.size
    spec = plan.pr_specs.first
    assert_equal :patch, spec.kind
    assert_equal 2, spec.packages.size
    assert_equal %w[axios lodash], spec.packages.map(&:name)  # alphabetical
    assert_equal "importmap-updates/patch", spec.branch
    assert_match(/Patch updates \(2 packages\)/, spec.title)
  end

  def test_groups_minor_bumps_into_a_single_pr_by_default
    plan = plan_with(outdated: [
      outdated("stimulus", "3.2.1", "3.3.0")
    ])
    assert_equal 1, plan.pr_specs.size
    assert_equal :minor, plan.pr_specs.first.kind
  end

  def test_emits_one_pr_per_major_bump_by_default
    plan = plan_with(outdated: [
      outdated("react", "18.2.0", "19.0.0"),
      outdated("vue", "2.7.0", "3.0.0")
    ])
    assert_equal 2, plan.pr_specs.size
    assert(plan.pr_specs.all? { |s| s.kind == :major })
    assert_equal %w[react vue], plan.pr_specs.map { |s| s.packages.first.name }
    assert_equal "importmap-updates/major-react", plan.pr_specs[0].branch
    assert_equal "importmap-updates/major-vue", plan.pr_specs[1].branch
  end

  def test_grouped_pr_with_single_package_uses_package_specific_title
    # Cosmetic but real: "patch updates (1 packages)" reads badly.
    plan = plan_with(outdated: [outdated("lodash", "4.17.20", "4.17.21")])
    assert_equal "Bump lodash 4.17.20 → 4.17.21", plan.pr_specs.first.title
  end

  # ---- security override ----

  def test_security_bumps_become_security_prs_regardless_of_semver_kind
    # lodash here is a patch bump, but the audit flags it. It should not
    # land in the grouped patch PR — it gets its own security PR.
    plan = plan_with(
      outdated: [
        outdated("lodash", "4.17.20", "4.17.21"),
        outdated("axios", "1.7.0", "1.7.1")
      ],
      vulnerabilities: [vuln("lodash", "high")]
    )

    assert_equal 2, plan.pr_specs.size

    security = plan.pr_specs.find(&:security?)
    refute_nil security
    assert_equal "importmap-updates/security-lodash", security.branch
    assert_equal "lodash", security.packages.first.name
    assert_equal "high", security.packages.first.advisory[:severity]

    patch = plan.pr_specs.find { |s| s.kind == :patch }
    refute_nil patch
    assert_equal %w[axios], patch.packages.map(&:name)
  end

  def test_security_pr_metadata_records_underlying_semver_kind
    # A reviewer looking at a security PR for a major bump needs to know
    # they're getting breaking changes along with the fix.
    plan = plan_with(
      outdated: [outdated("react", "18.2.0", "19.0.0")],
      vulnerabilities: [vuln("react", "critical")]
    )
    spec = plan.pr_specs.first
    assert_equal :security, spec.kind
    assert_equal :major, spec.packages.first.semver_kind
    pkg_meta = spec.metadata[:packages].first
    assert_equal :major, pkg_meta[:semver_kind]
    assert_equal "critical", pkg_meta[:severity]
  end

  def test_security_pr_title_includes_severity
    plan = plan_with(
      outdated: [outdated("lodash", "4.17.20", "4.17.21")],
      vulnerabilities: [vuln("lodash", "critical")]
    )
    assert_match(/security: critical/, plan.pr_specs.first.title)
  end

  def test_security_prs_sorted_by_severity_then_name
    plan = plan_with(
      outdated: [
        outdated("a-low", "1.0.0", "1.0.1"),
        outdated("z-high", "1.0.0", "1.0.1"),
        outdated("m-crit", "1.0.0", "1.0.1"),
        outdated("b-high", "1.0.0", "1.0.1")
      ],
      vulnerabilities: [
        vuln("a-low", "low"),
        vuln("z-high", "high"),
        vuln("m-crit", "critical"),
        vuln("b-high", "high")
      ]
    )
    names = plan.pr_specs.map { |s| s.packages.first.name }
    # critical first, then high (b before z alphabetically), then low.
    assert_equal %w[m-crit b-high z-high a-low], names
  end

  def test_duplicate_vulnerability_for_same_package_keeps_most_severe
    # Synthetic but defensible: if audit ever lists the same package twice
    # with different severities, take the worst.
    plan = plan_with(
      outdated: [outdated("lodash", "4.17.20", "4.17.21")],
      vulnerabilities: [
        vuln("lodash", "low"),
        vuln("lodash", "critical"),
        vuln("lodash", "moderate")
      ]
    )
    assert_equal "critical", plan.pr_specs.first.packages.first.advisory[:severity]
  end

  def test_vulnerability_for_package_not_in_outdated_is_ignored
    # importmap audit can sometimes flag a package that isn't strictly
    # "outdated" yet (audit checks for known-vulnerable ranges). Without
    # a target version to bump to, we can't act on it; the planner stays
    # silent rather than fabricating one.
    plan = plan_with(
      outdated: [],
      vulnerabilities: [vuln("ghost-pkg", "high")]
    )
    assert_empty plan.pr_specs
  end

  # ---- individual strategy ----

  def test_individual_patch_strategy_emits_one_pr_per_package
    config = Config.load(config_file(<<~YAML))
      version: 1
      grouping:
        patch:
          strategy: individual
    YAML
    plan = plan_with(
      outdated: [
        outdated("lodash", "4.17.20", "4.17.21"),
        outdated("axios", "1.7.0", "1.7.1")
      ],
      config:
    )
    assert_equal 2, plan.pr_specs.size
    assert(plan.pr_specs.all? { |s| s.kind == :patch })
    assert_equal "importmap-updates/patch-axios", plan.pr_specs[0].branch
    assert_equal "importmap-updates/patch-lodash", plan.pr_specs[1].branch
  end

  def test_grouped_major_strategy_combines_into_single_pr
    config = Config.load(config_file(<<~YAML))
      version: 1
      grouping:
        major:
          strategy: grouped
    YAML
    plan = plan_with(
      outdated: [
        outdated("react", "18.2.0", "19.0.0"),
        outdated("vue", "2.7.0", "3.0.0")
      ],
      config:
    )
    assert_equal 1, plan.pr_specs.size
    assert_equal :major, plan.pr_specs.first.kind
    assert_equal "importmap-updates/major", plan.pr_specs.first.branch
  end

  # ---- bump priority ordering ----

  def test_non_security_specs_ordered_major_then_minor_then_patch
    plan = plan_with(outdated: [
      outdated("lodash", "4.17.20", "4.17.21"),  # patch
      outdated("react", "18.2.0", "19.0.0"),   # major
      outdated("stimulus", "3.2.1", "3.3.0")    # minor
    ])
    kinds = plan.pr_specs.map(&:kind)
    assert_equal [:major, :minor, :patch], kinds
  end

  # ---- unparseable rows ----

  def test_unparseable_latest_version_is_skipped_with_a_warning
    plan = plan_with(outdated: [
      outdated("lodash", "4.17.20", "4.17.21"),
      outdated("broken-pkg", "1.0.0", nil, error: "Response code: 404")
    ])
    assert_equal 1, plan.pr_specs.size
    assert_equal "lodash", plan.pr_specs.first.packages.first.name
    assert(plan.warnings.any? { |w| w.include?("broken-pkg") && w.include?("404") })
  end

  def test_unclassifiable_version_pair_is_skipped_with_a_warning
    # Synthetic: a row where current and latest parse individually but semver
    # can't classify them (e.g. the gem returned a garbage string that
    # incidentally matched our cheap shape check).
    plan = plan_with(outdated: [
      outdated("weird", "garbage", "also-garbage")
    ])
    assert_empty plan.pr_specs
    assert(plan.warnings.any? { |w| w.include?("weird") })
  end

  # ---- empty cases ----

  def test_empty_outdated_yields_empty_plan
    plan = plan_with(outdated: [])
    assert_predicate plan, :empty?
    assert_empty plan.warnings
  end

  # ---- sanitization ----

  def test_branch_names_sanitize_scoped_package_names
    plan = plan_with(outdated: [
      outdated("@hotwired/stimulus", "3.2.1", "4.0.0")  # major → individual
    ])
    assert_equal "importmap-updates/major-hotwired-stimulus", plan.pr_specs.first.branch
  end

  def test_branch_names_sanitize_security_scoped_package_names
    plan = plan_with(
      outdated: [outdated("@hotwired/stimulus", "3.2.1", "3.2.2")],
      vulnerabilities: [vuln("@hotwired/stimulus", "moderate")]
    )
    assert_equal "importmap-updates/security-hotwired-stimulus", plan.pr_specs.first.branch
  end

  # ---- open-PR budget ----

  def test_open_pull_requests_limit_throttles_non_security_prs
    config = Config.load(config_file("version: 1\nopen_pull_requests_limit: 2\n"))
    # 3 majors → 3 individual PRs, but only 2 allowed.
    plan = plan_with(
      outdated: [
        outdated("a", "1.0.0", "2.0.0"),
        outdated("b", "1.0.0", "2.0.0"),
        outdated("c", "1.0.0", "2.0.0")
      ],
      config:
    )
    assert_equal 2, plan.pr_specs.size
    assert(plan.warnings.any? { |w| w.include?("Dropped 1") })
  end

  def test_security_prs_are_never_throttled_even_above_the_limit
    config = Config.load(config_file("version: 1\nopen_pull_requests_limit: 1\n"))
    plan = plan_with(
      outdated: [
        outdated("vulnA", "1.0.0", "1.0.1"),
        outdated("vulnB", "1.0.0", "1.0.1"),
        outdated("vulnC", "1.0.0", "1.0.1"),
        outdated("regular-patch", "1.0.0", "1.0.1")
      ],
      vulnerabilities: [
        vuln("vulnA", "high"),
        vuln("vulnB", "high"),
        vuln("vulnC", "high")
      ],
      config:
    )
    security = plan.pr_specs.select(&:security?)
    assert_equal 3, security.size, "security PRs should not be throttled"
    # Regular patch is dropped because security already exceeds the budget.
    refute(plan.pr_specs.any? { |s| s.kind == :patch })
    assert(plan.warnings.any? { |w| w.include?("Dropped 1") })
  end

  def test_budget_keeps_higher_priority_prs_when_truncating
    config = Config.load(config_file("version: 1\nopen_pull_requests_limit: 1\n"))
    plan = plan_with(
      outdated: [
        outdated("patch-pkg", "1.0.0", "1.0.1"),  # patch (grouped)
        outdated("major-pkg", "1.0.0", "2.0.0")  # major (individual)
      ],
      config:
    )
    # Major should win over patch when only 1 slot is available.
    assert_equal 1, plan.pr_specs.size
    assert_equal :major, plan.pr_specs.first.kind
  end

  # ---- metadata block (consumed by reconciler) ----

  def test_metadata_records_tool_marker_and_package_details
    plan = plan_with(outdated: [outdated("lodash", "4.17.20", "4.17.21")])
    meta = plan.pr_specs.first.metadata
    assert_equal "importmap-update", meta[:tool]
    assert_equal :patch, meta[:kind]
    assert_equal 1, meta[:packages].size
    assert_equal({name: "lodash", from: "4.17.20", to: "4.17.21", semver_kind: :patch},
      meta[:packages].first)
  end

  def test_metadata_for_grouped_pr_lists_all_packages_in_order
    plan = plan_with(outdated: [
      outdated("z-pkg", "1.0.0", "1.0.1"),
      outdated("a-pkg", "1.0.0", "1.0.1")
    ])
    meta = plan.pr_specs.first.metadata
    names = meta[:packages].map { |p| p[:name] }
    assert_equal %w[a-pkg z-pkg], names
  end

  # ---- helpers ----

  private

  def config_file(yaml_str)
    f = Tempfile.create(["config", ".yml"])
    f.write(yaml_str)
    f.close
    f.path
  end
end
