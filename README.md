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
(`--filter='{"state":"ACTIVE"}'`). A `oneOf`/`anyOf` body of object
variants (create process instance: by key or by BPMN process id) offers
every variant's fields; a field is required only when every variant
requires it, and the server checks the combination. Other unions stay
`--body` only.

`--order=resource|verb` only changes how help lists commands. Both orders
always parse.

## Output contract

d8ctl is built for agents and scripts, so its output is a contract (#16):

- **stdout** is the API response, unchanged: no envelope, so the OpenAPI
  spec is the output schema. JSON is compact when stdout is not a terminal
  and pretty in one; `--pretty` / `--compact` override. A command whose
  response has no body prints nothing.
- **stderr** carries errors as one JSON line when stderr is not a terminal,
  and as `d8ctl: <message>` in one; `--output=json|text` overrides. An HTTP
  error carries the API's problem fields:

  ```json
  {"error":{"kind":"not-found","status":404,"operation":"getProcessInstance","message":"HTTP 404: Process instance not found","title":"Process instance not found","detail":"No process instance with key 2251799813685249.","type":"about:blank","instance":""}}
  ```

  Warnings are `{"warning":"…"}` lines.
- **Exit codes:**

  | code | `error.kind` |
  | --- | --- |
  | 0 | success |
  | 1 | `other` |
  | 2 | `usage`, `config` |
  | 3 | `auth`: 401 or 403, or token fetch failed |
  | 4 | `not-found`: 404 |
  | 5 | `conflict` (409), `client` (other 4xx) |
  | 6 | `server`: 5xx or backpressure |
  | 7 | `network`: connection, timeout or TLS |

- **Retries.** Every request — cluster and extension calls, and extension
  spec downloads — is retried on a network error (dropped connection, reset,
  TLS handshake failure, timeout) and on HTTP 429/502/503/504, with
  exponential backoff and full jitter. Defaults: 3 attempts, 100 ms base,
  2 s cap. For a flaky route raise them per call
  (`--camunda-sdk-http-retry-max-attempts=10
  --camunda-sdk-http-retry-max-delay-ms=5000`) or in the profile
  (`CAMUNDA_SDK_HTTP_RETRY_MAX_ATTEMPTS`, `…_BASE_DELAY_MS`, `…_MAX_DELAY_MS`).
  POST/PUT/PATCH are retried too, so a request that reached the server
  before the connection dropped can be applied twice — the same trade-off
  as `curl --retry`.
- **`--fields=a,b.c`** trims the JSON response client-side (the API has no
  server-side selection). It applies to the operation's response schema: an
  array → each item; an object with one array of objects (`items`) → each item,
  other top-level fields (`page`) kept, unless you name one: then you get
  exactly the fields you named (`--fields=page.totalItems` prints only the
  count; add `items.x` or bare `items` to get items too); otherwise the
  object itself. With
  several arrays, prefix the array name (`--fields=prs.prKey,prs.status`).
  Dotted paths keep nesting. The whole selection is validated against the
  schema before the request is sent: unknown fields are a usage error
  (exit 2) listing the valid names — a typo never reaches the server, so a
  mutating command cannot create the resource and then hide its key.
  Undeclared fields the server sends are dropped. Not for non-JSON responses
  (usage error) and never applied to errors. `--dry-run` shows the selection;
  `--help` lists "Response fields" (`responseFields` in `--help --json`).

  ```sh
  d8ctl cluster process-instances search --filter='{"state":"ACTIVE"}' --fields=processInstanceKey,startDate
  ```
- **`--help --json`** describes commands as JSON. On a command, it gives the
  invocation, operation, positional arguments, flags (query and body, with
  type and required), whether `--body` is accepted, and the output kind. On a
  namespace, resource or the root, it lists command summaries
  (`d8ctl --help --json` lists them all).

`--pretty`, `--compact`, `--output` and `--json` are reserved global flags.

## Runtime extensions

Beyond the built-in `cluster` namespace, d8ctl can install namespaces
generated at runtime from a running server's OpenAPI spec (first target:
Nano Workforce):

```sh
d8ctl extension add nwf --spec=http://merlin.local:8080/.../app/api-docs/openapi.json [--profile=merlin]
d8ctl nwf --help                    # the namespace, from the cached spec
d8ctl nwf escalations list          # live: GET …/api/escalations
d8ctl nwf feature start --body='{…}' --dry-run
d8ctl extension list [--check]      # installed extensions (age, sha256, source)
d8ctl extension update [nwf|--all]  # re-download (skips on a matching sha256)
d8ctl extension remove nwf
```

The spec is cached under `<configDir>/extensions/<name>/` (`spec.json` byte
for byte plus an `extension.json` manifest, written 0600 in a 0700 dir).
Ordinary `d8ctl <name> …` commands read only the cache — never the network.
The namespace has its own base URL (the spec's `servers[0].url` resolved
against the spec URL, or `--base-url`); a profile supplies only auth and
headers, never its cluster address.

**Profile-relative extensions.** When the same server is reachable by more
than one route (a LAN address at home, a Tailscale URL with basic auth away),
give `--spec` (and `--base-url`, if needed) as root-relative **paths**. The
extension then follows the selected profile, like `cluster` commands do:

