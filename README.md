# importmap-update

A GitHub Action that provides Dependabot-style automated dependency updates
for Rails applications using [importmap-rails][importmap-rails]. It runs
`bin/importmap outdated` and `bin/importmap audit`, opens pull requests
according to a configurable grouping strategy, and reconciles its own PRs
across runs (force-pushing when versions move, closing when packages are
no longer outdated).

Dependabot does not support importmap-rails natively. Neither does Renovate.
This action fills that gap.

## Quick start

For this action to work you must explicitly allow GitHub Actions to create pull
requests. This setting can be found in a repository's settings under Actions >
General > Workflow permissions.

Another option is to use a dedicated GitHub token for this action, which can be
set as a secret in the repository's settings. This token should have the `repo`
scope enabled.

Then, add a workflow file that sets up your Rails environment and runs the action:

```yaml
# .github/workflows/importmap-updates.yml
name: Importmap updates
on:
  schedule:
    - cron: "0 9 * * 1"   # Mondays 09:00 UTC
  workflow_dispatch:

permissions:
  contents: write
  pull-requests: write

jobs:
  update:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
      - uses: ruby/setup-ruby@v1
        with:
          bundler-cache: true

      - uses: thoughtbot/importmap-update@v1
        with:
          github-token: ${{ secrets.GITHUB_TOKEN }}
```

That's enough to get going with the baked-in defaults. For first-time use,
set `dry-run: "true"` so you can review the action's log and see exactly
what it _would_ do before flipping the switch.

## Configuration

Configuration lives in `.github/importmap-updates.yml`:

```yaml
version: 1

grouping:
  security: { strategy: individual }   # always one PR per vulnerable pkg
  patch:    { strategy: grouped }      # one PR for all patch bumps
  minor:    { strategy: grouped }      # one PR for all minor bumps
  major:    { strategy: individual }   # one PR per major bump

open_pull_requests_limit: 10
labels: [dependencies, javascript, importmap]
commit_message:
  prefix: "chore(deps)"
branch_prefix: "importmap-updates"
```

All fields are optional. Missing fields fall back to defaults. Both
underscore and dash key styles are accepted (so
`open-pull-requests-limit` works too — convenient if you're coming from
Dependabot's config).

### Grouping strategies

For each of the four buckets (`security`, `patch`, `minor`, `major`) you
can pick `grouped` (one PR for the whole bucket) or `individual` (one PR
per package).

Security always takes priority over the semver bucket: a vulnerable
package that happens to be a major bump becomes a **security** PR, not a
major PR — but the PR body and metadata still record that it's a major
bump so reviewers know to expect breaking changes.

### Open-PR budget

`open_pull_requests_limit` caps the number of PRs the action will open.
Security PRs are never throttled. When the budget is tight, non-security
PRs are kept in priority order major → minor → patch.

## Safety properties

- **Foreign PRs are never touched.** A PR on a branch matching the
  configured prefix but without the action's metadata block is left
  alone — never closed, edited, or force-pushed. A human who manually
  creates a PR on the `importmap-updates/*` namespace will not have
  their work clobbered.
- **Dry-run mode.** Set `dry-run: "true"` to run end-to-end without
  side effects. Every action is reported in the workflow log.
- **Branch ownership via embedded metadata.** Every PR the action opens
  contains a YAML metadata block in its body (inside an HTML comment).
  On subsequent runs the action reads this back to identify its own
  PRs. The block is schema-versioned so future format changes can't
  cause this action to mistreat newer PRs.

## Debugging

The CLI supports three offline modes useful during config development:

```bash
# Show the resolved config (with defaults applied).
./exe/importmap-update --print-config

# Capture `bin/importmap outdated` and `bin/importmap audit` output,
# then see what the planner would do without hitting GitHub.
./exe/importmap-update --print-plan \
  --outdated-file /tmp/outdated.txt \
  --audit-file /tmp/audit.txt

# Same but also runs the reconciler against a YAML file of mocked
# existing PRs — useful for verifying close/force-push behavior.
./exe/importmap-update --print-actions \
  --outdated-file /tmp/outdated.txt \
  --audit-file /tmp/audit.txt \
  --existing-prs /tmp/existing.yml
```

## Development

```bash
git clone https://github.com/thoughtbot/importmap-update
cd importmap-update
bundle install
bundle exec rake
```

## Contributing

See the [CONTRIBUTING] document.
Thank you, [contributors]!

[CONTRIBUTING]: CONTRIBUTING.md
[contributors]: https://github.com/thoughtbot/importmap-update/graphs/contributors

## License

importmap-update is Copyright (c) thoughtbot, inc.
It is free software, and may be redistributed
under the terms specified in the [LICENSE] file.

[LICENSE]: /LICENSE
[importmap-rails]: https://github.com/rails/importmap-rails

<!-- START /templates/footer.md -->
<!-- END /templates/footer.md -->
