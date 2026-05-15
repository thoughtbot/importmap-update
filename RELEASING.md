# Releasing

1. Update `NEWS.md` with relevant changes since the last release and set the version heading.
2. Commit the changes with a message like "Release v#{version}"
3. Tag the release: `git tag -s v#{version}` and fill in the tag message with the relevant changes.
4. Push the changes: `git push --follow-tags`
5. Create a release on GitHub with the version and release notes from `NEWS.md`.
6. Announce the release.

### Versioning

This action follows [Semantic Versioning]. The major version tag (e.g. `v1`) is kept pointing at the latest patch release in that series so consumers who pin `thoughtbot/importmap-update@v1` get updates automatically.

After tagging `v1.x.x`, move the floating tag:

```
git tag -f v1
git push --force origin v1
```

[Semantic Versioning]: https://semver.org

### Additional Resources

- [Signing commits with GPG](https://docs.github.com/en/authentication/managing-commit-signature-verification/signing-commits)
