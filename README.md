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

LDC ≥ 1.43, dub, libcurl. The SDK is a path dependency
(`../orchestration-cluster-api-dlang`).

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

## Generation

`scripts/generate.py` reads the SDK's `external-spec/bundled/spec-metadata.json`
and writes `source/d8ctl/generated/catalog.d` (244 rows). Do not hand-edit
the catalog. There is no per-operation handler — dispatch walks the table
and calls `CamundaClient.requestJson` / `requestVoid` / `requestText`.

Multipart operations (`createDeployment`, `createDocument`, `createDocuments`)
are refused until we add file flags.

## License

Apache-2.0.
