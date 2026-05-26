# frozen_string_literal: true

require "octokit"
require_relative "reconciler"

module ImportmapUpdate
  # Wraps the Octokit client to give the executor a typed interface against
  # GitHub. Every method calls the injected Octokit client (or a test double).
  # The wrapper does no orchestration logic — that's the executor's job — but
  # it does translate Octokit responses into the structs the rest of the
  # codebase already knows how to handle.
  #
  # Authentication: pass the token directly; inside a GitHub Action use
  # ${{ secrets.GITHUB_TOKEN }} exposed as $GITHUB_TOKEN in the shell.
  class GitHubClient
    # Matches the old gh cap; GitHub's REST API allows up to 100 per_page.
    MAX_OPEN_PRS = 100

    def initialize(repo:, token:, client: nil)
      @repo = repo
      @client = client || Octokit::Client.new(access_token: token)
    end

    # Returns an array of Reconciler::ExistingPR for all open PRs whose
    # branch starts with `branch_prefix`. Fetches up to MAX_OPEN_PRS open
    # PRs and filters locally — GitHub's REST endpoint doesn't support
    # branch-name prefix filtering.
    def list_open_prs(branch_prefix:)
      prs = @client.pull_requests(@repo, state: "open", per_page: MAX_OPEN_PRS)
      prs
        .select { |pr| pr.head.ref.start_with?("#{branch_prefix}/") }
        .map do |pr|
          Reconciler::ExistingPR.new(
            number: pr.number,
            branch: pr.head.ref,
            title: pr.title,
            body: pr.body.to_s
          )
        end
    end

    # Creates a new PR. Branch must already exist on the remote.
    # Returns the new PR's number.
    def create_pr(branch:, base:, title:, body:, labels: [])
      pr = @client.create_pull_request(@repo, base, branch, title, body)
      @client.add_labels_to_an_issue(@repo, pr.number, labels) unless labels.empty?
      pr.number
    end

    # Ensures every label in +labels+ exists in the repo, creating any that
    # are missing. Missing labels are created with a neutral default color;
    # existing labels are left untouched.
    def ensure_labels(labels)
      return if labels.empty?
      existing = list_label_names
      labels.each do |label|
        next if existing.include?(label)
        @client.create_label(@repo, label, "0075ca")
      end
    end

    # Edits an existing PR's title and body.
    def update_pr(number:, title:, body:)
      @client.update_pull_request(@repo, number, title:, body:)
      nil
    end

    # Closes a PR, optionally leaving a comment explaining why.
    def close_pr(number:, comment: nil)
      if comment && !comment.empty?
        @client.add_comment(@repo, number, comment)
      end
      @client.close_pull_request(@repo, number)
      nil
    end

    private

    def list_label_names
      @client.labels(@repo).map(&:name)
    rescue Octokit::Error
      []
    end
  end
end
