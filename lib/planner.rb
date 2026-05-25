# frozen_string_literal: true

require_relative "semver"
require_relative "parsers/audit_parser"

module Importmap
  module Update
    # Turns the raw findings from `bin/importmap outdated` and `bin/importmap audit`,
    # combined with the user's config, into a concrete list of pull requests to
    # open. This is the brain of the action: pure functions, zero I/O, fully
    # testable offline.
    #
    # Usage:
    #
    #   plan = Planner.new(
    #     outdated: [OutdatedPackage, ...],
    #     vulnerabilities: [Vulnerability, ...],
    #     config: Config,
    #   ).call
    #
    #   plan.pr_specs   # => [PRSpec, ...]
    #   plan.warnings   # => ["Skipped foo: latest version unparseable", ...]
    #
    # Decision rules (each one is tested):
    #
    #   * Security wins over semver. A vulnerable package becomes a security PR
    #     regardless of whether it's a patch/minor/major bump. The PR body still
    #     records the underlying bump kind so reviewers know what they're getting.
    #   * Unparseable latest versions (fetch errors from importmap outdated) are
    #     skipped and surfaced as warnings — they never enter the plan.
    #   * Severity ordering: critical, high, moderate, low. Within a severity,
    #     packages sort alphabetically. This determines the order of security PRs
    #     and the order they fill the open-pull-request budget.
    #   * Open-PR budget: security PRs are never throttled. Remaining slots are
    #     filled by non-security PRs in priority order major → minor → patch.
    #     Bigger bumps get the slots because they typically need more review
    #     attention than patches.
    class Planner
      # An individual package update slated for inclusion in some PR.
      PackageBump = Data.define(:name, :from, :to, :semver_kind, :advisory)

      # A planned pull request. The reconciler (step 4) will compare these against
      # existing open PRs on GitHub to decide what to open, force-push, or close.
      PRSpec = Data.define(:kind, :packages, :branch, :title, :metadata) do
        def security?
          kind == :security
        end
      end

      # The full output of a planning pass.
      Plan = Data.define(:pr_specs, :warnings) do
        def empty?
          pr_specs.empty?
        end
      end

      # Severity rank — higher number = more urgent. Used for sorting security
      # vulnerabilities so the most critical PRs surface first and consume the
      # earliest slots in the open-PR budget.
      SEVERITY_RANK = {
        "critical" => 4,
        "high" => 3,
        "moderate" => 2,
        "low" => 1
      }.freeze
      DEFAULT_SEVERITY_RANK = 0

      # Order in which non-security buckets compete for the open-PR budget.
      # Earlier = wins ties.
      BUCKET_PRIORITY = %i[major minor patch].freeze

      def initialize(outdated:, vulnerabilities:, config:)
        @outdated = outdated
        @vulnerabilities = vulnerabilities
        @config = config
        @warnings = []
      end

      def call
        # 1. Discard unparseable rows up front, recording them as warnings.
        usable_outdated = collect_usable_outdated

        # 2. Cross-reference outdated with audit data.
        vuln_index = index_vulnerabilities
        security_bumps, regular_bumps = partition_by_security(usable_outdated, vuln_index)

        # 3. Emit one PR per security bump (these always use the individual
        #    strategy regardless of config; the user opted into security PRs
        #    by configuring the security bucket at all).
        security_specs = security_bumps
          .sort_by { |b| [-SEVERITY_RANK.fetch(b.advisory[:severity], DEFAULT_SEVERITY_RANK), b.name] }
          .map { |b| build_security_spec(b) }

        # 4. Bucket the rest by semver kind and emit specs per config.
        non_security_specs = build_non_security_specs(regular_bumps)

        # 5. Apply the open-pull-requests-limit budget.
        all_specs = enforce_budget(security_specs, non_security_specs)

        Plan.new(pr_specs: all_specs, warnings: @warnings.freeze)
      end

      private

      def collect_usable_outdated
        @outdated.filter_map do |pkg|
          unless pkg.parseable?
            @warnings << "Skipped #{pkg.name}: could not determine latest version (#{pkg.error})"
            next
          end
          kind = Semver.classify(pkg.current, pkg.latest)
          unless kind
            @warnings << "Skipped #{pkg.name}: could not classify bump #{pkg.current} → #{pkg.latest}"
            next
          end
          [pkg, kind]
        end
      end

      # name => Vulnerability. If a package somehow appears multiple times in
      # audit output, the most severe one wins.
      def index_vulnerabilities
        @vulnerabilities.each_with_object({}) do |v, h|
          existing = h[v.name]
          h[v.name] = v if existing.nil? || more_severe?(v, existing)
        end
      end

      def more_severe?(a, b)
        SEVERITY_RANK.fetch(a.severity, DEFAULT_SEVERITY_RANK) >
          SEVERITY_RANK.fetch(b.severity, DEFAULT_SEVERITY_RANK)
      end

      def partition_by_security(usable, vuln_index)
        security = []
        regular = []
        usable.each do |(pkg, kind)|
          vuln = vuln_index[pkg.name]
          if vuln
            security << PackageBump.new(
              name: pkg.name, from: pkg.current, to: pkg.latest,
              semver_kind: kind,
              advisory: {
                severity: vuln.severity,
                vulnerable_versions: vuln.vulnerable_versions,
                description: vuln.advisory
              }
            )
          else
            regular << PackageBump.new(
              name: pkg.name, from: pkg.current, to: pkg.latest,
              semver_kind: kind, advisory: nil
            )
          end
        end
        [security, regular]
      end

      def build_security_spec(bump)
        PRSpec.new(
          kind: :security,
          packages: [bump],
          branch: "#{@config.branch_prefix}/security-#{sanitize(bump.name)}",
          title: with_prefix("bump #{bump.name} #{bump.from} → #{bump.to} (security: #{bump.advisory[:severity]})"),
          metadata: metadata_for(:security, [bump])
        )
      end

      def build_non_security_specs(bumps)
        by_kind = bumps.group_by(&:semver_kind)
        specs = []

        BUCKET_PRIORITY.each do |kind|
          bucket_bumps = by_kind[kind] || []
          next if bucket_bumps.empty?

          # Stable ordering inside any bucket: alphabetical by package name.
          bucket_bumps = bucket_bumps.sort_by(&:name)
          strategy = @config.grouping.fetch(kind).strategy

          if strategy == :grouped
            specs << build_grouped_spec(kind, bucket_bumps)
          else
            bucket_bumps.each { |b| specs << build_individual_spec(kind, b) }
          end
        end

        specs
      end

      def build_grouped_spec(kind, bumps)
        PRSpec.new(
          kind:,
          packages: bumps,
          branch: "#{@config.branch_prefix}/#{kind}",
          title: grouped_title(kind, bumps),
          metadata: metadata_for(kind, bumps)
        )
      end

      def build_individual_spec(kind, bump)
        PRSpec.new(
          kind:,
          packages: [bump],
          branch: "#{@config.branch_prefix}/#{kind}-#{sanitize(bump.name)}",
          title: with_prefix("bump #{bump.name} #{bump.from} → #{bump.to}"),
          metadata: metadata_for(kind, [bump])
        )
      end

      def grouped_title(kind, bumps)
        if bumps.size == 1
          b = bumps.first
          with_prefix("bump #{b.name} #{b.from} → #{b.to}")
        else
          with_prefix("#{kind} updates (#{bumps.size} packages)")
        end
      end

      def with_prefix(message)
        prefix = @config.commit_message.prefix
        body = message.sub(/\A[a-z]/, &:upcase)
        prefix.empty? ? body : "#{prefix}: #{body}"
      end

      # This hash is what the reconciler matches against in step 4. It will be
      # serialized into the PR body inside an HTML comment block so the action
      # can identify and update its own PRs on subsequent runs.
      def metadata_for(kind, bumps)
        {
          tool: "importmap-update",
          kind:,
          packages: bumps.map { |b|
            entry = {name: b.name, from: b.from, to: b.to, semver_kind: b.semver_kind}
            entry[:severity] = b.advisory[:severity] if b.advisory
            entry
          }
        }
      end

      # Branch-safe slugs. Package names like @hotwired/stimulus contain
      # characters that are legal in git refs but read poorly; flatten them
      # so the branch name is unambiguous and shell-safe.
      def sanitize(package_name)
        package_name.gsub(%r{[@/]}, "-").squeeze("-").sub(/\A-/, "")
      end

      # Security specs are protected; the budget only constrains the rest.
      # Within the budget, non-security specs are kept in the order they were
      # built (major → minor → patch), and we truncate at the limit.
      def enforce_budget(security_specs, non_security_specs)
        limit = @config.open_pull_requests_limit
        room = limit - security_specs.size

        if room <= 0
          if non_security_specs.any?
            @warnings << "Dropped #{non_security_specs.size} non-security PR(s) to stay under open_pull_requests_limit=#{limit}"
          end
          return security_specs
        end

        kept = non_security_specs.first(room)
        dropped = non_security_specs.size - kept.size
        if dropped.positive?
          @warnings << "Dropped #{dropped} non-security PR(s) to stay under open_pull_requests_limit=#{limit}"
        end
        security_specs + kept
      end
    end
  end
end
