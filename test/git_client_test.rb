# frozen_string_literal: true

require_relative "test_helper"
require "minitest/mock"
require "git"
require "git_client"

class GitClientTest < Minitest::Test
  GitClient = ImportmapUpdate::GitClient

  AUTHOR_NAME = "Test Bot"
  AUTHOR_EMAIL = "bot@example.com"
  AUTHOR_STRING = "Test Bot <bot@example.com>"

  def setup
    @repo = Minitest::Mock.new
    @client = GitClient.new(repo: @repo, author_name: AUTHOR_NAME, author_email: AUTHOR_EMAIL)
  end

  def teardown
    assert_mock @repo
  end

  # ---- checkout_fresh_branch ----

  def test_checkout_fresh_branch_creates_branch_when_it_does_not_exist
    @repo.expect(:fetch, nil, ["origin"], ref: "main")
    @repo.expect(:checkout, nil) { raise Git::Error }
    @repo.expect(:checkout, nil, ["importmap-updates/patch"],
      new_branch: true, start_point: "origin/main")

    assert_nil @client.checkout_fresh_branch(branch: "importmap-updates/patch", base: "main")
  end

  def test_checkout_fresh_branch_resets_existing_branch_to_base
    @repo.expect(:fetch, nil, ["origin"], ref: "main")
    @repo.expect(:checkout, nil, ["importmap-updates/patch"])
    @repo.expect(:reset_hard, nil, ["origin/main"])

    assert_nil @client.checkout_fresh_branch(branch: "importmap-updates/patch", base: "main")
  end

  # ---- commit_changes ----

  def test_commit_changes_stages_and_commits_returning_true
    @repo.expect(:add, nil, [["config/importmap.rb", "vendor/javascript"]])
    @repo.expect(:commit, nil, ["Bump lodash from 4.17.20 to 4.17.21"],
      author: AUTHOR_STRING)

    assert_equal true, @client.commit_changes(message: "Bump lodash from 4.17.20 to 4.17.21")
  end

  def test_commit_changes_returns_false_when_nothing_to_commit
    @repo.expect(:add, nil, [["config/importmap.rb", "vendor/javascript"]])
    @repo.expect(:commit, nil) do |_msg, **_opts|
      raise git_failed_error("nothing to commit, working tree clean")
    end

    assert_equal false, @client.commit_changes(message: "irrelevant")
  end

  def test_commit_changes_re_raises_unexpected_git_errors
    @repo.expect(:add, nil, [["config/importmap.rb", "vendor/javascript"]])
    @repo.expect(:commit, nil) do |_msg, **_opts|
      raise git_failed_error("lock file exists")
    end

    assert_raises(Git::FailedError) do
      @client.commit_changes(message: "irrelevant")
    end
  end

  # ---- push ----

  def test_push_without_force
    @repo.expect(:push, nil, ["origin", "importmap-updates/patch"], force: false)
    assert_nil @client.push(branch: "importmap-updates/patch")
  end

  def test_push_with_force
    @repo.expect(:push, nil, ["origin", "importmap-updates/patch"], force: true)
    assert_nil @client.push(branch: "importmap-updates/patch", force: true)
  end

  private

  # Git::FailedError wraps a Git::CommandLineResult which needs a status
  # object. We build the minimum required for e.result.stderr to work.
  def git_failed_error(stderr)
    fake_status = Struct.new(:exitstatus, :pid) { def to_s = "pid #{pid} exit #{exitstatus}" }.new(1, 0)
    result = Git::CommandLineResult.new(["git", "commit"], fake_status, "", stderr)
    Git::FailedError.new(result)
  end
end
