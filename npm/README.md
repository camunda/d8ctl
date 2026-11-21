# npm packaging

d8ctl is published to npm as `@camunda8/d8ctl` plus one package per platform:

| Package | Binary (release asset) |
| --- | --- |
| `@camunda8/d8ctl-darwin-arm64` | `d8ctl-darwin-arm64` |
| `@camunda8/d8ctl-darwin-x64` | `d8ctl-darwin-amd64` |
| `@camunda8/d8ctl-linux-x64` (glibc) | `d8ctl-linux-amd64` |
| `@camunda8/d8ctl-linux-arm64` (glibc) | `d8ctl-linux-arm64` |
| `@camunda8/d8ctl-win32-x64` | `d8ctl-windows-amd64.exe` |

The main package lists the platform packages as `optionalDependencies`. Each
platform package declares its `os`/`cpu` (and `libc`), so npm installs only the
one that matches. `bin/d8ctl.js` finds that binary and runs it. Exit codes and
signals pass through. There are no install scripts and no downloads at install
time.

`scripts/npm-stage.sh <version> <assets-dir> <out-dir>` builds all six from a
release's binaries, checking each against its `.sha256` sidecar. It prints
the package directories in publish order.

## Publishing

`release.yml`'s `npm` job runs after the GitHub Release when the repository
variable `NPM_PUBLISH` is `true`. It uses npm Trusted Publishing (OIDC, no
token) with `--provenance`, and skips versions that are already published.

### One-time setup

Trusted Publishing is configured per package, and a package must exist before
you can configure it. So the first version goes up by hand:

```sh
# 1. Stage the latest release
v=0.9.2                                    # the latest vX.Y.Z (without the v)
gh release download "v$v" -R camunda/d8ctl -D /tmp/d8ctl-assets
bash scripts/npm-stage.sh "$v" /tmp/d8ctl-assets /tmp/d8ctl-npm

# 2. Publish them, platform packages first (needs publish rights on @camunda8)
npm login
for d in $(bash scripts/npm-stage.sh "$v" /tmp/d8ctl-assets /tmp/d8ctl-npm); do
  npm publish "$d" --access public
done
```

3. For **each** of the six packages, on npmjs.com go to *Settings → Trusted
   Publisher → GitHub Actions* and enter: organisation `camunda`, repository
   `d8ctl`, workflow `release.yml`, no environment.
4. Optionally, under *Settings → Publishing access*, choose "Require two-factor
   authentication and disallow tokens".
5. `gh variable set NPM_PUBLISH -R camunda/d8ctl --body true`

Provenance needs a public repository. Until camunda/d8ctl is public, publish
without `--provenance`.
