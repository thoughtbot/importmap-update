# frozen_string_literal: true

require_relative "test_helper"
require "minitest/mock"
require "github_client"

class GitHubClientTest < Minitest::Test
  GitHubClient = ImportmapUpdate::GitHubClient
  Reconciler = ImportmapUpdate::Reconciler

  REPO = "example-org/example-repo"

  def setup
    @octokit = Minitest::Mock.new
    @client = GitHubClient.new(repo: REPO, token: "unused-in-tests", client: @octokit)
  end

  def teardown
    assert_mock @octokit
  end

  # ---- list_open_prs ----

  def test_list_open_prs_returns_prs_matching_prefix
    @octokit.expect(:pull_requests, [
      pr_stub(number: 100, ref: "importmap-updates/security-lodash", title: "Security", body: "<!-- importmap-update:metadata -->"),
      pr_stub(number: 101, ref: "importmap-updates/patch", title: "Patch", body: ""),
      pr_stub(number: 102, ref: "other-branch", title: "Unrelated", body: "")
    ], [REPO], state: "open", per_page: 100)

    prs = @client.list_open_prs(branch_prefix: "importmap-updates")

    assert_equal 2, prs.size
    assert_equal 100, prs[0].number
    assert_equal "importmap-updates/security-lodash", prs[0].branch
    assert_includes prs[0].body, "importmap-update:metadata"
    assert_equal 101, prs[1].number
  end

  def test_list_open_prs_filters_out_branches_without_exact_prefix_slash
    # A branch named "importmap-updates-related-feature" must not leak through.
    @octokit.expect(:pull_requests, [
      pr_stub(number: 1, ref: "importmap-updates/patch", title: "ours", body: ""),
      pr_stub(number: 2, ref: "importmap-updates-related-feature", title: "leak", body: "")
    ], [REPO], state: "open", per_page: 100)

    prs = @client.list_open_prs(branch_prefix: "importmap-updates")
    assert_equal [1], prs.map(&:number)
  end

  def test_list_open_prs_returns_empty_when_no_open_prs
    @octokit.expect(:pull_requests, [], [REPO], state: "open", per_page: 100)
    assert_equal [], @client.list_open_prs(branch_prefix: "importmap-updates")
  end

  # ---- create_pr ----

  def test_create_pr_returns_pr_number
    @octokit.expect(:create_pull_request,
      pr_stub(number: 123),
      [REPO, "main", "importmap-updates/patch", "chore(deps): patch updates", "PR body text"])
    number = @client.create_pr(branch: "importmap-updates/patch", base: "main", title: "chore(deps): patch updates", body: "PR body text")
    assert_equal 123, number
  end

  def test_create_pr_adds_labels_when_given
    @octokit.expect(:create_pull_request, pr_stub(number: 200),
      [REPO, "main", "importmap-updates/patch", "t", "b"])
    @octokit.expect(:add_labels_to_an_issue, nil,
      [REPO, 200, %w[dependencies javascript]])
    number = @client.create_pr(branch: "importmap-updates/patch", base: "main", title: "t", body: "b", labels: %w[dependencies javascript])
    assert_equal 200, number
  end

  def test_create_pr_skips_label_call_when_no_labels
    @octokit.expect(:create_pull_request, pr_stub(number: 42),
      [REPO, "main", "importmap-updates/patch", "t", "b"])
    # No add_labels_to_an_issue call expected.
    @client.create_pr(branch: "importmap-updates/patch", base: "main", title: "t", body: "b")
  end

  # ---- ensure_labels ----

  def test_ensure_labels_is_a_no_op_when_labels_is_empty
    # No octokit calls expected.
    @client.ensure_labels([])
  end

  def test_ensure_labels_creates_missing_labels
    @octokit.expect(:labels, [label_stub("dependencies")], [REPO])
    @octokit.expect(:create_label, nil, [REPO, "javascript", "0075ca"])
    @client.ensure_labels(%w[dependencies javascript])
  end

  def test_ensure_labels_skips_labels_that_already_exist
    @octokit.expect(:labels, [label_stub("dependencies"), label_stub("javascript")], [REPO])
    # No create_label calls expected.
    @client.ensure_labels(%w[dependencies javascript])
  end

  def test_ensure_labels_tolerates_labels_list_failure
    @octokit.expect(:labels, nil) { |_repo| raise Octokit::Error }
    @octokit.expect(:create_label, nil, [REPO, "dependencies", "0075ca"])
    @client.ensure_labels(%w[dependencies])
  end

  # ---- update_pr ----

  def test_update_pr_edits_title_and_body
    @octokit.expect(:update_pull_request, nil, [REPO, 42], title: "new title", body: "new body")
    assert_nil @client.update_pr(number: 42, title: "new title", body: "new body")
  end

  # ---- close_pr ----

  def test_close_pr_leaves_comment_then_closes_when_comment_is_given
    order = []
    @octokit.expect(:add_comment, nil) do |repo, number, comment|
      order << :comment
      repo == REPO && number == 99 && comment == "no longer needed"
    end
    @octokit.expect(:close_pull_request, nil) do |repo, number|
      order << :close
      repo == REPO && number == 99
    end
    @client.close_pr(number: 99, comment: "no longer needed")
    assert_equal [:comment, :close], order
  end

  def test_close_pr_skips_comment_step_when_no_comment_provided
    @octokit.expect(:close_pull_request, nil, [REPO, 99])
    @client.close_pr(number: 99)
  end

  def test_close_pr_skips_comment_step_when_comment_is_empty
    @octokit.expect(:close_pull_request, nil, [REPO, 99])
    @client.close_pr(number: 99, comment: "")
  end

  private

  def pr_stub(number:, ref: "importmap-updates/patch", title: "PR title", body: "")
    head = Struct.new(:ref).new(ref)
    Struct.new(:number, :head, :title, :body).new(number, head, title, body)
  end

  def label_stub(name)
    Struct.new(:name).new(name)
  end
end
