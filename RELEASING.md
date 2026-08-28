# Releasing

1. Update `NEWS.md` with relevant changes since the last release and set the version heading.
2. Commit the changes with a message like "Release v#{version}"
3. Tag the release: `git tag -s v#{version}` and fill in the tag message with the relevant changes.
4. Push the changes: `git push --follow-tags`
5. Create a release on GitHub with the version and release notes from `NEWS.md`.
6. Announce the release.

### Versioning

This action follows [Semantic Versioning]. The major version tag (e.g. `v1`) is kept pointing at the latest patch release in that series so consumers who pin `thoughtbot/importmap-update@v1` get updates automatically.

The [Major version tag workflow](.github/workflows/major-version-tag.yml) moves it automatically when a non-prerelease release is published, so step 5 above is the last manual step.

Do not create a GitHub release for the `v1` tag. Releases in this repo are immutable, and attaching one would freeze the tag in place.

[Semantic Versioning]: https://semver.org

### Additional Resources

- [Signing commits with GPG](https://docs.github.com/en/authentication/managing-commit-signature-verification/signing-commits)
