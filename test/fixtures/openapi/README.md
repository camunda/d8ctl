# OpenAPI fixtures

Real specs, stored verbatim (re-indented only), for runtime-extension tests (#9) and the
spec-to-commands model (#8). Tests must use these files and never fetch a live server.

| File | Source | Fingerprint |
| --- | --- | --- |
| `nano-workforce-0.210.2.json` | `GET <app>/api-docs/openapi.json` on a Nano Workforce 0.210.2 instance | `/version` `gitSha` `56f0ff4c4a3a0d8a3cf68745b1f7b9bf539987da` |

The nano-workforce spec is OpenAPI 3.0.3 with 52 operations and relative `servers: [{url: api}]`.
It has **no** `x-cli` extensions (those arrive with nanobpm/nano-workforce#961), so it covers the
operationId-fallback naming path and the `x-mcp: {exclude: true}` operator-hiding default
(e.g. `dispatchDeliveryGraph`).

To refresh, add a new file next to the old one, named for the new version (don't overwrite it):

```bash
curl -sS <app>/version | jq -r .version            # -> X.Y.Z
curl -sS <app>/api-docs/openapi.json \
  | python3 -c 'import json,sys; json.dump(json.load(sys.stdin), sys.stdout, indent=1, ensure_ascii=False); print()' \
  > test/fixtures/openapi/nano-workforce-X.Y.Z.json
```

Once #961 ships, add an `x-cli`-bearing version alongside this one so both naming paths stay covered.
