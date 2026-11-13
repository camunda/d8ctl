#!/usr/bin/env python3
"""Generate the d8ctl command catalog from the D SDK's bundled spec.

Reads orchestration-cluster-api-dlang/external-spec/bundled/{spec-metadata,rest-api.bundle}.json
and writes source/d8ctl/generated/catalog.d. Never hand-edit the output.

No extra D dependencies: the catalog is a static table of string slices.
Top-level JSON body properties become documented --flags; nested values stay
JSON strings. --body is still accepted and wins on conflict.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SDK_DIR = ROOT.parent / "orchestration-cluster-api-dlang"
SDK_META = SDK_DIR / "external-spec" / "bundled" / "spec-metadata.json"
SDK_SPEC = SDK_DIR / "external-spec" / "bundled" / "rest-api.bundle.json"
OUT = ROOT / "source" / "d8ctl" / "generated" / "catalog.d"

# Longest-first so "search" wins over "se", "cancel" over "can", etc.
VERBS = sorted(
    [
        "search",
        "create",
        "update",
        "delete",
        "cancel",
        "trigger",
        "assign",
        "unassign",
        "complete",
        "fail",
        "throw",
        "activate",
        "pin",
        "reset",
        "take",
        "list",
        "resume",
        "suspend",
        "migrate",
        "modify",
        "resolve",
        "publish",
        "correlate",
        "evaluate",
        "deploy",
        "get",
        "broadcast",
        "pause",
        "restore",
        "change",
        "sync",
        "complete",
    ],
    key=len,
    reverse=True,
)

RESERVED_FLAGS = {"help", "version", "dry-run", "order", "body", "h"}


def kebab(s: str) -> str:
    s = re.sub(r"([a-z0-9])([A-Z])", r"\1-\2", s)
    s = re.sub(r"[^a-zA-Z0-9]+", "-", s)
    return s.strip("-").lower()


def split_op(oid: str) -> tuple[str, str]:
    for v in VERBS:
        if oid == v:
            return v, oid
        if oid.startswith(v) and len(oid) > len(v) and oid[len(v)].isupper():
            rest = oid[len(v) :]
            return v, rest or oid
    m = re.match(r"^([a-z]+)(.*)$", oid)
    if m:
        return m.group(1), m.group(2) or oid
    return oid, oid


def d_string(value: str) -> str:
    return json.dumps(value, ensure_ascii=False)


def d_string_array(values: list[str]) -> str:
    if not values:
        return "null"
    return "[" + ", ".join(d_string(v) for v in values) + "]"


def kind_of(op: dict) -> str:
    status = op.get("successStatus") or 200
    ref = op.get("successResponseSchemaRef")
    ctypes = op.get("requestBodyContentTypes") or []
    if any("multipart" in c for c in ctypes):
        return "multipart"
    if status == 204:
        return "void"
    if not ref:
        # binary / text / empty — treat as text (caller prints body)
        return "text"
    return "json"


def first_sentence(text: str, limit: int = 96) -> str:
    text = re.sub(r"<[^>]+>", "", text or "")
    text = re.sub(r"\s+", " ", text).strip()
    if not text:
        return ""
    cut = text.find(". ")
    if 0 <= cut < limit:
        text = text[: cut + 1]
    elif len(text) > limit:
        text = text[: limit - 1].rstrip() + "…"
    return text


def ref_name(ref: str | None) -> str | None:
    if not ref:
        return None
    return ref.rsplit("/", 1)[-1]


def unwrap_type(schema: dict | None, schemas: dict, seen: set[str] | None = None) -> str | None:
    """Best-effort JSON type of a (possibly $ref / allOf) schema."""
    if not schema:
        return None
    if seen is None:
        seen = set()
    if "$ref" in schema:
        name = ref_name(schema["$ref"])
        if not name or name in seen:
            return None
        seen.add(name)
        return unwrap_type(schemas.get(name), schemas, seen)
    t = schema.get("type")
    if t:
        return t
    if schema.get("enum"):
        return "string"
    if schema.get("oneOf") or schema.get("anyOf"):
        return None
    if schema.get("allOf"):
        for part in schema["allOf"]:
            got = unwrap_type(part, schemas, seen)
            if got:
                return got
    return None


def classify_prop(prop: dict, schemas: dict) -> str:
    t = unwrap_type(prop, schemas)
    if t in ("string", "integer", "number", "boolean"):
        return t
    return "json"


def flatten_schema(name: str | None, schemas: dict, seen: set[str] | None = None) -> list[tuple[str, dict, bool]] | None:
    """Top-level properties after unfolding allOf. None means a union (don't flatten)."""
    if not name:
        return []
    if seen is None:
        seen = set()
    if name in seen:
        return []
    seen.add(name)
    schema = schemas.get(name)
    if not schema:
        return []
    if schema.get("oneOf") or schema.get("anyOf"):
        return None
    props: dict[str, dict] = {}
    required: set[str] = set()
    parts: list[dict] = []
    if schema.get("allOf"):
        parts.extend(schema["allOf"])
    parts.append(schema)
    for part in parts:
        if "$ref" in part:
            nested = flatten_schema(ref_name(part["$ref"]), schemas, seen)
            if nested is None:
                return None
            for pn, p, req in nested:
                props[pn] = p
                if req:
                    required.add(pn)
            continue
        if part.get("oneOf") or part.get("anyOf"):
            return None
        for pn, p in (part.get("properties") or {}).items():
            props[pn] = p
        for r in part.get("required") or []:
            required.add(r)
    return [(pn, props[pn], pn in required) for pn in props]


def body_fields_of(op: dict, schemas: dict) -> list[dict]:
    if not op.get("hasRequestBody"):
        return []
    ctypes = op.get("requestBodyContentTypes") or []
    if any("multipart" in c for c in ctypes):
        return []
    fields = flatten_schema(op.get("requestBodySchemaRef"), schemas)
    if fields is None:
        return []
    out: list[dict] = []
    for name, prop, required in fields:
        if name in RESERVED_FLAGS:
            continue
        out.append(
            {
                "name": name,
                "kind": classify_prop(prop, schemas),
                "required": bool(required),
                "doc": first_sentence(prop.get("description") or ""),
            }
        )
    return out


def d_body_fields(fields: list[dict]) -> str:
    if not fields:
        return "null"
    parts = []
    for f in fields:
        parts.append(
            "BodyField("
            f"{d_string(f['name'])}, "
            f"{d_string(f['kind'])}, "
            f"{str(f['required']).lower()}, "
            f"{d_string(f['doc'])})"
        )
    return "[" + ", ".join(parts) + "]"


def main() -> int:
    if not SDK_META.is_file():
        sys.exit(f"missing SDK spec-metadata: {SDK_META}")
    if not SDK_SPEC.is_file():
        sys.exit(f"missing SDK OpenAPI bundle: {SDK_SPEC}")
    meta = json.loads(SDK_META.read_text(encoding="utf-8"))
    spec = json.loads(SDK_SPEC.read_text(encoding="utf-8"))
    schemas = (spec.get("components") or {}).get("schemas") or {}
    ops = list(meta["operations"])
    spec_hash = meta.get("specHash") or ""

    rows: list[str] = []
    seen: set[tuple[str, str, str]] = set()
    field_count = 0
    ops_with_fields = 0
    for op in ops:
        oid = op["operationId"]
        tag = (op.get("tags") or ["untagged"])[0]
        ns = kebab(tag)
        verb, resource_raw = split_op(oid)
        resource = kebab(resource_raw) or kebab(verb)
        key = (ns, resource, verb)
        if key in seen:
            # Should not happen (checked offline); keep operationId unique via resource suffix.
            resource = kebab(oid)
        seen.add((ns, resource, verb))
        path_params = list(op.get("pathParams") or [])
        query = op.get("queryParams") or []
        q_req = [q["name"] for q in query if isinstance(q, dict) and q.get("required") and q.get("name")]
        q_opt = [q["name"] for q in query if isinstance(q, dict) and not q.get("required") and q.get("name")]
        ext = op.get("vendorExtensions") or {}
        added = ext.get("x-added-in-version") or ""
        kind = kind_of(op)
        has_body = bool(op.get("hasRequestBody"))
        fields = body_fields_of(op, schemas)
        if fields:
            ops_with_fields += 1
            field_count += len(fields)
        rows.append(
            "    Command(\n"
            f"        {d_string(oid)},\n"
            f"        {d_string(ns)},\n"
            f"        {d_string(resource)},\n"
            f"        {d_string(verb)},\n"
            f"        {d_string((op.get('method') or 'get').upper())},\n"
            f"        {d_string(op.get('path') or '/')},\n"
            f"        {d_string((op.get('summary') or oid).strip())},\n"
            f"        {d_string(added)},\n"
            f"        {d_string(kind)},\n"
            f"        {str(has_body).lower()},\n"
            f"        {d_string_array(path_params)},\n"
            f"        {d_string_array(q_req)},\n"
            f"        {d_string_array(q_opt)},\n"
            f"        {d_body_fields(fields)},\n"
            "    ),"
        )

    body = f"""\
/// Generated by scripts/generate.py — DO NOT EDIT.
///
/// One row per Orchestration Cluster REST operation, derived from the D SDK's
/// bundled spec-metadata.json + rest-api.bundle.json. The argv parser and the
/// HTTP dispatcher both walk this table; there is no hand-written per-operation
/// handler.
module d8ctl.generated.catalog;

@safe:

/// A top-level JSON body property, exposed as `--name=value`.
/// `kind` is `string`, `integer`, `number`, `boolean`, or `json` (pass a JSON
/// value — object, array, or anything the flag cannot type).
struct BodyField
{{
    string name;
    string kind;
    bool required;
    string doc;
}}

/// A generated CLI command. `namespace` is the kebab-case OpenAPI tag
/// (`cluster`, `process-instance`, …). `resource` / `verb` are split from
/// the operationId so the parser can accept either order.
struct Command
{{
    string operationId;
    string namespace;
    string resource;
    string verb;
    string method;
    string path;
    string summary;
    string addedInVersion;
    /// `json`, `void`, `text`, or `multipart`.
    string kind;
    bool hasBody;
    string[] pathParams;
    string[] requiredQuery;
    string[] optionalQuery;
    BodyField[] bodyFields;
}}

/// SHA-256 of the bundled spec this catalog was generated from.
enum catalogSpecHash = {d_string(spec_hash)};

/// Number of operations in the catalog.
enum catalogOperationCount = {len(ops)};

immutable Command[] catalog = [
{chr(10).join(rows)}
];
"""
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(body, encoding="utf-8")
    print(
        f"generate: {len(ops)} commands, {ops_with_fields} with body flags "
        f"({field_count} fields) -> {OUT.relative_to(ROOT)}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
