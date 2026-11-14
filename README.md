# d8ctl

Native agent CLI for the Camunda 8 Orchestration Cluster API. A greenfield
spike of the generated half of [c8ctl#767](https://github.com/camunda/c8ctl/issues/767):
one binary, no extra D packages, command surface locked to the
[D SDK](https://github.com/camunda/orchestration-cluster-api-dlang).

See [issue #1](https://github.com/camunda/d8ctl/issues/1) for the design.

## Status

Technical Preview of an idea, not a product. Every Orchestration Cluster REST
operation is a command. Help is progressive. Resource-then-verb and
verb-then-resource both parse.

## Build

LDC ≥ 1.43, dub, libcurl. The SDK comes from
code.dlang.org (`camunda-orchestration-sdk:runtime`, pinned in `dub.json` and
locked in `dub.selections.json`). To build against a local SDK checkout:
`dub add-local ../orchestration-cluster-api-dlang` (undo with `dub remove-local`).

```sh
make generate   # rebuild the catalog from the SDK's spec-metadata.json
make test
make build      # ./d8ctl
```

Same `@safe` contract as the SDK: DIP1000, nosharedaccess, bounds checks on
in release, `scripts/check-safe.sh` as a pre-build hook. **Zero extra dub
packages** — Phobos + the D SDK (which itself only links libcurl).

## Usage

```sh
d8ctl --help
d8ctl cluster --help
d8ctl cluster topology --help
d8ctl cluster topology get --help
d8ctl cluster topology get          # live: GET /topology
d8ctl cluster get topology          # same command, verb-first
d8ctl cluster jobs activate --help
d8ctl cluster jobs activate --type=probe:x --timeout=1000 --maxJobsToActivate=1
d8ctl cluster topology get --dry-run
```

Path parameters are positional, in spec order. Query parameters are
`--name=value`. JSON bodies accept top-level fields as `--name=value`
(see `--help` on the command) and/or a full document via `--body='{…}'`.
`--body` wins on conflict. Nested objects and arrays are JSON strings
(`--filter='{"state":"ACTIVE"}'`). Union bodies (create process instance,
evaluate decision, …) stay `--body` only.

`--order=resource|verb` only changes how help lists commands. Both orders
always parse.

Auth and address are the SDK's `CAMUNDA_*` environment variables
(`CAMUNDA_REST_ADDRESS`, `CAMUNDA_AUTH_STRATEGY`, …).

## Releases

Pushes to `main` cut a GitHub Release (`vX.Y.Z`) with linux/darwin
amd64+arm64 binaries. Install from the release assets until Homebrew /
`curl | sh` land. The explainer site is `docs/` →
[camunda.github.io/d8ctl](https://camunda.github.io/d8ctl/).

## Generation

The spec comes straight from [camunda/camunda](https://github.com/camunda/camunda)
(`zeebe/gateway-protocol/src/main/proto/v2`), fetched and bundled by
`camunda-schema-bundler`, the same pipeline as the JS and D SDKs:

```sh
npm install
make generate                          # bundle camunda/camunda main, then rebuild the catalog
SPEC_REF=<branch|tag|sha> make generate
make generate-local                    # rebuild from the committed external-spec/bundled/
```

`scripts/generate.py` reads `external-spec/bundled/{rest-api.bundle,spec-metadata}.json`
and writes `source/d8ctl/generated/catalog.d` (one row per operation; 247 today).
Do not hand-edit the catalog. There is no per-operation handler — dispatch
walks the table and calls `Transport.requestJson` / `requestVoid` / `requestText`
from `camunda-orchestration-sdk:runtime`.

Multipart operations (`createDeployment`, `createDocument`, `createDocuments`)
are refused until we add file flags.

## License

Apache-2.0.
