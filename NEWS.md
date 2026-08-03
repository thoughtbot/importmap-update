# News

## Unreleased

### Added

### Changed

### Removed

### Deprecated

### Fixed

- Use Octokit's `add_label` instead of the nonexistent `create_label` when
  creating missing labels, which raised `NoMethodError` with Octokit v10.

### Security
