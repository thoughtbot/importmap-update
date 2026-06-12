# frozen_string_literal: true

require_relative "test_helper"
require "executor"
require "planner"
require "reconciler"

class ExecutorTest < Minitest::Test
  Executor = ImportmapUpdate::Executor
  Planner = ImportmapUpdate::Planner
  Reconciler = ImportmapUpdate::Reconciler
  Commands = ImportmapUpdate::Commands


  class FakeGh
    attr_reader :created, :updated, :closed
    attr_accessor :next_pr_number

    def initialize
      @created = []
      @updated = []
      @closed = []
      @next_pr_number = 1000
    end

    def ensure_labels(labels)
    end

    def create_pr(branch:, base:, title:, body:, labels: [])
      @created << {branch:, base:, title:, body:, labels:}
      n = @next_pr_number
      @next_pr_number += 1
      n
    end

    def update_pr(number:, title:, body:)
      @updated << {number:, title:, body:}
      nil
    end

    def close_pr(number:, comment: nil)
      @closed << {number:, comment:}
      nil
    end
  end

  class FakeGit
    attr_reader :checkouts, :commits, :pushes
    attr_accessor :commit_returns

    def initialize
      @checkouts = []
      @commits = []
      @pushes = []
      @commit_returns = true  # tests set false to simulate "nothing to commit"
    end

    def checkout_fresh_branch(branch:, base:)
      @checkouts << {branch:, base:}

      nil
    end

    def commit_changes(message:)
      @commits << message
      @commit_returns
    end

    def push(branch:, force: false)
      @pushes << {branch:, force:}

      nil
    end
  end

  class FakeOpen3
    Fixture = Data.define(:pattern, :stdout, :stderr, :exit_code)
    ProcessStatus = Data.define(:exitstatus)

    attr_reader :calls

    def initialize(fixtures = [])
      @fixtures = fixtures
      @calls = []
    end

    def add(pattern:, stdout: "", stderr: "", exit_code: 0)
      @fixtures << Fixture.new(pattern:, stdout:, stderr:, exit_code:)
    end

    def capture3(*argv, **)
      @calls << argv
      match = @fixtures.find { pattern_matches?(_1.pattern, argv) }

      if match.nil?
        raise "No fixture matched argv: #{argv.inspect}.\nRegistered patterns: #{@fixtures.map(&:pattern).inspect}"
      end

      [match.stdout, match.stderr, ProcessStatus.new(exitstatus: match.exit_code)]
    end

    private

    def pattern_matches?(pattern, argv)
      return false unless pattern.is_a?(Array)
      return false unless pattern.size == argv.size

      pattern.zip(argv).all? do |pat, arg|
        case pat
        when Regexp then pat.match?(arg)
        else pat == arg
        end
      end
    end
  end

  def bump(name, from, to, kind: :patch, severity: nil)
    advisory = severity ? {severity:} : nil

    Planner::PackageBump.new(name:, from:, to:, semver_kind: kind, advisory:)
  end

  def spec(branch:, packages:, kind: :patch, title: "spec title")
    Planner::PRSpec.new(
      kind:, packages:, branch:, title:,
      metadata: {
        tool: "importmap-update", kind:,
        packages: packages.map { |p| {name: p.name, from: p.from, to: p.to, semver_kind: p.semver_kind} }
      }
    )
  end

  def existing_pr(number:, branch:)
    Reconciler::ExistingPR.new(number:, branch:, body: "", title: "old")
  end

  def setup
    @gh = FakeGh.new
    @git = FakeGit.new
    @open3 = FakeOpen3.new
    @runner = Commands::ShellRunner.new(open3: @open3)
  end

  def make_executor(dry_run: false)
    Executor.new(
      gh: @gh, git: @git, runner: @runner,
      base_branch: "main",
      commit_message_prefix: "",
      labels: %w[dependencies],
      dry_run:,
      body_renderer: ->(s) { "body for #{s.branch}" }
    )
  end

  def test_noop_action_records_success_without_touching_git_or_gh
    s = spec(branch: "importmap-updates/patch", packages: [bump("lodash", "4.17.20", "4.17.21")])
    e = existing_pr(number: 1, branch: "importmap-updates/patch")
    action = Reconciler::Action.new(type: :noop, pr_spec: s, existing_pr: e)

    report = make_executor.call([action])

    assert_equal 1, report.outcomes.size
    assert_equal :noop, report.outcomes.first.type
    assert_predicate report.outcomes.first, :success?
    assert_empty @git.checkouts
    assert_empty @gh.created
  end

  def test_open_action_pins_pushes_and_creates_pr
    s = spec(
      branch: "importmap-updates/patch",
      packages: [bump("lodash", "4.17.20", "4.17.21")],
      title: "Bump lodash 4.17.20 → 4.17.21"
    )
    @open3.add(pattern: ["bin/importmap", "pin", "lodash@4.17.21"], stdout: "pinned\n")
    action = Reconciler::Action.new(type: :open, pr_spec: s)

    @gh.next_pr_number = 555
    report = make_executor.call([action])

    assert_predicate report.outcomes.first, :success?
    assert_equal 555, report.outcomes.first.pr_number

    assert_equal [{branch: "importmap-updates/patch", base: "main"}], @git.checkouts
    assert_equal 1, @git.commits.size
    assert_equal [{branch: "importmap-updates/patch", force: true}], @git.pushes

    assert_equal 1, @gh.created.size
    assert_equal "Bump lodash 4.17.20 → 4.17.21", @gh.created.first[:title]
    assert_equal "body for importmap-updates/patch", @gh.created.first[:body]
    assert_equal %w[dependencies], @gh.created.first[:labels]
  end

  def test_open_action_skips_pr_creation_when_pinning_produced_no_changes
    s = spec(branch: "importmap-updates/patch", packages: [bump("lodash", "4.17.20", "4.17.21")])
    @open3.add(pattern: ["bin/importmap", "pin", "lodash@4.17.21"], stdout: "pinned\n")
    @git.commit_returns = false

    report = make_executor.call([Reconciler::Action.new(type: :open, pr_spec: s)])

    assert_predicate report.outcomes.first, :skipped?
    assert_empty @gh.created
    assert_empty @git.pushes
  end

  def test_force_push_updates_branch_then_edits_pr
    s = spec(
      branch: "importmap-updates/patch",
      packages: [bump("lodash", "4.17.20", "4.17.21"), bump("axios", "1.7.0", "1.7.1")]
    )
    e = existing_pr(number: 42, branch: "importmap-updates/patch")
    @open3.add(pattern: ["bin/importmap", "pin", "lodash@4.17.21"], stdout: "")
    @open3.add(pattern: ["bin/importmap", "pin", "axios@1.7.1"], stdout: "")

    action = Reconciler::Action.new(type: :force_push, pr_spec: s, existing_pr: e, reason: "axios added")
    report = make_executor.call([action])

    assert_predicate report.outcomes.first, :success?
    assert_equal [{branch: "importmap-updates/patch", force: true}], @git.pushes
    assert_equal 1, @gh.updated.size
    assert_equal 42, @gh.updated.first[:number]
  end

  def test_close_action_closes_pr_with_reason_as_comment
    e = existing_pr(number: 99, branch: "importmap-updates/old")
    action = Reconciler::Action.new(type: :close, existing_pr: e, reason: "no longer outdated")

    report = make_executor.call([action])

    assert_predicate report.outcomes.first, :success?
    assert_equal [{number: 99, comment: "no longer outdated"}], @gh.closed
  end

  def test_dry_run_records_skipped_outcomes_and_invokes_nothing
    s_open = spec(branch: "importmap-updates/patch", packages: [bump("lodash", "4.17.20", "4.17.21")])
    s_fp = spec(branch: "importmap-updates/minor", packages: [bump("stim", "3.2.1", "3.3.0", kind: :minor)])
    e_fp = existing_pr(number: 5, branch: "importmap-updates/minor")
    e_cl = existing_pr(number: 6, branch: "importmap-updates/major-vue")

    actions = [
      Reconciler::Action.new(type: :open, pr_spec: s_open),
      Reconciler::Action.new(type: :force_push, pr_spec: s_fp, existing_pr: e_fp, reason: "..."),
      Reconciler::Action.new(type: :close, existing_pr: e_cl, reason: "...")
    ]

    report = make_executor(dry_run: true).call(actions)

    assert(report.outcomes.all?(&:skipped?), "all outcomes should be :skipped in dry run")
    assert_empty @git.checkouts
    assert_empty @git.commits
    assert_empty @git.pushes
    assert_empty @gh.created
    assert_empty @gh.updated
    assert_empty @gh.closed
    assert(report.outcomes.all? { |o| o.detail.start_with?("DRY RUN") })
    open_outcome = report.outcomes.find { |o| o.type == :open }
    fp_outcome = report.outcomes.find { |o| o.type == :force_push }
    assert_includes open_outcome.detail, "lodash"
    assert_includes fp_outcome.detail, "stim"
  end

  def test_one_failing_action_does_not_block_subsequent_actions
    failing = spec(branch: "importmap-updates/patch", packages: [bump("broken", "1.0.0", "2.0.0")])
    succeeding = spec(branch: "importmap-updates/minor", packages: [bump("ok", "1.0.0", "1.1.0", kind: :minor)])

    @open3.add(pattern: ["bin/importmap", "pin", "ok@1.1.0"], stdout: "")
    @open3.add(pattern: ["bin/importmap", "pin", "broken@2.0.0"], stderr: "boom", exit_code: 1)

    actions = [
      Reconciler::Action.new(type: :open, pr_spec: failing),
      Reconciler::Action.new(type: :open, pr_spec: succeeding)
    ]
    report = make_executor.call(actions)

    assert_predicate report.outcomes[0], :failed?
    assert_predicate report.outcomes[1], :success?
    assert_equal 1, @gh.created.size
    refute_empty report.warnings
  end

  def test_partial_group_failure_keeps_what_was_pinned_successfully
    s = spec(
      branch: "importmap-updates/patch",
      packages: [
        bump("a", "1.0.0", "1.0.1"),
        bump("b", "1.0.0", "1.0.1"),  # this one will fail
        bump("c", "1.0.0", "1.0.1")
      ]
    )

    @open3.add(pattern: ["bin/importmap", "pin", "a@1.0.1"], stdout: "")
    @open3.add(pattern: ["bin/importmap", "pin", "b@1.0.1"], stderr: "boom", exit_code: 1)
    @open3.add(pattern: ["bin/importmap", "pin", "c@1.0.1"], stdout: "")

    report = make_executor.call([Reconciler::Action.new(type: :open, pr_spec: s)])

    assert_predicate report.outcomes.first, :success?
    assert_equal 1, @gh.created.size
  end
end
