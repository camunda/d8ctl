# @camunda8/d8ctl

**One CLI. Every Camunda API. Built for agents.**

d8ctl is a native command-line client for the Camunda 8 Orchestration Cluster
API, generated from the API spec. This package installs the prebuilt binary for
your machine; there is no Node code in the hot path beyond a small launcher.

```sh
npm install -g @camunda8/d8ctl
d8ctl --help

# or without installing
npx @camunda8/d8ctl cluster topology get
```

Supported: macOS (arm64, x64), Linux glibc (x64, arm64; needs `libcurl4`),
Windows x64. Other installs (Homebrew, release binaries) and docs:
<https://github.com/camunda/d8ctl>.

c8ctl (`@camunda8/cli`) is the CLI for humans; d8ctl is the one for agents.
