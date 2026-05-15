# frozen_string_literal: true

require_relative "commands"

module Importmap
  module Update
    # Git operations the executor needs: creating/resetting a branch from
    # base, committing changes, pushing (with optional --force for the
    # force_push action). Every command runs through the injected runner
    # so tests can replay fixtures the same way they do for gh.
    class GitClient
      def initialize(author_name:, author_email:, runner: Commands::ShellRunner.new)
        @runner = runner
        @author_name = author_name
        @author_email = author_email
      end

      # Resets the working tree to base and creates/switches to `branch`.
      # If `branch` already exists locally (e.g. from a previous run on
      # the same worker), it's force-reset to base so we start from a
      # known state. This is destructive of local state by design — the
      # action runs in CI where there's no "uncommitted work to save".
      def checkout_fresh_branch(branch:, base:)
        @runner.run!("git", "fetch", "origin", base)
        @runner.run!("git", "checkout", "-B", branch, "origin/#{base}")
        nil
      end

      # Stages all changes and commits with the given message. Returns true
      # if a commit was actually created, false if there was nothing to
      # commit (which usually means `bin/importmap pin` was a no-op).
      def commit_all(message:)
        @runner.run!("git", "add", "-A")
        # `git diff --cached --quiet` exits 0 if there are no staged changes.
        diff = @runner.run("git", "diff", "--cached", "--quiet")
        return false if diff.success?

        @runner.run!(
          "git",
          "-c", "user.name=#{@author_name}",
          "-c", "user.email=#{@author_email}",
          "commit", "-m", message
        )
        true
      end

      def push(branch:, force: false)
        argv = ["git", "push", "origin", "#{branch}:#{branch}"]
        argv.push("--force") if force
        @runner.run!(*argv)
        nil
      end
    end
  end
end
