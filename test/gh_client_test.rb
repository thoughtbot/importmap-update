# frozen_string_literal: true

require_relative "test_helper"
require "gh_client"
require "commands"

class GhClientTest < Minitest::Test
  GhClient = Importmap::Update::GhClient
  Commands = Importmap::Update::Commands

  REPO = "example-org/example-repo"

  def setup
    @runner = Commands::FixtureRunner.new
    @client = GhClient.new(repo: REPO, runner: @runner)
  end

  # ---- list_open_prs ----

  def test_list_open_prs_invokes_gh_with_expected_arguments
    @runner.add(
      pattern: [
        "gh", "pr", "list", "--repo", REPO,
        "--state", "open",
        "--search", "head:importmap-updates/",
        "--limit", "100",
        "--json", "number,headRefName,title,body"
      ],
      stdout: +"[]"
    )
    @client.list_open_prs(branch_prefix: "importmap-updates")
    assert_equal 1, @runner.calls.size
  end

  def test_list_open_prs_parses_a_realistic_response
    @runner.add(
      pattern: [
        "gh", "pr", "list", "--repo", REPO,
        "--state", "open",
        "--search", "head:importmap-updates/",
        "--limit", "100",
        "--json", "number,headRefName,title,body"
      ],
      stdout: fixture("gh_pr_list_mixed.json")
    )

    prs = @client.list_open_prs(branch_prefix: "importmap-updates")

    assert_equal 3, prs.size
    assert_equal 100, prs[0].number
    assert_equal "importmap-updates/security-lodash", prs[0].branch
    assert_includes prs[0].body, "importmap-update:metadata"

    # The hand-written foreign PR comes through too — filtering it as
    # "foreign" is the reconciler's job, not the client's.
    assert_equal 102, prs[2].number
    refute_includes prs[2].body, "importmap-update:metadata"
  end

  def test_list_open_prs_filters_out_branches_that_dont_actually_start_with_the_prefix
    # GitHub's search syntax for `head:` is a prefix match, but it's a
    # *search*, not a strict filter — partial matches can leak through.
    # Belt and suspenders: re-filter client-side.
    @runner.add(
      pattern: [
        "gh", "pr", "list", "--repo", REPO,
        "--state", "open",
        "--search", "head:importmap-updates/",
        "--limit", "100",
        "--json", "number,headRefName,title,body"
      ],
      stdout: +<<~JSON
        [
          { "number": 1, "headRefName": "importmap-updates/patch", "title": "ours", "body": "" },
          { "number": 2, "headRefName": "importmap-updates-related-feature", "title": "leak", "body": "" }
        ]
      JSON
    )
    prs = @client.list_open_prs(branch_prefix: "importmap-updates")
    assert_equal [1], prs.map(&:number)
  end

  def test_list_open_prs_raises_on_invalid_json
    @runner.add(
      pattern: [
        "gh", "pr", "list", "--repo", REPO,
        "--state", "open",
        "--search", "head:importmap-updates/",
        "--limit", "100",
        "--json", "number,headRefName,title,body"
      ],
      stdout: +"not actually json"
    )
    err = assert_raises(Commands::CommandError) do
      @client.list_open_prs(branch_prefix: "importmap-updates")
    end
    assert_includes err.message, "Invalid JSON from gh"
  end

  def test_list_open_prs_propagates_gh_failure
    @runner.add(
      pattern: [
        "gh", "pr", "list", "--repo", REPO,
        "--state", "open",
        "--search", "head:importmap-updates/",
        "--limit", "100",
        "--json", "number,headRefName,title,body"
      ],
      stderr: "auth required",
      exit_code: 1
    )
    err = assert_raises(Commands::CommandError) do
      @client.list_open_prs(branch_prefix: "importmap-updates")
    end
    assert_includes err.message, "auth required"
  end

  # ---- ensure_labels ----

  def test_ensure_labels_is_a_no_op_when_labels_is_empty
    @client.ensure_labels([])
    assert_equal 0, @runner.calls.size
  end

  def test_ensure_labels_creates_missing_labels
    @runner.add(
      pattern: ["gh", "label", "list", "--repo", REPO, "--json", "name", "--limit", "200"],
      stdout: +%([{"name":"dependencies"}])
    )
    @runner.add(
      pattern: ["gh", "label", "create", "javascript", "--repo", REPO, "--color", "0075ca"],
      stdout: +""
    )
    @client.ensure_labels(%w[dependencies javascript])
    assert_equal 2, @runner.calls.size
  end

  def test_ensure_labels_skips_labels_that_already_exist
    @runner.add(
      pattern: ["gh", "label", "list", "--repo", REPO, "--json", "name", "--limit", "200"],
      stdout: +%([{"name":"dependencies"},{"name":"javascript"}])
    )
    @client.ensure_labels(%w[dependencies javascript])
    assert_equal 1, @runner.calls.size
  end

  def test_ensure_labels_tolerates_gh_label_list_failure
    @runner.add(
      pattern: ["gh", "label", "list", "--repo", REPO, "--json", "name", "--limit", "200"],
      stderr: "not found",
      exit_code: 1
    )
    @runner.add(
      pattern: ["gh", "label", "create", "dependencies", "--repo", REPO, "--color", "0075ca"],
      stdout: +""
    )
    @client.ensure_labels(%w[dependencies])
    assert_equal 2, @runner.calls.size
  end

  # ---- create_pr ----

  def test_create_pr_invokes_gh_with_title_body_branch_and_base
    @runner.add(
      pattern: [
        "gh", "pr", "create",
        "--repo", REPO,
        "--head", "importmap-updates/patch",
        "--base", "main",
        "--title", "chore(deps): patch updates",
        "--body", "PR body text"
      ],
      stdout: fixture("gh_pr_create_success.txt")
    )

    number = @client.create_pr(
      branch: "importmap-updates/patch",
      base: "main",
      title: "chore(deps): patch updates",
      body: "PR body text"
    )
    assert_equal 123, number
  end

  def test_create_pr_passes_labels_individually
    # `gh pr create` accepts repeated --label flags; we want each label
    # on its own --label so values containing commas don't get split.
    @runner.add(
      pattern: [
        "gh", "pr", "create",
        "--repo", REPO,
        "--head", "importmap-updates/patch",
        "--base", "main",
        "--title", "t",
        "--body", "b",
        "--label", "dependencies",
        "--label", "javascript"
      ],
      stdout: "https://github.com/example-org/example-repo/pull/200\n"
    )
    number = @client.create_pr(
      branch: "importmap-updates/patch",
      base: "main",
      title: "t",
      body: "b",
      labels: %w[dependencies javascript]
    )
    assert_equal 200, number
  end

  def test_create_pr_propagates_branch_taken_failure_with_clear_message
    @runner.add(
      pattern: [
        "gh", "pr", "create",
        "--repo", REPO,
        "--head", "importmap-updates/patch",
        "--base", "main",
        "--title", "t",
        "--body", "b"
      ],
      stderr: fixture("gh_pr_create_branch_taken.txt"),
      exit_code: 1
    )
    err = assert_raises(Commands::CommandError) do
      @client.create_pr(branch: "importmap-updates/patch", base: "main", title: "t", body: "b")
    end
    assert_includes err.message, "already exists"
  end

  # ---- update_pr ----

  def test_update_pr_edits_title_and_body
    @runner.add(
      pattern: [
        "gh", "pr", "edit", "42",
        "--repo", REPO,
        "--title", "new title",
        "--body", "new body"
      ],
      stdout: ""
    )
    assert_nil @client.update_pr(number: 42, title: "new title", body: "new body")
  end

  # ---- close_pr ----

  def test_close_pr_leaves_comment_then_closes_when_comment_is_given
    @runner.add(
      pattern: ["gh", "pr", "comment", "99", "--repo", REPO, "--body", "no longer needed"],
      stdout: ""
    )
    @runner.add(
      pattern: ["gh", "pr", "close", "99", "--repo", REPO],
      stdout: ""
    )
    @client.close_pr(number: 99, comment: "no longer needed")
    assert_equal 2, @runner.calls.size
    # Comment must come before close so reviewers see the explanation
    # alongside the closed status.
    assert_equal "comment", @runner.calls[0][2]
    assert_equal "close", @runner.calls[1][2]
  end

  def test_close_pr_skips_comment_step_when_no_comment_provided
    @runner.add(pattern: ["gh", "pr", "close", "99", "--repo", REPO], stdout: "")
    @client.close_pr(number: 99)
    assert_equal 1, @runner.calls.size
    assert_equal "close", @runner.calls[0][2]
  end

  def test_close_pr_skips_comment_step_when_comment_is_empty
    # Defensive: a caller passing comment: "" shouldn't post an empty comment.
    @runner.add(pattern: ["gh", "pr", "close", "99", "--repo", REPO], stdout: "")
    @client.close_pr(number: 99, comment: "")
    assert_equal 1, @runner.calls.size
  end
end
