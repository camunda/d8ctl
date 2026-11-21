#!/usr/bin/env bash
# Smoke-test shell completion (#34) against a built binary: the bash function
# with a simulated COMP_LINE, zsh's function with _describe stubbed, and fish's
# real completer via `complete -C`. Shells that are not installed are skipped.
set -euo pipefail
bin=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
mkdir -p "$dir/bin"
ln -s "$bin" "$dir/bin/d8ctl"
export PATH="$dir/bin:$PATH"
fail=0
expect() { # name got want
  if [[ " $2 " == *" $3 "* ]]; then echo "ok   $1: $3"; else echo "FAIL $1: want '$3' in '$2'"; fail=1; fi
}

d8ctl completion bash > "$dir/d8ctl.bash"
got=$(bash -c 'source "$1"
  COMP_LINE="d8ctl cluster get topo"; COMP_POINT=${#COMP_LINE}; _d8ctl; echo "${COMPREPLY[*]}"' _ "$dir/d8ctl.bash")
expect bash "$got" topology
got=$(bash -c 'source "$1"
  COMP_LINE="d8ctl --output="; COMP_POINT=${#COMP_LINE}; _d8ctl; echo "${COMPREPLY[*]}"' _ "$dir/d8ctl.bash")
expect bash "$got" json

if command -v zsh >/dev/null; then
  d8ctl completion zsh > "$dir/_d8ctl"
  zsh -n "$dir/_d8ctl"
  got=$(zsh -f -c '_describe() { print -r -- ${${(P)4}%%:*}; }; compdef() { :; }; source "$1"
    words=(d8ctl cluster topology ""); CURRENT=4; _d8ctl' _ "$dir/_d8ctl")
  expect zsh "$got" get
else
  echo "skip zsh (not installed)"
fi

if command -v fish >/dev/null; then
  d8ctl completion fish > "$dir/d8ctl.fish"
  got=$(fish --no-config -c 'source $argv[1]; complete -C "d8ctl cluster get topo"' "$dir/d8ctl.fish" | cut -f1 | tr '\n' ' ')
  expect fish "$got" topology
else
  echo "skip fish (not installed)"
fi
exit $fail
