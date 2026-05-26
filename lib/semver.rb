# frozen_string_literal: true

module ImportmapUpdate
  # Classifies a version bump as :patch, :minor, or :major.
  #
  # Follows SemVer 2.0.0 (https://semver.org), with one project-specific
  # rule for 0.x.y versions: while SemVer technically considers anything
  # in 0.x to be unstable, npm/yarn/Dependabot treat 0.x.y → 0.x.(y+1) as
  # patch and 0.x.y → 0.(x+1).0 as minor, and we follow that convention
  # because importmap-rails pulls from the npm ecosystem.
  #
  # Pre-release tags (e.g. -beta.1, -rc.0) are stripped before comparing
  # core versions: a bump *to* a pre-release of the same core version is
  # treated as :patch, since the user is explicitly opting into pre-releases.
  module Semver
    module_function

    VERSION_RE = /\A
      v?                                  # optional leading "v"
      (?<major>\d+)
      \.(?<minor>\d+)
      \.(?<patch>\d+)
      (?:-(?<prerelease>[0-9A-Za-z.-]+))? # -beta.1, -rc.0, etc.
      (?:\+(?<build>[0-9A-Za-z.-]+))?    # +build.123 (ignored for comparison)
    \z/x

    # @return [Symbol, nil] :patch | :minor | :major, or nil if either
    #   version is unparseable.
    def classify(from, to)
      f = parse(from)
      t = parse(to)
      return nil unless f && t

      return :major if t[:major] != f[:major]
      return :minor if t[:minor] != f[:minor]
      :patch
    end

    def parse(version)
      return nil if version.nil?
      m = VERSION_RE.match(version.to_s.strip)
      return nil unless m
      {
        major: m[:major].to_i,
        minor: m[:minor].to_i,
        patch: m[:patch].to_i,
        prerelease: m[:prerelease]
      }
    end
  end
end
