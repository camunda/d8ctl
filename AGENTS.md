# AGENTS.md

> This repo follows the central Camunda AGENTS guidelines:
> https://raw.githubusercontent.com/camunda/.github/refs/heads/main/AGENTS.md
> The instructions below extend those and take precedence on conflict.

## Role & boundary

**d8ctl** is a greenfield spike of a native, generated CLI for the Camunda 8
Orchestration Cluster API. Design: https://github.com/camunda/d8ctl/issues/1.
It is not a replacement for c8ctl.

The command surface is generated from the D SDK's bundled spec-metadata.
There is no hand-written per-operation handler.

Upstream: [orchestration-cluster-api-dlang](https://github.com/camunda/orchestration-cluster-api-dlang)
(path dependency `../orchestration-cluster-api-dlang`).

## Path map

| Path | Ownership |
| --- | --- |
| `source/d8ctl/app.d` | Entry + `run`. |
| `source/d8ctl/parse.d` | Argv. Accepts both resource-verb and verb-resource. |
| `source/d8ctl/help.d` | Progressive help. |
| `source/d8ctl/dispatch.d` | Generic live HTTP via `CamundaClient.request*`. |
| `source/d8ctl/catalog.d` | Lookups over the generated table. |
| `source/d8ctl/generated/catalog.d` | **Generated.** `make generate`. Never hand-edit. |
| `scripts/generate.py` | Catalog generator. |
| `scripts/check-safe.sh` | `@safe` ratchet (same contract as the SDK). |

## Strictness

LDC ≥ 1.43 only. Every module `@safe:`. `-preview=dip1000 -preview=nosharedaccess`.
Release keeps `-boundscheck=on`. No extra dub packages. No raw threads,
`__gshared`, or `union` outside a future `safeio.d`.

## Commands

```bash
make generate
make test
make lint
make check
```
