// d8ctl is a single-line CLI. Releases come off `main` as GitHub Releases
// with attached binaries (see .github/workflows/release.yml), built after
// a dry run has resolved the version, so each binary reports its own. Pre-1.0: versions stay 0.x (breaking -> minor)
// and every GitHub Release is flagged Pre-release. Cutting 1.0.0 is a
// deliberate config change, not a side effect of a commit message.
module.exports = {
  branches: ['main'],
  plugins: [
    [
      '@semantic-release/commit-analyzer',
      {
        releaseRules: [
          { type: 'feat', release: 'minor' },
          { type: 'fix', release: 'patch' },
          { type: 'perf', release: 'patch' },
          { type: 'revert', release: 'patch' },
          { breaking: true, release: 'minor' },
        ],
      },
    ],
    '@semantic-release/release-notes-generator',
    '@semantic-release/changelog',
    [
      '@semantic-release/exec',
      {
        // Dry runs (the workflow's `version` job) stop after verifyRelease:
        // it records the version so the builds can stamp it first.
        verifyReleaseCmd: 'echo "${nextRelease.version}" > .next-version',
        prepareCmd: 'bash scripts/prepare-release.sh "${nextRelease.version}"',
        successCmd: 'gh release edit "v${nextRelease.version}" --prerelease --repo camunda/d8ctl',
      },
    ],
    [
      '@semantic-release/git',
      {
        assets: ['CHANGELOG.md', 'dub.json', 'source/d8ctl/version_.d'],
        message:
          'chore(release): ${nextRelease.version} [skip ci]\n\n${nextRelease.notes}',
      },
    ],
    [
      '@semantic-release/github',
      {
        successComment: false,
        assets: ['release-assets/*'],
      },
    ],
  ],
};
