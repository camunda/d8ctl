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

## Connecting to clusters

d8ctl uses the SDK's `CAMUNDA_*` settings (`CAMUNDA_REST_ADDRESS`,
`CAMUNDA_AUTH_STRATEGY`, `CAMUNDA_CLIENT_ID`, …). There are three ways to supply them.

**Explicit switches.** Every `CAMUNDA_*` key has a `--camunda-*` switch, so a
command can carry its own address and credentials, with no environment set up:

```sh
d8ctl --camunda-rest-address=https://bru-2.zeebe.camunda.io/<cluster-id> \
      --camunda-client-id=… --camunda-client-secret=… \
      --camunda-oauth-url=https://login.cloud.camunda.io/oauth/token \
      --camunda-token-audience=zeebe.camunda.io \
      cluster topology get
```

**Profiles.** Named sets of the same keys, for working with several clusters:

```sh
d8ctl profile add local --camunda-rest-address=http://localhost:8080 --camunda-auth-strategy=NONE
d8ctl profile add prod  --camunda-rest-address=https://… --camunda-client-id=… --camunda-client-secret=…
d8ctl profile add ci --from-env          # snapshot the current CAMUNDA_* variables
d8ctl profile list                       # * marks the active profile
d8ctl profile use prod                   # the default from now on
d8ctl --profile=local cluster topology get   # or D8CTL_PROFILE=local, for one command
d8ctl profile show prod                  # secrets are masked
d8ctl profile use --none                 # back to environment variables only
```

The first profile you add becomes active. Profiles live in
`~/.config/d8ctl/profiles.json` (`$XDG_CONFIG_HOME/d8ctl`, or `$D8CTL_CONFIG_DIR`),
written with mode 0600 because they can hold secrets.

**Existing c8ctl profiles and Camunda Modeler connections** work as they are.
d8ctl reads them (never writes them) from the same places c8ctl does
(`C8CTL_DATA_DIR`, `C8CTL_MODELER_DIR`, or the platform default), so d8ctl can
replace c8ctl without reconfiguring:

```sh
d8ctl list profiles                          # c8ctl spelling works too
  local                    c8ctl    http://localhost:8080/v2
* modeler:c8run (local)    modeler  http://localhost:8080/v2
d8ctl --profile prod cluster topology get    # a c8ctl profile
d8ctl --profile "modeler:c8run (local)" …    # a Modeler connection (name, or its id)
d8ctl use profile prod                       # d8ctl's own active profile
```

- c8ctl's active profile and tenant (`c8 use profile`, `c8 use tenant`) apply
  until you pick one in d8ctl; `d8ctl profile use --none` ignores them.
- With no profile and no `CAMUNDA_REST_ADDRESS`, d8ctl falls back like c8ctl:
  c8ctl's `CAMUNDA_BASE_URL` / `CAMUNDA_USERNAME` / `CAMUNDA_PASSWORD` variables,
  then c8ctl's `local` profile.
- Auth is chosen as c8ctl chooses it: OAuth if a client id and secret are set,
  else Basic, else none. c8ctl's custom `headers` are not supported (`profile
  show` says so).
- A name resolves d8ctl first, then c8ctl, then Modeler.

**Environment variables.** As for every Camunda SDK.

When the same key comes from more than one place, the highest wins:

1. `--camunda-*` switches
2. the selected profile: `--profile`, else `D8CTL_PROFILE`, else d8ctl's active
   profile, else c8ctl's
3. `CAMUNDA_*` environment variables
4. c8ctl's `CAMUNDA_BASE_URL` variables, else c8ctl's `local` profile
5. SDK defaults

`d8ctl profile --help` lists every switch.

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
