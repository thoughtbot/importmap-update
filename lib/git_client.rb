# frozen_string_literal: true

require "git"

module ImportmapUpdate
  # Git operations the executor needs: creating/resetting a branch from
  # base, committing changes, and pushing. Every method delegates to an
  # injected Git::Base repo object (or a Minitest::Mock in tests) so the
  # class does no orchestration — that's the executor's job.
  class GitClient
    def initialize(repo:, author_name:, author_email:)
      @repo = repo
      @author_name = author_name
      @author_email = author_email
    end

    # Resets the working tree to base and creates/switches to `branch`.
    # If `branch` already exists locally it is checked out and hard-reset
    # to origin/base, mirroring `git checkout -B branch origin/base`.
    # This is destructive of local state by design — the action runs in
    # CI where there is no uncommitted work to save.
    def checkout_fresh_branch(branch:, base:)
      @repo.fetch("origin", ref: base)
      begin
        @repo.checkout(branch)
      rescue Git::Error
        # Branch does not exist yet — create it at origin/base and stop.
        @repo.checkout(branch, new_branch: true, start_point: "origin/#{base}")
        return nil
      end
      # Branch existed; reset it to origin/base from a clean state.
      @repo.reset_hard("origin/#{base}")
      nil
    end

    # Stages the importmap and vendored JS files and commits them.
    # Returns true iff a commit was actually created; false when
    # bin/importmap pin was a no-op and there is nothing to commit.
    def commit_changes(message:)
      @repo.add(["config/importmap.rb", "vendor/javascript"])
      @repo.commit(message, author: "#{@author_name} <#{@author_email}>")
      true
    rescue Git::FailedError => e
      return false if e.result.stderr.to_s.include?("nothing to commit")
      raise
    end

    def push(branch:, force: false)
      @repo.push("origin", branch, force:)
      nil
    end
  end
end
