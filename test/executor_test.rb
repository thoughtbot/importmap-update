# frozen_string_literal: true

require_relative "test_helper"
require "executor"
require "planner"
require "reconciler"

class ExecutorTest < Minitest::Test
  Executor = Importmap::Update::Executor
  Planner = Importmap::Update::Planner
  Reconciler = Importmap::Update::Reconciler
  Commands = Importmap::Update::Commands

  # ---- fakes ----

  # Spy GhClient that records calls and lets tests configure the PR number
  # returned by create_pr.
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
      @created << {branch: branch, base: base, title: title, body: body, labels: labels}
      n = @next_pr_number
      @next_pr_number += 1
      n
    end

    def update_pr(number:, title:, body:)
      @updated << {number: number, title: title, body: body}
      nil
    end

    def close_pr(number:, comment: nil)
      @closed << {number: number, comment: comment}
      nil
    end
  end

  # Spy GitClient that records every git operation but does nothing.
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
      @checkouts << {branch: branch, base: base}
      nil
    end

    def commit_all(message:)
      @commits << message
      @commit_returns
    end

    def push(branch:, force: false)
      @pushes << {branch: branch, force: force}
      nil
    end
  end

  # ---- builders mirroring the planner's output ----

  def bump(name, from, to, kind: :patch, severity: nil)
    advisory = severity ? {severity: severity} : nil
    Planner::PackageBump.new(name: name, from: from, to: to, semver_kind: kind, advisory: advisory)
  end

  def spec(branch:, packages:, kind: :patch, title: "spec title")
    Planner::PRSpec.new(
      kind: kind, packages: packages, branch: branch, title: title,
      metadata: {
        tool: "importmap-update", kind: kind,
        packages: packages.map { |p| {name: p.name, from: p.from, to: p.to, semver_kind: p.semver_kind} }
      }
    )
  end

  def existing_pr(number:, branch:)
    Reconciler::ExistingPR.new(number: number, branch: branch, body: "", title: "old")
  end

  def setup
    @gh = FakeGh.new
    @git = FakeGit.new
    @runner = Commands::FixtureRunner.new
  end

  def make_executor(dry_run: false)
    Executor.new(
      gh: @gh, git: @git, runner: @runner,
      base_branch: "main",
      commit_message_prefix: "",
      labels: %w[dependencies],
      dry_run: dry_run,
      # Override the body renderer so tests don't depend on the exact body string.
      body_renderer: ->(s) { "body for #{s.branch}" }
    )
  end

  # ---- :noop ----

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

  # ---- :open ----

  def test_open_action_pins_pushes_and_creates_pr
    s = spec(
      branch: "importmap-updates/patch",
      packages: [bump("lodash", "4.17.20", "4.17.21")],
      title: "Bump lodash 4.17.20 → 4.17.21"
    )
    @runner.add(pattern: ["bin/importmap", "pin", "lodash@4.17.21"], stdout: "pinned\n")
    action = Reconciler::Action.new(type: :open, pr_spec: s)

    @gh.next_pr_number = 555
    report = make_executor.call([action])

    assert_predicate report.outcomes.first, :success?
    assert_equal 555, report.outcomes.first.pr_number

    # Git operations: checkout fresh, commit, push.
    assert_equal [{branch: "importmap-updates/patch", base: "main"}], @git.checkouts
    assert_equal 1, @git.commits.size
    assert_equal [{branch: "importmap-updates/patch", force: false}], @git.pushes

    # gh create_pr called with planner-provided title and rendered body.
    assert_equal 1, @gh.created.size
    assert_equal "Bump lodash 4.17.20 → 4.17.21", @gh.created.first[:title]
    assert_equal "body for importmap-updates/patch", @gh.created.first[:body]
    assert_equal %w[dependencies], @gh.created.first[:labels]
  end

  def test_open_action_skips_pr_creation_when_pinning_produced_no_changes
    # Race condition: the importmap was updated between the planner's read
    # and the executor's run, so `bin/importmap pin` is a no-op. The
    # `git diff --cached --quiet` step returns true; commit_all returns
    # false; we abort the open and record a skip.
    s = spec(branch: "importmap-updates/patch", packages: [bump("lodash", "4.17.20", "4.17.21")])
    @runner.add(pattern: ["bin/importmap", "pin", "lodash@4.17.21"], stdout: "pinned\n")
    @git.commit_returns = false

    report = make_executor.call([Reconciler::Action.new(type: :open, pr_spec: s)])

    assert_predicate report.outcomes.first, :skipped?
    assert_empty @gh.created
    assert_empty @git.pushes
  end

  # ---- :force_push ----

  def test_force_push_updates_branch_then_edits_pr
    s = spec(
      branch: "importmap-updates/patch",
      packages: [bump("lodash", "4.17.20", "4.17.21"), bump("axios", "1.7.0", "1.7.1")]
    )
    e = existing_pr(number: 42, branch: "importmap-updates/patch")
    @runner.add(pattern: ["bin/importmap", "pin", "lodash@4.17.21"], stdout: "")
    @runner.add(pattern: ["bin/importmap", "pin", "axios@1.7.1"], stdout: "")

    action = Reconciler::Action.new(type: :force_push, pr_spec: s, existing_pr: e, reason: "axios added")
    report = make_executor.call([action])

    assert_predicate report.outcomes.first, :success?
    assert_equal [{branch: "importmap-updates/patch", force: true}], @git.pushes
    assert_equal 1, @gh.updated.size
    assert_equal 42, @gh.updated.first[:number]
  end

  # ---- :close ----

  def test_close_action_closes_pr_with_reason_as_comment
    e = existing_pr(number: 99, branch: "importmap-updates/old")
    action = Reconciler::Action.new(type: :close, existing_pr: e, reason: "no longer outdated")

    report = make_executor.call([action])

    assert_predicate report.outcomes.first, :success?
    assert_equal [{number: 99, comment: "no longer outdated"}], @gh.closed
  end

  # ---- dry run ----

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
    # All "would have" details should be informative.
    assert(report.outcomes.all? { |o| o.detail.start_with?("DRY RUN") })
  end

  # ---- failure isolation ----

  def test_one_failing_action_does_not_block_subsequent_actions
    # First action will fail (no fixture matching → CommandError); second
    # should still run cleanly.
    failing = spec(branch: "importmap-updates/patch", packages: [bump("broken", "1.0.0", "2.0.0")])
    succeeding = spec(branch: "importmap-updates/minor", packages: [bump("ok", "1.0.0", "1.1.0", kind: :minor)])
    # No fixture for "broken" → bin/importmap will raise via FixtureRunner.
    @runner.add(pattern: ["bin/importmap", "pin", "ok@1.1.0"], stdout: "")

    # Suppress the "no fixture matched" RuntimeError from the FixtureRunner
    # by registering a failing fixture instead.
    @runner.add(pattern: ["bin/importmap", "pin", "broken@2.0.0"], stderr: "boom", exit_code: 1)

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
    # In a grouped PR with three packages, if the second fails but the
    # first and third succeed, we still want a PR with two packages —
    # not zero. The executor swallows mid-group failures and continues.
    s = spec(
      branch: "importmap-updates/patch",
      packages: [
        bump("a", "1.0.0", "1.0.1"),
        bump("b", "1.0.0", "1.0.1"),  # this one will fail
        bump("c", "1.0.0", "1.0.1")
      ]
    )
    @runner.add(pattern: ["bin/importmap", "pin", "a@1.0.1"], stdout: "")
    @runner.add(pattern: ["bin/importmap", "pin", "b@1.0.1"], stderr: "boom", exit_code: 1)
    @runner.add(pattern: ["bin/importmap", "pin", "c@1.0.1"], stdout: "")

    report = make_executor.call([Reconciler::Action.new(type: :open, pr_spec: s)])

    assert_predicate report.outcomes.first, :success?
    assert_equal 1, @gh.created.size
  end
end
