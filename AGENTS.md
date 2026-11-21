# AGENTS.md

> This repo follows the central Camunda AGENTS guidelines:
> https://raw.githubusercontent.com/camunda/.github/refs/heads/main/AGENTS.md
> The instructions below extend those and take precedence on conflict.

## Role & boundary

**d8ctl** is a greenfield spike of a native, generated CLI for the Camunda 8
Orchestration Cluster API. Design: https://github.com/camunda/d8ctl/issues/1.
It is not a replacement for c8ctl.

The command surface is generated from the Orchestration Cluster spec, fetched
from camunda/camunda and bundled by `camunda-schema-bundler` (`npm run
bundle:spec`, `SPEC_REF` default `main`) into the committed `external-spec/bundled/`.
There is no hand-written per-operation handler.

Transport: `camunda-orchestration-sdk:runtime` from
[orchestration-cluster-api-dlang](https://github.com/camunda/orchestration-cluster-api-dlang)
(code.dlang.org `camunda-orchestration-sdk:runtime` and `:openapi` `~>11.0.0-alpha.4`, the `main`/11.x alpha line; bump it in `dub.json` and refresh `dub.selections.json` with `dub upgrade`). The SDK is not a spec source; `:openapi` is only its hardened OpenAPI reader.

## Path map

| Path | Ownership |
| --- | --- |
| `source/d8ctl/app.d` | Entry + `run`. |
| `source/d8ctl/parse.d` | Argv. Accepts both resource-verb and verb-resource. |
| `source/d8ctl/help.d` | Progressive help. |
| `source/d8ctl/profiles.d` | Profiles (`profiles.json`) and `--camunda-*` switches → SDK config overrides. Precedence: switches > profile > env. |
| `source/d8ctl/compat.d` | Read-only c8ctl profiles/session and Camunda Modeler connections, mapped to SDK keys as c8ctl maps them. |
| `source/d8ctl/dispatch.d` | Generic live HTTP via `Transport.request*` (`camunda-orchestration-sdk:runtime`). |
| `source/d8ctl/catalog.d` | Lookups over the generated table. |
| `source/d8ctl/generated/catalog.d` | **Generated.** `make generate`. Never hand-edit. |
| `source/d8ctl/version_.d` | SemVer stamp (`scripts/prepare-release.sh`). |
| `source/d8ctl/specmodel.d` | OpenAPI (+ optional Camunda spec-metadata) → command model: verb/resource split, kebab flags, body flags, root server, `x-cli`. Throws, never exits. Shared by the generator and runtime extensions. |
| `source/d8ctl/completion.d` | Shell completion (#34): `completion bash/zsh/fish/powershell/install` scripts and the dynamic `__complete` answerer (catalog, extensions, profiles; offline). Smoke-tested by `scripts/test-completion.sh`. |
| `source/d8ctl/extensions.d` | Runtime extensions (#9): `extension add/list/update/remove`, the `<configDir>/extensions/<name>/` cache (spec + manifest, 0600/0700, atomic), and the model built from it. Profile-relative extensions (#25) resolve path `--spec`/`--base-url` against the selected profile's origin per call. |
| `scripts/generate.d` | Thin catalog generator (`dub run --single`). Reads `external-spec/bundled/`, calls `specmodel`. |
| `external-spec/bundled/` | Bundled spec + `spec-metadata.json` (`npm run bundle:spec`). Committed. |
| `scripts/check-safe.sh` | `@safe` ratchet (same contract as the SDK). |
| `scripts/prepare-release.sh` | Stamps `dub.json` + `version_.d` (the release builds, then semantic-release). |
| `scripts/npm-stage.sh`, `npm/` | npm packages from the release binaries: `@camunda8/d8ctl` (launcher `npm/d8ctl/bin/d8ctl.js`) + one per platform. `npm/README.md` has the first-publish steps. |
| `docs/` | GitHub Pages explainer (`camunda.github.io/d8ctl`). |

## Strictness

LDC ≥ 1.43 only. Every module `@safe:`. `-preview=dip1000 -preview=nosharedaccess`.
Release keeps `-boundscheck=on`. No extra dub packages beyond the SDK's `:runtime` and `:openapi`. No raw threads,
`__gshared`, or `union` outside a future `safeio.d`.

## Releases

Pushes to `main` run `.github/workflows/release.yml`:
1. `version` dry-runs semantic-release to get the next version (none due means nothing else runs).
2. `build` stamps it and builds linux/darwin amd64+arm64 and windows amd64; each binary must report that version.
3. `release` (semantic-release) tags `vX.Y.Z` and attaches the binaries to a GitHub Release.
4. `npm` publishes the same binaries to npm when the repo variable `NPM_PUBLISH` is `true`.

Homebrew lives in [camunda/homebrew-tap](https://github.com/camunda/homebrew-tap), which picks up new releases itself. `curl | sh` is #3.

## Commands

```bash
make generate        # bundle from camunda/camunda + rebuild catalog
make generate-local  # rebuild from the committed bundle (CI drift gate)
make test
make lint
make check
```