```sh
d8ctl extension add nwf --spec=/console/app-view/Workforce/app/api-docs/openapi.json
d8ctl nwf escalations list                      # the active profile's host
d8ctl nwf escalations list --profile=merlin-ts  # same API, the Tailscale route
```

Each call resolves the paths against the origin (`scheme://host:port`) of the
selected profile's REST address: `--profile`, else `D8CTL_PROFILE`, else the
active profile. That profile's credentials go only to its own host, so
following the active profile cannot send them anywhere new. No profile is
stored with the extension; `add`, `update` and `list --check` fetch the spec
through the selected profile into one shared cache. A spec whose server is on
another host is refused (pass `--base-url=<path>`).

Command names come from the spec's `x-cli.command` when present, else from
splitting the `operationId`. `x-cli.command` is a non-empty array of
kebab-case words (nano-ide ADR 0068), used as an exact command path —
`d8ctl <name> w1 … wn`, never reordered; `x-cli.aliases` (arrays of words)
add more paths to the same operation. A string `command` or a duplicate path
is rejected. A path may prefix another (`guide` and `guide skill`): the
command is then also a group, the longest matching path wins, and its
`--help` lists the subcommands. Operations with `x-cli.audience: operator` (or
excluded from the MCP surface with no `x-cli`) are hidden from help and
refused unless you pass `--operator`; `x-cli.exclude` removes them
completely. Extension names are reserved against the built-ins (`cluster`,
`profile`, `extension`, …). See `d8ctl extension --help`.

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
`~/.config/d8ctl/profiles.json` (`%APPDATA%\d8ctl` on Windows; `$XDG_CONFIG_HOME/d8ctl`
or `$D8CTL_CONFIG_DIR` override either), written with mode 0600 because they can
hold secrets. On Windows the file inherits the per-user permissions of `%APPDATA%`.

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
  else Basic, else none. c8ctl's custom `headers` map to
  `CAMUNDA_DEFAULT_HEADERS`.
- A name resolves d8ctl first, then c8ctl, then Modeler.

**Environment variables.** As for every Camunda SDK.

When the same key comes from more than one place, the highest wins:

1. `--camunda-*` switches
2. the selected profile: `--profile`, else `D8CTL_PROFILE`, else d8ctl's active
   profile, else c8ctl's
3. `CAMUNDA_*` environment variables
4. c8ctl's `CAMUNDA_BASE_URL` variables, else c8ctl's `local` profile
5. SDK defaults

**Custom HTTP headers.** `--header 'Name: value'` (repeatable, curl syntax)
adds a header to every API request of one command, or stores it with
`profile add`. The SDK key is `CAMUNDA_DEFAULT_HEADERS`, a JSON object
(`--camunda-default-headers='{"X-Api-Key":"…"}'`, the env var, or
`--from-env`). Headers merge per name, case-insensitively: `--header` >
profile / `--camunda-default-headers` > env. They are applied last, so they
may replace `Authorization` (as in c8ctl), and are never sent to the OAuth
token endpoint. Values are masked in `profile show` and `--dry-run`.

```sh
d8ctl --header 'X-Api-Key: …' cluster topology get
d8ctl profile add gw --camunda-rest-address=https://gw/v2 --header 'X-Api-Key: …'
```

`d8ctl profile --help` lists every switch.

## Install

```sh
brew install camunda/tap/d8ctl        # macOS, Linux
npm install -g @camunda8/d8ctl        # or: npx @camunda8/d8ctl …
```

Or download the binary for your platform from
[Releases](https://github.com/camunda/d8ctl/releases): `d8ctl-darwin-arm64`,
`d8ctl-darwin-amd64`, `d8ctl-linux-amd64`, `d8ctl-linux-arm64`, or
`d8ctl-windows-amd64.exe`. Each has a `.sha256` file to check it against. The
Linux binaries need glibc and `libcurl4`. On Windows d8ctl uses the system's
HTTP stack (WinHTTP), so nothing else is needed.

## Releases

Pushes to `main` cut a GitHub Release (`vX.Y.Z`) with the binaries above,
built after the version is resolved, so each reports its own version. The
same binaries go to npm ([npm/README.md](npm/README.md)), and the Homebrew
tap [camunda/homebrew-tap](https://github.com/camunda/homebrew-tap) picks
up new releases on its own. The explainer site is `docs/` →
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

`scripts/generate.d` (`dub run --single scripts/generate.d`; needs only LDC and
dub) reads `external-spec/bundled/{rest-api.bundle,spec-metadata}.json` and
writes `source/d8ctl/generated/catalog.d` (one row per operation; 247 today).
The naming and flag rules live in `source/d8ctl/specmodel.d`, which reads
the spec with `camunda-orchestration-sdk:openapi`. It also works on plain
OpenAPI documents without Camunda `spec-metadata.json`.
Do not hand-edit the catalog. There is no per-operation handler — dispatch
walks the table and calls `Transport.requestJson` / `requestVoid` / `requestText`
from `camunda-orchestration-sdk:runtime`.

Multipart operations (`createDeployment`, `createDocument`, `createDocuments`)
are refused until we add file flags.

## License

Apache-2.0.
