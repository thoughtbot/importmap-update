# frozen_string_literal: true

require "json"
require_relative "commands"
require_relative "reconciler"

module Importmap
  module Update
    # Wraps the `gh` CLI to give the executor a typed interface against
    # GitHub. Every method shells out through a Commands::ShellRunner (or a
    # FixtureRunner in tests). The wrapper does no orchestration logic —
    # that's the executor's job — but it does parse `gh`'s JSON output into
    # the structs the rest of the codebase already knows how to handle.
    #
    # Authentication: `gh` reads $GH_TOKEN or $GITHUB_TOKEN from the
    # environment. Inside a GitHub Action, ${{ secrets.GITHUB_TOKEN }}
    # passed as the `github-token` input is exposed as $GITHUB_TOKEN
    # in the shell where this runs.
    #
    # Repository: every `gh` invocation uses --repo OWNER/REPO so we don't
    # depend on the current directory being a git checkout pointed at the
    # right remote. The action.yml will pass $GITHUB_REPOSITORY through.
    class GhClient
      # We deliberately cap below GitHub's hard limit. A consumer with more
      # than this many bot-PRs open simultaneously has bigger problems
      # than the action can fix, and we surface a warning in that case.
      MAX_OPEN_PRS = 100

      def initialize(repo:, runner: Commands::ShellRunner.new)
        @repo = repo
        @runner = runner
      end

      # Returns an array of Reconciler::ExistingPR for all open PRs whose
      # branch starts with `branch_prefix`. The body field is included so
      # the reconciler can parse the metadata block out of it.
      def list_open_prs(branch_prefix:)
        # `head:foo/` is a GitHub-search-syntax prefix match. We can't use
        # `gh pr list --head` because that's an exact-match filter.
        result = @runner.run!(
          "gh", "pr", "list",
          "--repo", @repo,
          "--state", "open",
          "--search", "head:#{branch_prefix}/",
          "--limit", MAX_OPEN_PRS.to_s,
          "--json", "number,headRefName,title,body"
        )
        parse_pr_list(result.stdout, branch_prefix)
      end

      # Creates a new PR. Branch must already exist on the remote.
      # Returns the new PR's number.
      def create_pr(branch:, base:, title:, body:, labels: [])
        argv = [
          "gh", "pr", "create",
          "--repo", @repo,
          "--head", branch,
          "--base", base,
          "--title", title,
          "--body", body
        ]
        labels.each { |l| argv.push("--label", l) }
        result = @runner.run!(*argv)
        # `gh pr create` prints the PR URL on stdout; extract the number.
        result.stdout.strip[%r{/pull/(\d+)}, 1]&.to_i
      end

      # Ensures every label in +labels+ exists in the repo, creating any that
      # are missing. Called once before opening PRs so that `create_pr` never
      # fails with "label does not exist". Missing labels are created with a
      # neutral default color; existing labels are left untouched.
      def ensure_labels(labels)
        return if labels.empty?
        existing = list_label_names
        labels.each do |label|
          next if existing.include?(label)
          @runner.run(
            "gh", "label", "create", label,
            "--repo", @repo,
            "--color", "0075ca"
          )
        end
      end

      # Edits an existing PR's title and body. Used after force-pushing a
      # changed branch — the body must be re-rendered so the metadata
      # block reflects the new package set.
      def update_pr(number:, title:, body:)
        @runner.run!(
          "gh", "pr", "edit", number.to_s,
          "--repo", @repo,
          "--title", title,
          "--body", body
        )
        nil
      end

      # Closes a PR, optionally leaving a comment explaining why. The
      # comment is what tells reviewers "this was managed by the action
      # and was closed because…", which beats a silent close every time.
      def close_pr(number:, comment: nil)
        if comment && !comment.empty?
          @runner.run!(
            "gh", "pr", "comment", number.to_s,
            "--repo", @repo,
            "--body", comment
          )
        end
        @runner.run!(
          "gh", "pr", "close", number.to_s,
          "--repo", @repo
        )
        nil
      end

      private

      def list_label_names
        result = @runner.run(
          "gh", "label", "list",
          "--repo", @repo,
          "--json", "name",
          "--limit", "200"
        )
        return [] unless result.success?
        JSON.parse(result.stdout.force_encoding("UTF-8")).map { |l| l["name"] }
      rescue JSON::ParserError
        []
      end

      def parse_pr_list(stdout, branch_prefix)
        parsed = JSON.parse(stdout.force_encoding("UTF-8"))
        # `head:foo/` is a *search* term, not a strict filter — GitHub's
        # search can return PRs whose branch matches loosely. Belt and
        # suspenders: re-filter on the client side too.
        parsed
          .select { |pr| pr["headRefName"].to_s.start_with?("#{branch_prefix}/") }
          .map do |pr|
            Reconciler::ExistingPR.new(
              number: pr["number"],
              branch: pr["headRefName"],
              title: pr["title"],
              body: pr["body"].to_s
            )
          end
      rescue JSON::ParserError => e
        raise Commands::CommandError.new(
          ["gh", "pr", "list"],
          Commands::Result.new(
            stdout: stdout, stderr: "Invalid JSON from gh: #{e.message}", exit_code: 1
          )
        )
      end
    end
  end
end
