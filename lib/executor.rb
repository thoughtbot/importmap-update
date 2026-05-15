# frozen_string_literal: true

require_relative "commands"
require_relative "gh_client"
require_relative "git_client"
require_relative "metadata"

module Importmap
  module Update
    # Consumes the reconciler's actions and performs the actual side
    # effects: pinning packages with `bin/importmap pin`, committing,
    # pushing, and opening/editing/closing PRs through `gh`. Most of the
    # decision-making happened upstream; this layer's job is to do what
    # it's told and report results.
    #
    # Failure handling:
    #   * One failing action does not block the others. A bad `bin/importmap pin`
    #     for one package shouldn't prevent the rest of a grouped PR from
    #     being committed, and a single failing PR shouldn't prevent the
    #     other planned PRs from being opened.
    #   * Every action returns a Report indicating what was attempted, what
    #     succeeded, and (if it failed) why. The caller can decide how
    #     loudly to surface failures.
    #   * Dry-run mode logs the actions it *would* perform but invokes no
    #     side-effect runners. Use this for the first deployment in a repo,
    #     or whenever you want to inspect behavior without consequences.
    class Executor
      Outcome = Struct.new(:type, :status, :branch, :pr_number, :detail, keyword_init: true) do
        def success?
          status == :success
        end

        def skipped?
          status == :skipped
        end

        def failed?
          status == :failed
        end
      end

      Report = Struct.new(:outcomes, :warnings, keyword_init: true)

      def initialize(
        gh:,
        git:,
        base_branch:, commit_message_prefix:, runner: Commands::ShellRunner.new,
        labels: [],
        dry_run: false,
        body_renderer: nil
      )
        @gh = gh
        @git = git
        @runner = runner
        @base = base_branch
        @commit_message_prefix = commit_message_prefix
        @labels = labels
        @dry_run = dry_run
        # Allows tests to inject a deterministic body renderer; production
        # uses the default which embeds the metadata block.
        @body_renderer = body_renderer || method(:default_body_for)
      end

      def call(actions)
        outcomes = []
        warnings = []

        actions.each do |action|
          outcomes << begin
            case action.type
            when :noop then handle_noop(action)
            when :open then handle_open(action)
            when :force_push then handle_force_push(action)
            when :close then handle_close(action)
            else
              Outcome.new(type: action.type, status: :failed, detail: "Unknown action type")
            end
          rescue Commands::CommandError => e
            warnings << "#{action.type} on #{describe(action)}: #{e.message}"
            Outcome.new(
              type: action.type, status: :failed,
              branch: action.pr_spec&.branch || action.existing_pr&.branch,
              pr_number: action.existing_pr&.number,
              detail: e.message
            )
          end
        end

        Report.new(outcomes: outcomes.freeze, warnings: warnings.freeze)
      end

      private

      # ---- per-action handlers ----

      def handle_noop(action)
        Outcome.new(
          type: :noop, status: :success,
          branch: action.pr_spec.branch,
          pr_number: action.existing_pr.number,
          detail: "Already up-to-date."
        )
      end

      def handle_open(action)
        spec = action.pr_spec
        if @dry_run
          return Outcome.new(
            type: :open, status: :skipped, branch: spec.branch,
            detail: "DRY RUN: would open PR for #{spec.packages.size} package(s)."
          )
        end

        @gh.ensure_labels(@labels)
        @git.checkout_fresh_branch(branch: spec.branch, base: @base)
        committed = pin_packages_and_commit(spec)
        if !committed
          return Outcome.new(
            type: :open, status: :skipped, branch: spec.branch,
            detail: "No changes after pinning — packages may already be at latest."
          )
        end
        @git.push(branch: spec.branch, force: true)
        number = @gh.create_pr(
          branch: spec.branch, base: @base,
          title: spec.title, body: @body_renderer.call(spec),
          labels: @labels
        )
        Outcome.new(type: :open, status: :success, branch: spec.branch, pr_number: number)
      end

      def handle_force_push(action)
        spec = action.pr_spec
        existing = action.existing_pr

        if @dry_run
          return Outcome.new(
            type: :force_push, status: :skipped, branch: spec.branch, pr_number: existing.number,
            detail: "DRY RUN: would force-push (#{action.reason})."
          )
        end

        @git.checkout_fresh_branch(branch: spec.branch, base: @base)
        committed = pin_packages_and_commit(spec)
        if !committed
          return Outcome.new(
            type: :force_push, status: :skipped, branch: spec.branch, pr_number: existing.number,
            detail: "No changes after pinning; leaving PR as-is."
          )
        end
        @git.push(branch: spec.branch, force: true)
        @gh.update_pr(number: existing.number, title: spec.title, body: @body_renderer.call(spec))
        Outcome.new(type: :force_push, status: :success, branch: spec.branch, pr_number: existing.number)
      end

      def handle_close(action)
        existing = action.existing_pr
        if @dry_run
          return Outcome.new(
            type: :close, status: :skipped, branch: existing.branch, pr_number: existing.number,
            detail: "DRY RUN: would close (#{action.reason})."
          )
        end
        @gh.close_pr(number: existing.number, comment: action.reason)
        Outcome.new(type: :close, status: :success, branch: existing.branch, pr_number: existing.number)
      end

      # ---- helpers ----

      # Pins each package in the spec by shelling to `bin/importmap pin
      # <name>@<version>`. Per-package failures are logged but don't abort
      # the rest of the group — a grouped patch PR with one broken package
      # is better than nothing, and the broken one surfaces as a warning.
      # Returns true iff something was actually committed.
      def pin_packages_and_commit(spec)
        applied = []
        spec.packages.each do |pkg|
          result = @runner.run("bin/importmap", "pin", "#{pkg.name}@#{pkg.to}")
          if result.success?
            applied << pkg
          elsif applied.empty?
            # Don't raise — that would abort the whole spec. The warning is
            # captured by the surrounding rescue in #call.
            if applied.empty?
              raise Commands::CommandError.new(
                ["bin/importmap", "pin", "#{pkg.name}@#{pkg.to}"], result
              )
            end
            # If we've already pinned at least one package, swallow this
            # one's failure and keep going so the partial group still ships.
          end
        end
        return false if applied.empty?
        @git.commit_all(message: commit_message_for(spec))
      end

      def commit_message_for(spec)
        if spec.packages.size == 1
          p = spec.packages.first
          with_prefix("bump #{p.name} from #{p.from} to #{p.to}")
        else
          names = spec.packages.map(&:name).sort.join(", ")
          with_prefix("#{spec.kind} updates (#{names})")
        end
      end

      def with_prefix(message)
        body = message.sub(/\A[a-z]/, &:upcase)
        @commit_message_prefix.empty? ? body : "#{@commit_message_prefix}: #{body}"
      end

      # Default PR body: a short human-readable header listing the bumps,
      # then the metadata block. Tests can override the renderer to make
      # output deterministic.
      def default_body_for(spec)
        header_lines = ["This PR updates the following pinned packages:", ""]
        spec.packages.each do |p|
          line = "- `#{p.name}`: `#{p.from}` → `#{p.to}`"
          line += " — **#{p.advisory[:severity]} severity**" if p.advisory
          header_lines << line
        end
        if spec.kind == :security
          header_lines << ""
          header_lines << "_This PR addresses one or more security advisories reported by `bin/importmap audit`._"
        end
        header = header_lines.join("\n")
        Metadata.embed(header, spec.metadata)
      end

      def describe(action)
        if action.pr_spec
          "branch=#{action.pr_spec.branch}"
        elsif action.existing_pr
          "PR ##{action.existing_pr.number}"
        else
          "unknown"
        end
      end
    end
  end
end
