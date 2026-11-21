#!/usr/bin/env bash
# Build the npm packages for one d8ctl release from its release binaries.
#
#   scripts/npm-stage.sh <version> <assets-dir> <out-dir>
#
# <assets-dir> holds the GitHub Release assets (d8ctl-<os>-<arch>[.exe] plus
# .sha256 sidecars); every binary is checked against its sidecar. Writes
# <out-dir>/<package-dir> for the five platform packages and the main
# @camunda8/d8ctl package, and prints the directories in publish order
# (platform packages first, so the main package's optionalDependencies
# resolve). Used by release.yml and for a manual first publish.
set -euo pipefail

VERSION="${1:?usage: npm-stage.sh <version> <assets-dir> <out-dir>}"
ASSETS="$(cd "${2:?assets-dir}" && pwd)"
OUT="${3:?out-dir}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

if command -v sha256sum > /dev/null; then SHA="sha256sum"; else SHA="shasum -a 256"; fi

# npm package suffix (Node's process.platform-process.arch) : release asset : os : cpu : libc
TARGETS=(
  "darwin-arm64:d8ctl-darwin-arm64:darwin:arm64:"
  "darwin-x64:d8ctl-darwin-amd64:darwin:x64:"
  "linux-x64:d8ctl-linux-amd64:linux:x64:glibc"
  "linux-arm64:d8ctl-linux-arm64:linux:arm64:glibc"
  "win32-x64:d8ctl-windows-amd64.exe:win32:x64:"
)

PYTHON="$(command -v python3 || command -v python)"
optional=()
for t in "${TARGETS[@]}"; do
  IFS=: read -r suffix asset os cpu libc <<< "$t"
  src="$ASSETS/$asset"
  [ -f "$src" ] || { echo "npm-stage: missing $src" >&2; exit 1; }
  want="$(cut -d' ' -f1 < "$src.sha256")"
  got="$($SHA "$src" | cut -d' ' -f1)"
  [ "$want" = "$got" ] || { echo "npm-stage: $asset sha256 $got != sidecar $want" >&2; exit 1; }

  name="@camunda8/d8ctl-$suffix"
  dir="$OUT/d8ctl-$suffix"
  exe="d8ctl"; [ "$os" = win32 ] && exe="d8ctl.exe"
  rm -rf "$dir"; mkdir -p "$dir/bin"
  cp "$src" "$dir/bin/$exe"; chmod 0755 "$dir/bin/$exe"
  cp "$ROOT/LICENSE" "$dir/"
  printf '# %s\n\nThe d8ctl %s binary for %s/%s. Install [@camunda8/d8ctl](https://www.npmjs.com/package/@camunda8/d8ctl) instead; it picks this package for you.\n' \
    "$name" "$VERSION" "$os" "$cpu" > "$dir/README.md"
  "$PYTHON" - "$dir/package.json" "$name" "$VERSION" "$os" "$cpu" "$libc" <<'PY'
import json, sys
path, name, version, os_, cpu, libc = sys.argv[1:]
pkg = {
    "name": name,
    "version": version,
    "description": f"d8ctl native binary for {os_}-{cpu}",
    "license": "Apache-2.0",
    "repository": {"type": "git", "url": "git+https://github.com/camunda/d8ctl.git"},
    "homepage": "https://github.com/camunda/d8ctl",
    "os": [os_],
    "cpu": [cpu],
    "files": ["bin/", "LICENSE", "README.md"],
    "publishConfig": {"access": "public"},
}
if libc:
    pkg["libc"] = [libc]
open(path, "w").write(json.dumps(pkg, indent=2) + "\n")
PY
  optional+=("$name")
  echo "$dir"
done

main="$OUT/d8ctl"
rm -rf "$main"; mkdir -p "$main/bin"
cp "$ROOT/npm/d8ctl/bin/d8ctl.js" "$main/bin/"
cp "$ROOT/npm/d8ctl/README.md" "$ROOT/LICENSE" "$main/"
"$PYTHON" - "$main/package.json" "$VERSION" "${optional[@]}" <<'PY'
import json, sys
path, version, *optional = sys.argv[1:]
pkg = {
    "name": "@camunda8/d8ctl",
    "version": version,
    "description": "One CLI. Every Camunda API. Built for agents.",
    "license": "Apache-2.0",
    "repository": {"type": "git", "url": "git+https://github.com/camunda/d8ctl.git"},
    "homepage": "https://camunda.github.io/d8ctl/",
    "keywords": ["camunda", "camunda8", "cli", "agent", "orchestration", "bpmn"],
    "bin": {"d8ctl": "bin/d8ctl.js"},
    "files": ["bin/", "LICENSE", "README.md"],
    "engines": {"node": ">=18"},
    "optionalDependencies": {name: version for name in optional},
    "publishConfig": {"access": "public"},
}
open(path, "w").write(json.dumps(pkg, indent=2) + "\n")
PY
echo "$main"
