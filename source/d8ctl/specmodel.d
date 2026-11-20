/**
OpenAPI spec → d8ctl command model.

Holds the CLI rules shared by the build-time catalog generator
(`scripts/generate.d`) and runtime extension loading: operationId → resource
and verb, kebab flag naming, request body → flags, help text, and root-server
detection.

Works from a plain OpenAPI document. A Camunda `spec-metadata.json` sidecar is
optional; when present it supplies the operation list (and the spec hash).
Every failure is an exception (`OpenApiException` or `SpecModelException`),
never a process exit.
*/
module d8ctl.specmodel;

@safe:

import std.algorithm.iteration : map;
import std.array : appender, array, join, replace;
import std.conv : to;
import std.regex : ctRegex, matchFirst, replaceAll;
import std.string : endsWith, indexOf, startsWith, strip, stripRight, toLower, toUpper;
import std.uni : isUpper;

import camunda.openapi;

/// A model error that is not about JSON/OpenAPI structure (e.g. an unsupported server path).
class SpecModelException : OpenApiException
{
    this(string msg, string path = null, string file = __FILE__, size_t line = __LINE__)
    {
        super(msg, path, file, line);
    }
}

/// A top-level JSON body property, exposed as `--name=value`.
struct ModelField
{
    string name;
    /// `string`, `integer`, `number`, `boolean`, or `json`.
    string kind;
    bool required;
    string doc;
}

/// A selectable response field: a top-level name of the selection target
/// (see `ModelCommand.responseTarget`), with the names of its own object
/// properties when it is an object (dotted `--fields=a.b` paths).
struct ModelResponseField
{
    string name;
    /// `string`, `integer`, `number`, `boolean`, `array`, `object`, or `json`.
    string kind;
    /// Nested object property names, one level deep.
    string[] children;
}

/// One CLI command derived from one OpenAPI operation.
struct ModelCommand
{
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
    ModelField[] bodyFields;
    bool rootServer;
    /// Hidden unless `--operator` (`x-cli.audience: operator`, or `x-mcp`
    /// exclusion with no `x-cli` — the nano-workforce operator default).
    bool operatorOnly;
    /// `x-cli.exclude: true` — the command does not exist at all.
    bool excluded;
    /// Positional argument names from `x-cli.positional`; empty = path order.
    string[] positional;
    /// Explicit command paths from `x-cli.command` + `x-cli.aliases`
    /// (namespace-relative words, as authored). Non-empty = the command is
    /// reached only by these exact word paths, never by resource/verb reordering.
    string[][] paths;
    /// Where `--fields` selection applies (#21): `array` (trim each item),
    /// `items` (trim each item of the one array-of-objects property), `object`
    /// (trim the response itself), `multi` (several arrays of objects: a
    /// `name.field` prefix is required), or empty (no JSON object/array
    /// response — `--fields` is a usage error).
    string responseTarget;
    /// Selection-target fields, in declaration order. `multi` targets carry
    /// the array names (each with its items' property names as children).
    ModelResponseField[] responseFields;
}

/// The command model of a whole spec.
struct Catalog
{
    ModelCommand[] commands;
    /// `specHash` from metadata; empty without metadata.
    string specHash;
}

/// Verbs recognised at the start of an operationId, longest first.
immutable string[] VERBS = sortedVerbs();

/// Body properties that would collide with built-in switches.
immutable string[] RESERVED_FLAGS = ["help", "version", "dry-run", "order", "body", "h"];

/// True when `--<name>` is consumed by the CLI itself (help, profile, header, `--camunda-*`).
bool isReservedFlag(string name)
{
    import std.algorithm.searching : canFind;

    foreach (n; [name, kebab(name)])
        if (RESERVED_FLAGS.canFind(n) || n == "profile" || n == "header" || n.startsWith("camunda-"))
            return true;
    return false;
}

private string[] sortedVerbs() pure
{
    import std.algorithm.mutation : SwapStrategy;
    import std.algorithm.sorting : sort;

    auto v = [
        "search", "create", "update", "delete", "cancel", "trigger", "assign",
        "unassign", "complete", "fail", "throw", "activate", "pin", "reset",
        "take", "list", "resume", "suspend", "migrate", "modify", "resolve",
        "publish", "correlate", "evaluate", "deploy", "get", "broadcast",
        "pause", "restore", "change", "sync",
    ];
    v.sort!((a, b) => a.length > b.length, SwapStrategy.stable);
    return v;
}

/// `camelCase/stuff` → `camel-case-stuff`.
string kebab(string s)
{
    s = s.replaceAll(ctRegex!`([a-z0-9])([A-Z])`, "$1-$2");
    s = s.replaceAll(ctRegex!`[^a-zA-Z0-9]+`, "-");
    while (s.startsWith("-"))
        s = s[1 .. $];
    while (s.endsWith("-"))
        s = s[0 .. $ - 1];
    return s.toLower;
}

/// operationId → (verb, resource), e.g. `searchProcessInstances` → (`search`, `ProcessInstances`).
string[2] splitOp(string oid)
{
    foreach (v; VERBS)
    {
        if (oid == v)
            return [v, oid];
        if (oid.startsWith(v) && oid.length > v.length && isUpper(oid[v.length]))
            return [v, oid[v.length .. $]];
    }
    auto m = oid.matchFirst(ctRegex!`^([a-z]+)(.*)$`);
    if (!m.empty)
        return [m[1], m[2].length ? m[2] : oid];
    return [oid, oid];
}

/// First sentence of `text` (HTML tags removed, whitespace collapsed), at most `limit` characters.
string firstSentence(string text, size_t limit = 96)
{
    import std.utf : toUTF8, toUTF32;

    text = text.replaceAll(ctRegex!`<[^>]+>`, "");
    text = text.replaceAll(ctRegex!`\s+`, " ").strip;
    if (!text.length)
        return "";
    dstring t = text.toUTF32;
    const cut = t.indexOf(". "d);
    if (cut >= 0 && cut < limit)
        t = t[0 .. cut + 1];
    else if (t.length > limit)
        t = t[0 .. limit - 1].stripRight ~ "…"d;
    return t.toUTF8;
}

private enum maxSchemaDepth = 200;

/// Best-effort JSON type of a (possibly `$ref` / `allOf`) schema.
private string unwrapType(Spec spec, J schema, ref bool[string] seen, size_t depth = 0)
{
    if (schema is null || !schema.isObj || !truthy(schema))
        return null;
    if (depth > maxSchemaDepth)
        throw new OpenApiLimitException("schema type resolution too deep");
    if (schema.has("$ref"))
    {
        const name = spec.refName(schema);
        if (!name.length || name in seen)
            return null;
        seen[name] = true;
        return unwrapType(spec, spec.schemas.get(name), seen, depth + 1);
    }
    if (auto t = schema.get("type"))
        if (truthy(t))
            return t.isStr ? t.text : null; // 3.1 type unions (arrays) → json
    if (truthy(schema.get("enum")))
        return "string";
    if (truthy(schema.get("oneOf")) || truthy(schema.get("anyOf")))
        return null;
    foreach (part; itemsOf(schema.get("allOf")))
        if (auto got = unwrapType(spec, part, seen, depth + 1))
            return got;
    return null;
}

/// Flag kind of a body property.
string classifyProp(Spec spec, J prop)
{
    bool[string] seen;
    const t = unwrapType(spec, prop, seen);
    switch (t)
    {
    case "string", "integer", "number", "boolean":
        return t;
    default:
        return "json";
    }
}

private struct Flat
{
    bool isUnion;
    string[] names;
    J[string] props;
    bool[string] required;

    void put(string k, J v)
    {
        if (k !in props)
            names ~= k;
        props[k] = v;
    }
}

/// A `oneOf`/`anyOf` of object variants as flags: every variant's
/// properties (the first declaration wins), required only when every variant
/// requires it. The server still validates which combination is sent.
/// `isUnion` (give up: `--body` only) when a variant is not an object with
/// properties. Each variant gets its own copy of `seen`, so variants sharing
/// a base schema both count it.
private Flat flattenUnion(Spec spec, J schema, ref bool[string] seen, size_t depth)
{
    Flat out_;
    J[] variants = itemsOf(schema.get("oneOf")).dup ~ itemsOf(schema.get("anyOf"));
    bool[string] req;
    foreach (i, v; variants)
    {
        auto own = seen.dup;
        Flat f;
        if (v.isObj && v.has("$ref"))
        {
            const r = spec.refName(v);
            f = r.length ? flattenSchema(spec, r, spec.schemas.get(r), own, depth + 1) : Flat.init;
        }
        else
            f = flattenSchema(spec, null, v, own, depth + 1);
        if (f.isUnion || !f.names.length)
        {
            out_.isUnion = true;
            return out_;
        }
        foreach (pn; f.names)
            if (pn !in out_.props)
                out_.put(pn, f.props[pn]);
        if (i == 0)
        {
            foreach (k; f.required.byKey)
                req[k] = true;
        }
        else
            foreach (k; req.keys)
                if (k !in f.required)
                    req.remove(k);
    }
    out_.required = req;
    return out_;
}

/// Merge `from` into `into`; false (stop: `--body` only) when `from` is an
/// unusable oneOf/anyOf.
private bool mergeFlat(ref Flat into, Flat from)
{
    if (from.isUnion)
    {
        into = from;
        return false;
    }
    foreach (pn; from.names)
        into.put(pn, from.props[pn]);
    foreach (rn; from.required.byKey)
        into.required[rn] = true;
    return true;
}

/// Top-level properties after unfolding `allOf` and object `oneOf`/`anyOf`
/// (see flattenUnion); `isUnion` when a oneOf/anyOf cannot be flattened.
private Flat flattenSchema(Spec spec, string name, J schema, ref bool[string] seen, size_t depth = 0)
{
    Flat out_;
    if (depth > maxSchemaDepth)
        throw new OpenApiLimitException("schema flattening too deep");
    if (name !is null)
    {
        if (name in seen)
            return out_;
        seen[name] = true;
    }
    if (schema is null || !schema.isObj || !truthy(schema))
        return out_;
    J[] parts = itemsOf(schema.get("allOf")).dup ~ schema;
    foreach (part; parts)
    {
        if (part.has("$ref"))
        {
            const r = spec.refName(part);
            auto nested = r.length ? flattenSchema(spec, r, spec.schemas.get(r), seen, depth + 1) : Flat.init;
            if (!mergeFlat(out_, nested))
                return out_;
            // OpenAPI 3.1: sibling keywords next to `$ref` still apply.
        }
        if (truthy(part.get("oneOf")) || truthy(part.get("anyOf")))
            if (!mergeFlat(out_, flattenUnion(spec, part, seen, depth)))
                return out_;
        if (part !is schema && truthy(part.get("allOf")))
        {
            if (!mergeFlat(out_, flattenSchema(spec, null, part, seen, depth + 1)))
                return out_;
            continue;
        }
        auto props = part.get("properties");
        foreach (pn; keysOf(props))
            out_.put(pn, props.fields[pn]);
        foreach (r; itemsOf(part.get("required")))
            if (r.isStr)
                out_.required[r.text] = true;
    }
    return out_;
}

/// Operation fields the model needs, from metadata or from `paths`.
private struct OpInfo
{
    string operationId;
    string method;
    string path;
    string summary;
    string[] pathParams;
    string[] requiredQuery;
    string[] optionalQuery;
    long successStatus = 200;
    bool hasResponseSchema;
    /// `components/schemas` name of the 2xx JSON response, when it is one.
    string responseRef;
    /// The 2xx JSON response schema itself, when not a bare `$ref`.
    J responseSchema;
    string[] requestBodyContentTypes;
    bool hasRequestBody;
    string bodyRef;
    J bodySchema;
    J vendorExtensions;
}

private bool isMultipart(const string[] ctypes)
{
    foreach (c; ctypes)
        if (c.indexOf("multipart") >= 0)
            return true;
    return false;
}

private string kindOf(ref OpInfo op)
{
    if (isMultipart(op.requestBodyContentTypes))
        return "multipart";
    if (op.successStatus == 204)
        return "void";
    if (!op.hasResponseSchema)
        return "text";
    return "json";
}

private ModelField[] bodyFieldsOf(Spec spec, ref OpInfo op)
{
    import std.algorithm.searching : canFind;

    if (!op.hasRequestBody || isMultipart(op.requestBodyContentTypes))
        return null;
    bool[string] seen;
    Flat flat;
    if (op.bodyRef.length)
        flat = flattenSchema(spec, op.bodyRef, spec.schemas.get(op.bodyRef), seen);
    else if (op.bodySchema !is null)
        flat = flattenSchema(spec, null, op.bodySchema, seen);
    if (flat.isUnion)
        return null;
    ModelField[] fields;
    foreach (n; flat.names)
    {
        if (isReservedFlag(n))
            continue;
        auto p = flat.props[n];
        fields ~= ModelField(n, classifyProp(spec, p), (n in flat.required) !is null,
            firstSentence(p.get("description").orS("")));
    }
    return fields;
}

// ---- Response field selection (`--fields`, #21) ----

/// The property names of an object schema (one level), after unfolding
/// `$ref`/`allOf`/object `oneOf`/`anyOf`. Empty for non-objects and
/// unflattenable unions.
private string[] propNames(Spec spec, J schema, bool[string] seen, size_t depth = 0)
{
    if (schema is null || !schema.isObj || !truthy(schema))
        return null;
    if (depth > maxSchemaDepth)
        throw new OpenApiLimitException("schema property listing too deep");
    if (schema.has("$ref"))
    {
        const name = spec.refName(schema);
        if (!name.length || name in seen)
            return null;
        seen[name] = true;
        return propNames(spec, spec.schemas.get(name), seen, depth + 1);
    }
    string[] out_;
    foreach (part; itemsOf(schema.get("allOf")))
        foreach (n; propNames(spec, part, seen, depth + 1))
        {
            import std.algorithm.searching : canFind;

            if (!out_.canFind(n))
                out_ ~= n;
        }
    if (truthy(schema.get("oneOf")) || truthy(schema.get("anyOf")))
    {
        auto own = seen.dup;
        auto flat = flattenUnion(spec, schema, own, depth);
        if (!flat.isUnion)
            foreach (n; flat.names)
            {
                import std.algorithm.searching : canFind;

                if (!out_.canFind(n))
                    out_ ~= n;
            }
    }
    auto props = schema.get("properties");
    foreach (k; keysOf(props))
    {
        import std.algorithm.searching : canFind;

        if (!out_.canFind(k))
            out_ ~= k;
    }
    return out_;
}

/// The `items` schema of an array schema (through `$ref`/`allOf`), or null.
private J arrayItems(Spec spec, J schema, bool[string] seen, size_t depth = 0)
{
    if (schema is null || !schema.isObj || !truthy(schema))
        return null;
    if (depth > maxSchemaDepth)
        throw new OpenApiLimitException("array items resolution too deep");
    if (schema.has("$ref"))
    {
        const name = spec.refName(schema);
        if (!name.length || name in seen)
            return null;
        seen[name] = true;
        return arrayItems(spec, spec.schemas.get(name), seen, depth + 1);
    }
    if (auto it = schema.get("items"))
        if (truthy(it) && it.isObj)
            return it;
    foreach (part; itemsOf(schema.get("allOf")))
        if (auto got = arrayItems(spec, part, seen, depth + 1))
            return got;
    return null;
}

/// True when the schema is (through `$ref`/`allOf`) an object with properties.
private bool isObjectWithProps(Spec spec, J schema, bool[string] seen, size_t depth = 0)
{
    if (schema is null || !schema.isObj || !truthy(schema))
        return false;
    if (depth > maxSchemaDepth)
        throw new OpenApiLimitException("object check too deep");
    if (schema.has("$ref"))
    {
        const name = spec.refName(schema);
        if (!name.length || name in seen)
            return false;
        seen[name] = true;
        return isObjectWithProps(spec, spec.schemas.get(name), seen, depth + 1);
    }
    if (truthy(schema.get("properties")))
        return true;
    foreach (part; itemsOf(schema.get("allOf")))
        if (isObjectWithProps(spec, part, seen, depth + 1))
            return true;
    return false;
}

/// One flattened property as a selectable response field (its own object
/// properties become dotted-path children).
private ModelResponseField responseFieldOf(Spec spec, string name, J prop, bool[string] seen)
{
    ModelResponseField f;
    f.name = name;
    f.kind = classifyProp(spec, prop);
    if (f.kind == "json")
    {
        // classifyProp only knows scalars; label arrays and objects.
        bool[string] own;
        const t = unwrapType(spec, prop, own);
        if (t == "array")
            f.kind = "array";
        else if (t == "object")
            f.kind = "object";
        else
        {
            bool[string] objSeen;
            if (isObjectWithProps(spec, prop, objSeen))
                f.kind = "object";
        }
    }
    if (f.kind == "object")
    {
        auto own = seen.dup;
        f.children = propNames(spec, prop, own);
    }
    return f;
}

/// The selectable fields of an object schema, in declaration order.
private ModelResponseField[] objectFields(Spec spec, J schema, bool[string] seen, size_t depth = 0)
{
    ModelResponseField[] out_;
    if (schema is null || !schema.isObj || !truthy(schema))
        return out_;
    if (depth > maxSchemaDepth)
        throw new OpenApiLimitException("response field listing too deep");
    if (schema.has("$ref"))
    {
        const name = spec.refName(schema);
        if (!name.length || name in seen)
            return out_;
        seen[name] = true;
        return objectFields(spec, spec.schemas.get(name), seen, depth + 1);
    }
    foreach (part; itemsOf(schema.get("allOf")))
        foreach (f; objectFields(spec, part, seen, depth + 1))
        {
            import std.algorithm.searching : canFind;

            if (!out_.map!(x => x.name).canFind(f.name))
                out_ ~= f;
        }
    if (truthy(schema.get("oneOf")) || truthy(schema.get("anyOf")))
    {
        auto own = seen.dup;
        auto flat = flattenUnion(spec, schema, own, depth);
        if (!flat.isUnion)
            foreach (n; flat.names)
            {
                import std.algorithm.searching : canFind;

                if (!out_.map!(x => x.name).canFind(n))
                    out_ ~= responseFieldOf(spec, n, flat.props[n], seen);
            }
    }
    auto props = schema.get("properties");
    foreach (k; keysOf(props))
    {
        import std.algorithm.searching : canFind;

        if (!out_.map!(x => x.name).canFind(k))
            out_ ~= responseFieldOf(spec, k, props.fields[k], seen);
    }
    return out_;
}

/// Derive the `--fields` selection target and its fields from the 2xx JSON
/// response schema (#21): an array trims each item; an object with exactly
/// one array-of-objects property (Camunda `items`, nwf `prs`, …) trims that
/// array's items and keeps the other top-level fields; several such arrays
/// require a `name.field` prefix (`multi`); anything else trims the object.
private void responseModel(Spec spec, ref OpInfo op, out string target, out ModelResponseField[] fields)
{
    target = null;
    fields = null;
    if (!op.hasResponseSchema || op.successStatus == 204)
        return;
    J schema;
    bool[string] seen;
    if (op.responseRef.length)
    {
        schema = spec.schemas.get(op.responseRef);
        if (schema is null)
            throw new OpenApiException("$ref to missing schema component: #/components/schemas/"
                ~ pointerEscape(op.responseRef));
        seen[op.responseRef] = true;
    }
    else
        schema = op.responseSchema;
    const t = unwrapType(spec, schema, seen);
    if (t == "array")
    {
        auto items = arrayItems(spec, schema, seen.dup);
        if (!propNames(spec, items, seen.dup).length)
            return; // an array of scalars: nothing to select
        target = "array";
        fields = objectFields(spec, items, seen.dup);
        return;
    }
    // Object (or unknown) shape: look at its properties.
    auto flat = objectFields(spec, schema, seen.dup);
    if (!flat.length)
        return; // scalar or opaque JSON: --fields is a usage error
    // The array-of-objects properties (Camunda `items`; nwf `prs`, …).
    ModelResponseField[] arrays;
    foreach (f; flat)
    {
        if (f.kind != "array")
            continue;
        auto prop = findProp(spec, schema, f.name, seen.dup);
        auto items = arrayItems(spec, prop, seen.dup);
        if (items is null || !isObjectWithProps(spec, items, seen.dup))
            continue;
        auto itemFields = objectFields(spec, items, seen.dup);
        if (!itemFields.length)
            continue;
        f.children = itemFields.map!(x => x.name).array;
        arrays ~= f;
    }
    if (arrays.length == 1)
    {
        target = "items";
        auto items = arrayItems(spec, findProp(spec, schema, arrays[0].name, seen.dup), seen.dup);
        fields = objectFields(spec, items, seen.dup);
        return;
    }
    if (arrays.length > 1)
    {
        target = "multi";
        fields = arrays;
        return;
    }
    target = "object";
    fields = flat;
}

/// The (possibly `$ref`/`allOf`-nested) declaration of property `name`.
private J findProp(Spec spec, J schema, string name, bool[string] seen, size_t depth = 0)
{
    if (schema is null || !schema.isObj || !truthy(schema))
        return null;
    if (depth > maxSchemaDepth)
        throw new OpenApiLimitException("property lookup too deep");
    if (schema.has("$ref"))
    {
        const n = spec.refName(schema);
        if (!n.length || n in seen)
            return null;
        seen[n] = true;
        return findProp(spec, spec.schemas.get(n), name, seen, depth + 1);
    }
    if (auto props = schema.get("properties"))
        if (auto p = props.get(name))
            return p;
    foreach (part; itemsOf(schema.get("allOf")))
        if (auto p = findProp(spec, part, name, seen, depth + 1))
            return p;
    return null;
}

/// Path part of the first server URL (`{schema}://{host}:{port}/v2` → `/v2`); null without servers.
private string serverPath(J servers)
{
    auto list = itemsOf(servers);
    if (!list.length)
        return null;
    string rest = list[0].get("url").orS("");
    // Server variables take their declared defaults (as resolveBaseUrl does).
    if (auto vars = list[0].get("variables"))
        foreach (k; keysOf(vars))
            rest = rest.replace("{" ~ k ~ "}", vars.get(k).get("default").orS(""));
    const sep = rest.indexOf("://");
    string p;
    if (sep >= 0)
    {
        rest = rest[sep + 3 .. $];
        const i = rest.indexOf('/');
        if (i < 0)
            return "";
        p = rest[i .. $];
    }
    else // relative server URL (`api`, `/api`, `/`): the whole value is the path
        p = rest.startsWith("/") ? rest : "/" ~ rest;
    while (p.endsWith("/"))
        p = p[0 .. $ - 1];
    return p;
}

/// True when the operation (or its path) declares the bare-root server
/// instead of the top-level one (e.g. Camunda cluster-admin ops).
private bool isRootServer(Spec spec, ref OpInfo op)
{
    auto item = spec.spec.get("paths").get(op.path);
    auto operation = item.get(op.method.toLower);
    auto own = operation.get("servers");
    if (!truthy(own))
        own = item.get("servers");
    const ownPath = serverPath(own);
    string top = serverPath(spec.spec.get("servers"));
    if (top is null)
        top = "";
    if (ownPath is null || ownPath == top)
        return false;
    if (ownPath == "")
        return true;
    throw new SpecModelException("unsupported server path '" ~ ownPath ~ "' for " ~ op.operationId
        ~ " (top-level '" ~ top ~ "')", "#/paths/" ~ pointerEscape(op.path));
}

/// The parsed `x-cli` operation extension (nano-ide#617): explicit command
/// naming and visibility for runtime extensions. All fields optional.
struct CliExt
{
    /// Explicit command path (non-empty array of kebab-case words, as
    /// authored — nano-ide ADR 0068); overrides operationId splitting.
    string[] command;
    /// Extra command paths reaching the same operation.
    string[][] aliases;
    /// `audience: operator` hides the command unless `--operator`.
    string audience;
    /// `exclude: true` removes the command entirely.
    bool exclude;
    /// Positional argument names, overriding path-parameter order.
    string[] positional;
    /// True when the operation carried an `x-cli` key at all.
    bool present;
}

/// Read and validate `x-cli`; `where` qualifies errors with a JSON pointer.
/// Unknown keys, a non-kebab or empty `command`, and non-string `positional`
/// entries are SpecModelException (untrusted input must fail closed).
CliExt parseCliExt(J vendorExtensions, string where)
{
    CliExt c;
    auto x = vendorExtensions.get("x-cli");
    if (x is null)
        return c;
    if (!x.isObj)
        throw new SpecModelException("x-cli must be an object", where ~ "/x-cli");
    c.present = true;
    foreach (k; keysOf(x))
    {
        switch (k)
        {
        case "command":
            c.command = parseWordPath(x.fields[k], where ~ "/x-cli/command", "x-cli.command");
            break;
        case "aliases":
            if (!x.fields[k].isArr)
                throw new SpecModelException("x-cli.aliases must be an array of word arrays",
                    where ~ "/x-cli/aliases");
            foreach (i, a; itemsOf(x.fields[k]))
                c.aliases ~= parseWordPath(a, where ~ "/x-cli/aliases/" ~ i.to!string, "x-cli.aliases entry");
            break;
        case "audience":
            c.audience = x.fields[k].isStr ? x.fields[k].text : null;
            if (c.audience is null)
                throw new SpecModelException("x-cli.audience must be a string", where ~ "/x-cli/audience");
            // Only `operator` is defined; anything else (a typo such as
            // `operater`) would otherwise silently publish the operation.
            if (c.audience != "operator")
                throw new SpecModelException("unsupported x-cli.audience '" ~ c.audience
                    ~ "' (only 'operator' is defined)", where ~ "/x-cli/audience");
            break;
        case "exclude":
            if (x.fields[k].kind == Kind.bool_)
                c.exclude = x.fields[k].boolean;
            else
                throw new SpecModelException("x-cli.exclude must be a boolean", where ~ "/x-cli/exclude");
            break;
        case "positional":
            if (!x.fields[k].isArr)
                throw new SpecModelException("x-cli.positional must be an array of names",
                    where ~ "/x-cli/positional");
            foreach (i, p; itemsOf(x.fields[k]))
            {
                if (!p.isStr || !p.text.length)
                    throw new SpecModelException("x-cli.positional entries must be non-empty names",
                        where ~ "/x-cli/positional/" ~ i.to!string);
                c.positional ~= p.text;
            }
            break;
        default:
            throw new SpecModelException("unknown x-cli key '" ~ k ~ "'", where ~ "/x-cli/" ~ pointerEscape(k));
        }
    }
    if (c.aliases.length && !c.command.length)
        throw new SpecModelException("x-cli.aliases requires x-cli.command", where ~ "/x-cli/aliases");
    return c;
}

/// A non-empty JSON array of kebab-case words. A string (the pre-ADR-0068
/// `"resource verb"` shape) is rejected with a pointer to the array form.
private string[] parseWordPath(J v, string where, string what)
{
    if (v.isStr)
        throw new SpecModelException(what ~ " must be an array of kebab-case words (e.g. [\"start\", \"feature\"]), not the string '"
            ~ v.text ~ "'", where);
    if (!v.isArr)
        throw new SpecModelException(what ~ " must be a non-empty array of kebab-case words", where);
    string[] words;
    foreach (i, w; itemsOf(v))
    {
        if (!w.isStr || !w.text.length || w.text != kebab(w.text) || w.text != w.text.toLower)
            throw new SpecModelException(what ~ " words must be non-empty kebab-case strings",
                where ~ "/" ~ i.to!string);
        words ~= w.text;
    }
    if (!words.length)
        throw new SpecModelException(what ~ " must be a non-empty array of kebab-case words", where);
    return words;
}

private OpInfo fromMeta(J op, size_t i)
{
    OpInfo o;
    auto oid = op.get("operationId");
    if (oid is null || !oid.isStr || !oid.text.length)
        throw new OpenApiException("metadata operation has no operationId", "#/operations/" ~ i.to!string);
    o.operationId = oid.text;
    o.method = op.get("method").orS("get");
    o.path = op.get("path").orS("/");
    o.summary = op.get("summary").orS(o.operationId);
    foreach (p; itemsOf(op.get("pathParams")))
        o.pathParams ~= pyStr(p);
    foreach (q; itemsOf(op.get("queryParams")))
    {
        if (!q.isObj || !truthy(q.get("name")))
            continue;
        if (truthy(q.get("required")))
            o.requiredQuery ~= pyStr(q.get("name"));
        else
            o.optionalQuery ~= pyStr(q.get("name"));
    }
    auto st = op.get("successStatus");
    o.successStatus = truthy(st) ? pyStr(st).to!double.to!long : 200;
    o.responseRef = pyStrOrNull(op.get("successResponseSchemaRef"));
    o.hasResponseSchema = o.responseRef.length > 0;
    foreach (c; itemsOf(op.get("requestBodyContentTypes")))
        o.requestBodyContentTypes ~= pyStr(c);
    o.hasRequestBody = truthy(op.get("hasRequestBody"));
    o.bodyRef = pyStrOrNull(op.get("requestBodySchemaRef"));
    o.vendorExtensions = op.get("vendorExtensions");
    return o;
}

/// `{verb}{Path}` operationId for operations that have none, e.g. `get /users/{id}` → `getUsersId`.
private string syntheticOperationId(string method, string path)
{
    import std.uni : asCapitalized;

    auto b = appender!string;
    b.put(method.toLower);
    foreach (seg; kebab(path).splitHyphen)
        b.put(seg.asCapitalized.to!string);
    return b[];
}

private string[] splitHyphen(string s)
{
    import std.array : split;

    return s.length ? s.split("-") : null;
}

/// Resolve `#/components/<kind>/X` `$ref`s on a non-schema object (bounded).
private J resolveComponent(Spec spec, J node, string kind, string where)
{
    const prefix = "#/components/" ~ kind ~ "/";
    foreach (_; 0 .. spec.limits.maxRefChain + 1)
    {
        if (node is null || !node.has("$ref"))
            return node;
        if (_ == spec.limits.maxRefChain)
            break;
        const r = fragmentDecode(node.get("$ref").orS(""));
        if (!r.startsWith(prefix))
            throw new OpenApiException("unsupported $ref: " ~ r, where);
        node = spec.spec.get("components").get(kind).get(pointerUnescape(r[prefix.length .. $]));
        if (node is null)
            throw new OpenApiException("unresolvable $ref: " ~ r, where);
    }
    throw new OpenApiLimitException("$ref chain too long", where);
}

private J jsonContent(J content)
{
    foreach (k; keysOf(content))
        if (k.indexOf("json") >= 0)
            return content.fields[k];
    return null;
}

private OpInfo fromPaths(Spec spec, J op)
{
    OpInfo o;
    o.method = op.get("method").orS("get");
    o.path = op.get("path").orS("/");
    const where = "#/paths/" ~ pointerEscape(o.path) ~ "/" ~ o.method;
    auto oid = op.get("operationId");
    o.operationId = oid !is null && oid.isStr && oid.text.length ? oid.text : syntheticOperationId(o.method, o.path);
    o.summary = op.get("summary").orS(o.operationId);
    foreach (i, p; itemsOf(op.get("parameters")))
    {
        auto r = resolveComponent(spec, p, "parameters", where ~ "/parameters/" ~ i.to!string);
        const name = r.get("name").orS("");
        if (!name.length)
            continue;
        switch (r.get("in").orS(""))
        {
        case "path":
            o.pathParams ~= name;
            break;
        case "query":
            if (truthy(r.get("required")))
                o.requiredQuery ~= name;
            else
                o.optionalQuery ~= name;
            break;
        default:
            break;
        }
    }
    auto raw = spec.spec.get("paths").get(o.path).get(o.method);
    auto responses = raw.get("responses");
    // Consider every 2xx: the first sets the status, but a later one with a
    // JSON body wins so member order never turns a payload into `void`.
    bool found;
    int bestRank;
    foreach (code; keysOf(responses))
    {
        if (!(code.length == 3 && code[0] == '2'))
            continue;
        import std.conv : ConvException;

        long status;
        // OpenAPI range key `2XX`: rank it as a generic body-bearing 200.
        if (code[1 .. $] == "XX" || code[1 .. $] == "xx")
            status = 200;
        else
        {
            try
                status = code.to!long;
            catch (ConvException)
                continue;
        }
        auto resp = resolveComponent(spec, responses.fields[code], "responses", where ~ "/responses/" ~ code);
        auto media = jsonContent(resp.get("content"));
        auto respSchema = media is null ? null : media.get("schema");
        const hasSchema = truthy(respSchema);
        // Rank: JSON schema > any body > no content.
        const rank = hasSchema ? 2 : (keysOf(resp.get("content")).length ? 1 : 0);
        if (!found || rank > bestRank)
        {
            o.successStatus = status;
            o.hasResponseSchema = hasSchema;
            bestRank = rank;
            o.responseRef = null;
            o.responseSchema = null;
            if (hasSchema)
            {
                // A `$ref` with siblings (OpenAPI 3.1) keeps the whole schema.
                if (respSchema.isObj && keysOf(respSchema).length == 1)
                    o.responseRef = spec.refName(respSchema);
                if (!o.responseRef.length)
                    o.responseSchema = respSchema;
            }
        }
        found = true;
        if (hasSchema)
            break;
    }
    if (!found)
        o.successStatus = 200;
    if (op.has("requestBody"))
    {
        auto body = resolveComponent(spec, op.get("requestBody"), "requestBodies", where ~ "/requestBody");
        o.hasRequestBody = true;
        auto content = body.get("content");
        o.requestBodyContentTypes = keysOf(content).dup;
        if (auto media = jsonContent(content))
        {
            auto schema = media.get("schema");
            // A `$ref` with siblings (OpenAPI 3.1) keeps the whole schema.
            if (schema !is null && schema.isObj && keysOf(schema).length == 1)
                o.bodyRef = spec.refName(schema);
            if (!o.bodyRef.length)
                o.bodySchema = schema;
        }
    }
    o.vendorExtensions = op.get("vendorExtensions");
    return o;
}

/**
Build the command model for `spec`. With metadata, operations come from
`meta.operations`; otherwise from `paths` in document order. Every command
gets namespace `ns`. `x-cli` extensions (nano-ide#617) override naming and
visibility: `command` names the command, `audience: operator` and `x-mcp`
exclusion (without `x-cli`) mark it operator-only, `exclude: true` drops it.
*/
Catalog buildCatalog(Spec spec, string ns = "cluster")
{
    Catalog cat;
    cat.specHash = spec.meta.get("specHash").orS("");
    const fromMetadata = spec.meta.has("operations");
    bool[string] seen;
    string[][] explicitPaths;
    foreach (i, raw; spec.operations)
    {
        auto op = fromMetadata ? fromMeta(raw, i) : fromPaths(spec, raw);
        const where = "#/paths/" ~ pointerEscape(op.path) ~ "/" ~ op.method.toLower;
        auto cli = parseCliExt(op.vendorExtensions, where);
        if (cli.exclude)
            continue; // x-cli.exclude: the command does not exist at all.
        // The transport sends only these verbs (HEAD and bodiless
        // OPTIONS/TRACE always fail), so never advertise anything else.
        import std.algorithm : canFind;

        if (!["GET", "POST", "PUT", "PATCH", "DELETE"].canFind(op.method.toUpper))
            continue;
        string resource;
        string verb;
        string[][] paths;
        if (cli.command.length)
        {
            // A command path: w1..w(n-1) are groups, wn the leaf (ADR 0068).
            paths = [cli.command] ~ cli.aliases;
            foreach (pi, p; paths)
                checkPathConflicts(explicitPaths, p, op.operationId,
                    where ~ (pi == 0 ? "/x-cli/command" : "/x-cli/aliases/" ~ (pi - 1).to!string));
            resource = cli.command[0 .. $ - 1].join(" ");
            verb = cli.command[$ - 1];
        }
        else
        {
            auto vr = splitOp(op.operationId);
            verb = vr[0];
            resource = kebab(vr[1]);
            if (!resource.length)
                resource = kebab(verb);
        }
        // Lookup matches verbs case-insensitively, so collision keys must too.
        const vkey = verb.toLower;
        if (paths.length)
        {
            // Explicit paths have their own (prefix-aware) collision check;
            // also refuse to shadow an earlier operationId-derived command.
            if ((ns ~ "\0" ~ resource ~ "\0" ~ vkey) in seen)
                throw new SpecModelException("duplicate command '" ~ resource ~ " " ~ verb ~ "' for "
                    ~ op.operationId, "#/paths/" ~ pointerEscape(op.path));
            seen[ns ~ "\0" ~ resource ~ "\0" ~ vkey] = true;
            goto build;
        }
        if ((ns ~ "\0" ~ resource ~ "\0" ~ vkey) in seen)
            resource = kebab(op.operationId);
        if ((ns ~ "\0" ~ resource ~ "\0" ~ vkey) in seen)
            throw new SpecModelException("duplicate command '" ~ resource ~ " " ~ verb ~ "' for "
                ~ op.operationId, "#/paths/" ~ pointerEscape(op.path));
        seen[ns ~ "\0" ~ resource ~ "\0" ~ vkey] = true;
    build:
        ModelCommand c;
        c.operationId = op.operationId;
        c.namespace = ns;
        c.resource = resource;
        c.verb = verb;
        c.method = op.method.toUpper;
        c.path = op.path;
        c.summary = op.summary.strip;
        c.addedInVersion = op.vendorExtensions.get("x-added-in-version").orS("");
        c.kind = kindOf(op);
        c.hasBody = op.hasRequestBody;
        c.pathParams = placeholderOrder(op.path, op.pathParams);
        c.requiredQuery = op.requiredQuery;
        c.optionalQuery = op.optionalQuery;
        c.bodyFields = bodyFieldsOf(spec, op);
        c.rootServer = isRootServer(spec, op);
        // Operator gate: explicit x-cli.audience wins; without any x-cli, an
        // x-mcp exclusion defaults to operator-only (nano-workforce#961).
        c.operatorOnly = cli.audience == "operator"
            || (!cli.present && isMcpExcluded(op.vendorExtensions));
        c.positional = cli.positional;
        c.paths = paths;
        responseModel(spec, op, c.responseTarget, c.responseFields);
        validatePositional(c, "#/paths/" ~ pointerEscape(op.path) ~ "/" ~ op.method.toLower);
        cat.commands ~= c;
    }
    checkDerivedAgainstExplicit(cat, explicitPaths);
    return cat;
}

/// `params` ordered by where their `{name}` placeholder appears in `path`
/// (default positional order must follow the URL, not the spec's parameter
/// array). Names without a placeholder keep their relative order, last.
string[] placeholderOrder(string path, const string[] params) pure
{
    import std.algorithm : sort, SwapStrategy;
    import std.typecons : tuple;

    auto keyed = new typeof(tuple(size_t.init, size_t.init, ""))[params.length];
    foreach (i, p; params)
    {
        const at = path.indexOf("{" ~ p ~ "}");
        keyed[i] = tuple(at < 0 ? size_t.max : cast(size_t) at, i, p);
    }
    sort!((a, b) => a[0] < b[0] || (a[0] == b[0] && a[1] < b[1]), SwapStrategy.stable)(keyed);
    string[] o;
    foreach (k; keyed)
        o ~= k[2];
    return o;
}

unittest
{
    assert(placeholderOrder("/parents/{parentId}/children/{childId}", ["childId", "parentId"])
        == ["parentId", "childId"]);
    assert(placeholderOrder("/a/{x}", ["y", "x"]) == ["x", "y"]);
}

/// Explicit paths are matched before operationId-derived commands, so an
/// explicit path or alias equal to, or a prefix of, either accepted order of
/// a derived command (`resource verb` / `verb resource`) would silently steal
/// it — whatever the declaration order. Checked after every op is known.
private void checkDerivedAgainstExplicit(const ref Catalog cat, const string[][] explicitPaths)
{
    import std.algorithm : map;
    import std.array : array;

    string[] low(const string[] w) { return w.map!(x => x.toLower).array; }

    foreach (ref c; cat.commands)
    {
        if (c.paths.length)
            continue;
        foreach (d; [[c.resource, c.verb], [c.verb, c.resource]])
        {
            const dl = low(d);
            foreach (k; explicitPaths)
            {
                const kl = low(k);
                const n = kl.length < dl.length ? kl.length : dl.length;
                if (kl[0 .. n] != dl[0 .. n])
                    continue;
                throw new SpecModelException("x-cli command path '" ~ k.join(" ")
                    ~ "' conflicts with the command '" ~ d.join(" ") ~ "' derived from "
                    ~ c.operationId ~ " (give it an x-cli.command, or pick another path)",
                    "#/paths/" ~ pointerEscape(c.path));
            }
        }
    }
}

/// Register `p`; a duplicate path is ambiguous and fails clearly. A path
/// that is a prefix of another (`guide` and `guide skill`) is allowed, as the
/// x-cli contract allows it (nano-ide#617): the command is also a group, and
/// the parser matches the longest path first.
private void checkPathConflicts(ref string[][] known, string[] p, string opId, string where)
{
    foreach (k; known)
        if (k == p)
            throw new SpecModelException("duplicate x-cli command path '" ~ p.join(" ") ~ "' for " ~ opId, where);
    known ~= p;
}

/// `x-cli.positional` must name each path/query parameter or body field at
/// most once, and (when given) bind every path parameter — an unbound
/// placeholder would otherwise reach the request URL.
private void validatePositional(const ref ModelCommand c, string where)
{
    import std.algorithm : canFind;

    if (!c.positional.length)
        return;
    bool[string] seen;
    foreach (i, p; c.positional)
    {
        const at = where ~ "/x-cli/positional/" ~ i.to!string;
        if (p in seen)
            throw new SpecModelException("duplicate x-cli.positional name '" ~ p ~ "'", at);
        seen[p] = true;
        bool known = c.pathParams.canFind(p) || c.requiredQuery.canFind(p)
            || c.optionalQuery.canFind(p);
        foreach (f; c.bodyFields)
            if (f.name == p)
                known = true;
        if (!known)
            throw new SpecModelException("x-cli.positional name '" ~ p
                ~ "' is not a path/query parameter or body field of " ~ c.operationId, at);
    }
    foreach (p; c.pathParams)
        if (p !in seen)
            throw new SpecModelException("x-cli.positional omits path parameter '" ~ p ~ "' of "
                ~ c.operationId, where ~ "/x-cli/positional");
}

/// True when `x-mcp` excludes the operation (`x-mcp: false` or
/// `x-mcp: {exclude: true}` — nano-workforce's operator-only marker).
bool isMcpExcluded(J vendorExtensions)
{
    auto x = vendorExtensions.get("x-mcp");
    if (x is null)
        return false;
    if (x.kind == Kind.bool_)
        return !x.boolean;
    if (x.isObj)
    {
        auto e = x.get("exclude");
        if (e !is null && e.kind == Kind.bool_)
            return e.boolean;
    }
    return false;
}

/// Parse `specJson` (and optional `metaJson`) and build the command model.
Catalog buildCatalog(string specJson, string metaJson = null, string ns = "cluster")
{
    auto spec = new Spec(parseJson(specJson), metaJson is null ? null : parseJson(metaJson));
    return buildCatalog(spec, ns);
}

private string dString(string v) { return jsonQuote(v, false); }

private string dStringArray(const string[] values)
{
    if (!values.length)
        return "null";
    string[] parts;
    foreach (v; values)
        parts ~= dString(v);
    return "[" ~ parts.join(", ") ~ "]";
}

private string dBodyFields(const ModelField[] fields)
{
    if (!fields.length)
        return "null";
    string[] parts;
    foreach (f; fields)
        parts ~= "BodyField(" ~ dString(f.name) ~ ", " ~ dString(f.kind) ~ ", "
            ~ (f.required ? "true" : "false") ~ ", " ~ dString(f.doc) ~ ")";
    return "[" ~ parts.join(", ") ~ "]";
}

private string dResponseFields(const ModelResponseField[] fields)
{
    if (!fields.length)
        return "null";
    string[] parts;
    foreach (f; fields)
        parts ~= "ResponseField(" ~ dString(f.name) ~ ", " ~ dString(f.kind) ~ ", "
            ~ dStringArray(f.children) ~ ")";
    return "[" ~ parts.join(", ") ~ "]";
}

private string dPaths(const string[][] paths)
{
    if (!paths.length)
        return "null";
    string[] parts;
    foreach (p; paths)
        parts ~= dStringArray(p);
    return "[" ~ parts.join(", ") ~ "]";
}

/// Render `cat` as the D source of `d8ctl.generated.catalog`; `generator` names the script in the header.
string renderCatalogModule(const ref Catalog cat, string generator)
{
    auto rows = appender!string;
    foreach (i, c; cat.commands)
    {
        if (i)
            rows.put("\n");
        rows.put("    Command(\n");
        foreach (v; [dString(c.operationId), dString(c.namespace), dString(c.resource), dString(c.verb),
                dString(c.method), dString(c.path), dString(c.summary), dString(c.addedInVersion),
                dString(c.kind), c.hasBody ? "true" : "false", dStringArray(c.pathParams),
                dStringArray(c.requiredQuery), dStringArray(c.optionalQuery), dBodyFields(c.bodyFields),
                c.rootServer ? "true" : "false", c.operatorOnly ? "true" : "false",
                dStringArray(c.positional), dPaths(c.paths),
                dString(c.responseTarget), dResponseFields(c.responseFields)])
            rows.put("        " ~ v ~ ",\n");
        rows.put("    ),");
    }
    return "/// Generated by " ~ generator ~ " — DO NOT EDIT.\n" ~ catalogPreamble
        ~ "/// SHA-256 of the bundled spec this catalog was generated from.\n"
        ~ "enum catalogSpecHash = " ~ dString(cat.specHash) ~ ";\n\n"
        ~ "/// Number of operations in the catalog.\n"
        ~ "enum catalogOperationCount = " ~ cat.commands.length.to!string ~ ";\n\n"
        ~ "immutable Command[] catalog = [\n" ~ rows[] ~ "\n];\n";
}

private enum catalogPreamble = `///
/// One row per Orchestration Cluster REST operation, derived from the D SDK's
/// bundled spec-metadata.json + rest-api.bundle.json. The argv parser and the
/// HTTP dispatcher both walk this table; there is no hand-written per-operation
/// handler.
module d8ctl.generated.catalog;

@safe:

/// A top-level JSON body property, exposed as ` ~ "`--name=value`" ~ `.
/// ` ~ "`kind` is `string`, `integer`, `number`, `boolean`, or `json`" ~ ` (pass a JSON
/// value — object, array, or anything the flag cannot type).
struct BodyField
{
    string name;
    string kind;
    bool required;
    string doc;
}

/// A selectable response field (` ~ "`--fields`" ~ `, d8ctl#21): a top-level name of the
/// command's selection target. ` ~ "`children`" ~ ` are its own object property names
/// (dotted ` ~ "`a.b`" ~ ` paths); on a ` ~ "`multi`" ~ ` target they are the array's item fields.
struct ResponseField
{
    string name;
    /// ` ~ "`string`, `integer`, `number`, `boolean`, `array`, `object`, or `json`" ~ `.
    string kind;
    string[] children;
}

/// A generated CLI command. ` ~ "`namespace`" ~ ` is always ` ~ "`cluster`" ~ ` (the OC
/// surface). ` ~ "`resource` / `verb`" ~ ` are split from the operationId so the
/// parser can accept either order.
struct Command
{
    string operationId;
    string namespace;
    string resource;
    string verb;
    string method;
    string path;
    string summary;
    string addedInVersion;
    /// ` ~ "`json`, `void`, `text`, or `multipart`" ~ `.
    string kind;
    bool hasBody;
    string[] pathParams;
    string[] requiredQuery;
    string[] optionalQuery;
    BodyField[] bodyFields;
    /// Resolved against the bare root (` ~ "`{schema}://{host}:{port}`" ~ `), not ` ~ "`/v2`" ~ `.
    bool rootServer;
    /// Hidden unless ` ~ "`--operator`" ~ ` (runtime extensions, d8ctl#9).
    bool operatorOnly;
    /// Positional argument names from ` ~ "`x-cli.positional`" ~ `; empty = path order.
    string[] positional;
    /// Explicit command paths from ` ~ "`x-cli.command`/`aliases`" ~ `; empty = resource/verb.
    string[][] paths;
    /// Where ` ~ "`--fields`" ~ ` selection applies (d8ctl#21): ` ~ "`array`, `items`, `object`" ~ `
    /// or ` ~ "`multi`" ~ `; empty = no selectable JSON response (usage error).
    string responseTarget;
    /// Selection-target fields, in declaration order.
    ResponseField[] responseFields;
}

`;

unittest
{
    assert(splitOp("searchProcessInstances") == ["search", "ProcessInstances"]);
    assert(splitOp("getTopology") == ["get", "Topology"]);
    assert(splitOp("unassignUser") == ["unassign", "User"]);
    assert(splitOp("pinClock") == ["pin", "Clock"]);
    assert(splitOp("frobnicateThing") == ["frobnicate", "Thing"]);
    assert(splitOp("get") == ["get", "get"]);
    assert(kebab("ProcessInstances") == "process-instances");
    assert(kebab("--a_b--") == "a-b");
    assert(firstSentence("Hello <b>world</b>.  More text.") == "Hello world.");
    assert(firstSentence("") == "");
}

/// A small non-Camunda spec, no metadata: the model still builds.
unittest
{
    enum petstore = `{
      "openapi": "3.0.3",
      "info": {"title": "Pets", "version": "1"},
      "servers": [{"url": "https://pets.example/api"}],
      "paths": {
        "/pets": {
          "get": {
            "operationId": "listPets",
            "summary": " List pets ",
            "parameters": [
              {"name": "limit", "in": "query"},
              {"$ref": "#/components/parameters/Owner"}
            ],
            "responses": {"200": {"description": "ok",
              "content": {"application/json": {"schema": {"type": "array"}}}}}
          },
          "post": {
            "operationId": "createPet",
            "x-added-in-version": "1.2",
            "requestBody": {"content": {"application/json": {"schema": {"$ref": "#/components/schemas/NewPet"}}}},
            "responses": {"201": {"description": "created",
              "content": {"application/json": {"schema": {"$ref": "#/components/schemas/Pet"}}}}}
          }
        },
        "/pets/{petId}": {
          "parameters": [{"name": "petId", "in": "path", "required": true}],
          "delete": {"operationId": "deletePet", "responses": {"204": {"description": "gone"}}},
          "put": {
            "operationId": "updatePet",
            "requestBody": {"content": {"application/json": {"schema": {
              "type": "object", "required": ["name"],
              "properties": {"name": {"type": "string", "description": "New name. Ignored rest."},
                             "help": {"type": "string"}}}}}},
            "responses": {"200": {"description": "ok"}}
          }
        },
        "/health": {"get": {"responses": {"200": {"description": "ok"}}}}
      },
      "components": {
        "parameters": {"Owner": {"name": "owner", "in": "query", "required": true}},
        "schemas": {
          "Pet": {"allOf": [{"$ref": "#/components/schemas/NewPet"},
                            {"type": "object", "properties": {"id": {"type": "integer"}}}]},
          "NewPet": {"type": "object", "required": ["name"],
            "properties": {"name": {"type": "string"},
                           "tag": {"$ref": "#/components/schemas/Tag"},
                           "meta": {"type": "object"}}},
          "Tag": {"type": "string", "enum": ["a", "b"]}
        }
      }
    }`;
    auto cat = buildCatalog(petstore, null, "pets");
    assert(cat.specHash == "");
    assert(cat.commands.length == 5);

    auto list = cat.commands[0];
    assert(list.operationId == "listPets" && list.namespace == "pets");
    assert(list.resource == "pets" && list.verb == "list" && list.method == "GET");
    assert(list.summary == "List pets" && list.kind == "json" && !list.hasBody);
    assert(list.requiredQuery == ["owner"] && list.optionalQuery == ["limit"]);
    assert(!list.rootServer);

    auto create = cat.commands[1];
    assert(create.verb == "create" && create.resource == "pet" && create.addedInVersion == "1.2");
    assert(create.hasBody && create.kind == "json");
    assert(create.bodyFields == [
        ModelField("name", "string", true, ""),
        ModelField("tag", "string", false, ""),
        ModelField("meta", "json", false, ""),
    ]);

    auto del = cat.commands[2];
    assert(del.verb == "delete" && del.kind == "void" && del.pathParams == ["petId"]);

    auto update = cat.commands[3];
    assert(update.kind == "text");
    assert(update.bodyFields == [ModelField("name", "string", true, "New name.")]);

    assert(cat.commands[4].operationId == "getHealth");
    assert(cat.commands[4].verb == "get" && cat.commands[4].resource == "health");

    const src = renderCatalogModule(cat, "test");
    assert(src.startsWith("/// Generated by test — DO NOT EDIT.\n"));
    assert(src.indexOf("enum catalogOperationCount = 5;") >= 0);
}

/// Errors are exceptions, not exits.
unittest
{
    import std.exception : assertThrown;

    assertThrown!OpenApiException(buildCatalog(`{"paths": `));
    assertThrown!SpecModelException(buildCatalog(`{"servers": [{"url": "http://h/v2"}],
        "paths": {"/x": {"servers": [{"url": "http://h/other"}],
        "get": {"operationId": "getX", "responses": {}}}}}`));
}

/// x-cli: explicit naming, operator audience, exclude, positional.
unittest
{
    import std.exception : assertThrown;

    enum spec = `{
      "paths": {
        "/status": {"get": {"operationId": "listActivePrs",
          "x-cli": {"command": ["status", "show"]},
          "responses": {"200": {"description": "ok"}}}},
        "/dispatch": {"post": {"operationId": "dispatchDeliveryGraph",
          "x-mcp": {"exclude": true},
          "responses": {"200": {"description": "ok"}}}},
        "/cancel": {"post": {"operationId": "cancelPrRun",
          "x-cli": {"command": ["pr", "cancel"], "audience": "operator"},
          "x-mcp": {"exclude": true},
          "responses": {"200": {"description": "ok"}}}},
        "/internal": {"post": {"operationId": "agentCompleteEscalation",
          "x-cli": {"exclude": true},
          "responses": {"200": {"description": "ok"}}}},
        "/library/{id}": {"get": {"operationId": "getLibraryEntry",
          "x-cli": {"positional": ["id"]},
          "parameters": [{"name": "id", "in": "path", "required": true}],
          "responses": {"200": {"description": "ok"}}}}
      }
    }`;
    auto cat = buildCatalog(spec, null, "nwf");
    assert(cat.commands.length == 4); // agentCompleteEscalation excluded

    auto status = cat.commands[0];
    assert(status.resource == "status" && status.verb == "show");
    assert(status.paths == [["status", "show"]]);
    assert(!status.operatorOnly);

    auto dispatch = cat.commands[1];
    assert(dispatch.resource == "delivery-graph" && dispatch.verb == "dispatch");
    assert(dispatch.operatorOnly); // x-mcp exclude, no x-cli

    auto cancel = cat.commands[2];
    assert(cancel.resource == "pr" && cancel.verb == "cancel");
    assert(cancel.operatorOnly); // explicit audience wins (x-cli present)

    auto entry = cat.commands[3];
    assert(entry.positional == ["id"] && !entry.operatorOnly);

    // Validation: unknown keys, non-kebab/empty command, bad positional.
    assertThrown!SpecModelException(buildCatalog(`{"paths": {"/x": {"get":
        {"operationId": "getX", "x-cli": {"nope": 1}, "responses": {}}}}}`));
    assertThrown!SpecModelException(buildCatalog(`{"paths": {"/x": {"get":
        {"operationId": "getX", "x-cli": {"command": ["Not Kebab"]}, "responses": {}}}}}`));
    assertThrown!SpecModelException(buildCatalog(`{"paths": {"/x": {"get":
        {"operationId": "getX", "x-cli": {"command": []}, "responses": {}}}}}`));
    assertThrown!SpecModelException(buildCatalog(`{"paths": {"/x": {"get":
        {"operationId": "getX", "x-cli": {"command": ""}, "responses": {}}}}}`));
    assertThrown!SpecModelException(buildCatalog(`{"paths": {"/x": {"get":
        {"operationId": "getX", "x-cli": {"positional": "id"}, "responses": {}}}}}`));
    assertThrown!SpecModelException(buildCatalog(`{"paths": {"/x": {"get":
        {"operationId": "getX", "x-cli": {"exclude": "yes"}, "responses": {}}}}}`));
    // The pre-ADR-0068 string form is rejected with a clear message.
    try
    {
        buildCatalog(`{"paths": {"/x": {"get": {"operationId": "getX",
            "x-cli": {"command": "status show"}, "responses": {}}}}}`);
        assert(0);
    }
    catch (SpecModelException e)
        assert(e.msg.indexOf("array of kebab-case words") >= 0, e.msg);
    assertThrown!SpecModelException(buildCatalog(`{"paths": {"/x": {"get":
        {"operationId": "getX", "x-cli": {"command": ["ok", 1]}, "responses": {}}}}}`));
    // Aliases: word arrays, need a command, and share the path namespace.
    assertThrown!SpecModelException(buildCatalog(`{"paths": {"/x": {"get":
        {"operationId": "getX", "x-cli": {"aliases": [["a", "b"]]}, "responses": {}}}}}`));
    assertThrown!SpecModelException(buildCatalog(`{"paths": {"/x": {"get":
        {"operationId": "getX", "x-cli": {"command": ["a", "b"], "aliases": ["a b"]}, "responses": {}}}}}`));
    // Duplicate paths are ambiguous; a path that prefixes another is a
    // command that is also a group (nwf: `guide`, `guide skill`).
    assertThrown!SpecModelException(buildCatalog(`{"paths": {
        "/x": {"get": {"operationId": "getX", "x-cli": {"command": ["a", "b"]}, "responses": {}}},
        "/y": {"get": {"operationId": "getY", "x-cli": {"command": ["a", "b"]}, "responses": {}}}}}`));
    assertThrown!SpecModelException(buildCatalog(`{"paths": {
        "/x": {"get": {"operationId": "getX", "x-cli": {"command": ["a", "b"]}, "responses": {}}},
        "/y": {"get": {"operationId": "getY", "x-cli": {"command": ["z"], "aliases": [["a", "b"]]},
          "responses": {}}}}}`));
    assert(buildCatalog(`{"paths": {
        "/x": {"get": {"operationId": "getX", "x-cli": {"command": ["a"]}, "responses": {}}},
        "/y": {"get": {"operationId": "getY", "x-cli": {"command": ["a", "b"]}, "responses": {}}}}}`)
        .commands.length == 2);
    assert(buildCatalog(`{"paths": {
        "/x": {"get": {"operationId": "getX", "x-cli": {"command": ["a", "b", "c"]}, "responses": {}}},
        "/y": {"get": {"operationId": "getY", "x-cli": {"command": ["z"], "aliases": [["a", "b"]]},
          "responses": {}}}}}`).commands.length == 2);
    // An explicit path may not shadow an earlier derived command.
    assertThrown!SpecModelException(buildCatalog(`{"paths": {
        "/x": {"get": {"operationId": "getStatus", "responses": {}}},
        "/y": {"get": {"operationId": "getY", "x-cli": {"command": ["status", "get"]}, "responses": {}}}}}`));
    // 3+ word paths and aliases are kept as authored.
    auto deep = buildCatalog(`{"paths": {"/x": {"get": {"operationId": "getX",
        "x-cli": {"command": ["pr", "run", "cancel"], "aliases": [["cancel", "run"]]},
        "responses": {}}}}}`, null, "nwf");
    assert(deep.commands[0].paths == [["pr", "run", "cancel"], ["cancel", "run"]]);
    assert(deep.commands[0].resource == "pr run" && deep.commands[0].verb == "cancel");
    // Unsupported audience fails closed (a typo must not publish the op).
    assertThrown!SpecModelException(buildCatalog(`{"paths": {"/x": {"get":
        {"operationId": "getX", "x-cli": {"audience": "operater"}, "x-mcp": {"exclude": true},
        "responses": {}}}}}`));
    // Positional: unknown name, duplicate name, unbound path parameter.
    assertThrown!SpecModelException(buildCatalog(`{"paths": {"/x": {"get":
        {"operationId": "getX", "x-cli": {"positional": ["nope"]}, "responses": {}}}}}`));
    assertThrown!SpecModelException(buildCatalog(`{"paths": {"/x/{a}": {"get":
        {"operationId": "getX", "x-cli": {"positional": ["a", "a"]},
        "parameters": [{"name": "a", "in": "path", "required": true}], "responses": {}}}}}`));
    assertThrown!SpecModelException(buildCatalog(`{"paths": {"/x/{a}/{b}": {"get":
        {"operationId": "getX", "x-cli": {"positional": ["a"]},
        "parameters": [{"name": "a", "in": "path", "required": true},
          {"name": "b", "in": "path", "required": true}], "responses": {}}}}}`));
    // Positional may name a query parameter.
    auto q = buildCatalog(`{"paths": {"/x": {"get": {"operationId": "getX",
        "x-cli": {"positional": ["q"]},
        "parameters": [{"name": "q", "in": "query"}], "responses": {}}}}}`, null, "nwf");
    assert(q.commands[0].positional == ["q"]);

    // An explicit path/alias may not equal or prefix a derived command
    // (either order), whatever the declaration order.
    foreach (alias_; [`["status", "get"]`, `["get", "status"]`, `["status"]`, `["get"]`])
    {
        const post = `"/s2": {"post": {"operationId": "poke", "x-cli": {"command": ["poke"],
            "aliases": [` ~ alias_ ~ `]}, "responses": {}}}`;
        const get_ = `"/s": {"get": {"operationId": "getStatus", "responses": {}}}`;
        assertThrown!SpecModelException(buildCatalog(`{"paths": {` ~ get_ ~ `, ` ~ post ~ `}}`, null, "t"), alias_);
        assertThrown!SpecModelException(buildCatalog(`{"paths": {` ~ post ~ `, ` ~ get_ ~ `}}`, null, "t"), alias_);
    }
    // A sibling path that shares only a first word is fine.
    buildCatalog(`{"paths": {"/s": {"get": {"operationId": "getStatus", "responses": {}}},
        "/s2": {"post": {"operationId": "poke", "x-cli": {"command": ["status", "poke"]}, "responses": {}}}}}`, null, "t");

    // x-mcp: false also excludes (the MCP surface's off switch).
    auto mcpOff = buildCatalog(`{"paths": {"/x": {"get":
        {"operationId": "getX", "x-mcp": false, "responses": {}}}}}`, null, "nwf");
    assert(mcpOff.commands[0].operatorOnly);
}

/// Review regressions: response order, type unions, required merge, nested allOf, ref limit, collisions.
unittest
{
    import std.exception : assertThrown;

    enum spec = `{
      "paths": {
        "/a": {"get": {"operationId": "getA", "responses": {
          "204": {"description": "none"},
          "200": {"description": "ok", "content": {"application/json": {"schema": {"type": "object"}}}}}}},
        "/b": {"get": {"operationId": "getB", "responses": {
          "200": {"description": "ok", "content": {"application/json": {"schema": {"type": "object"}}}},
          "204": {"description": "none"}}}},
        "/c": {"post": {"operationId": "createC",
          "requestBody": {"$ref": "#/components/requestBodies/C"},
          "responses": {"204": {"description": "none"}}}}
      },
      "components": {
        "requestBodies": {"C": {"content": {"application/json": {"schema": {"allOf": [
          {"$ref": "#/components/schemas/RequiredName"},
          {"properties": {"name": {"type": "string"}, "u": {"type": ["string", "null"]}}},
          {"allOf": [{"properties": {"deep": {"type": "integer"}}, "required": ["deep"]}]}
        ]}}}}},
        "schemas": {"RequiredName": {"required": ["name"]}}
      }
    }`;
    auto spec_ = new Spec(parseJson(spec), null);
    spec_.limits.maxRefChain = 1;
    auto cat = buildCatalog(spec_);
    assert(cat.commands[0].kind == "json");
    assert(cat.commands[1].kind == "json");
    assert(cat.commands[2].bodyFields == [
        ModelField("name", "string", true, ""),
        ModelField("u", "json", false, ""),
        ModelField("deep", "integer", true, ""),
    ]);

    assertThrown!SpecModelException(buildCatalog(`{"paths": {
        "/foo-bar": {"get": {"responses": {}}},
        "/foo_bar": {"get": {"responses": {}}},
        "/foo/bar": {"get": {"responses": {}}}}}`));
}

unittest
{
    import std.exception : assertThrown;

    enum spec = `{
      "paths": {
        "/t": {"get": {"operationId": "getT", "responses": {
          "204": {"description": "none"},
          "200": {"description": "ok", "content": {"text/plain": {"schema": {"type": "string"}}}}}}},
        "/r": {"post": {"operationId": "createR",
          "requestBody": {"content": {"application/json": {"schema": {
            "$ref": "#/components/schemas/R", "required": ["a"],
            "properties": {"extra": {"type": "boolean"}}}}}},
          "responses": {"204": {"description": "none"}}}}
      },
      "components": {"schemas": {"R": {"properties": {
        "a": {"type": "string"}, "profile": {"type": "string"}, "header": {"type": "string"},
        "camundaRestAddress": {"type": "string"}}}}}
    }`;
    auto cat = buildCatalog(spec);
    assert(cat.commands[0].kind == "text");
    assert(cat.commands[1].bodyFields == [
        ModelField("a", "string", true, ""),
        ModelField("extra", "boolean", false, ""),
    ]);

    assertThrown!SpecModelException(buildCatalog(`{"paths": {
        "/p": {"get": {"operationId": "ping", "responses": {}}},
        "/q": {"get": {"operationId": "PING", "responses": {}}}}}`));

    // `2XX` range keys are successes; a JSON `2XX` beats an empty 204.
    auto ranged = buildCatalog(`{"paths": {"/x": {"get": {"operationId": "getX", "responses": {
        "204": {"description": "none"},
        "2XX": {"description": "ok", "content": {"application/json": {"schema": {"type": "object"}}}}}}}}}`);
    assert(ranged.commands[0].kind != "void" && ranged.commands[0].kind != "text");
}

unittest
{
    // Relative server URLs: `api` top-level + `/` per-operation is a root server.
    auto cat = buildCatalog(`{"servers": [{"url": "api"}], "paths": {
      "/health": {"get": {"operationId": "getHealth", "servers": [{"url": "/"}],
        "responses": {"200": {"description": "ok"}}}},
      "/x": {"get": {"operationId": "getX", "responses": {"200": {"description": "ok"}}}}}}`,
        null, "t");
    foreach (c; cat.commands)
        assert(c.rootServer == (c.operationId == "getHealth"), c.operationId);

    // Server-variable defaults apply before comparing: `/{version}` (v1) == `/v1`.
    auto vcat = buildCatalog(`{"servers": [{"url": "/{version}", "variables": {"version": {"default": "v1"}}}],
      "paths": {"/x": {"get": {"operationId": "getX", "servers": [{"url": "/v1"}],
        "responses": {"200": {"description": "ok"}}}}}}`, null, "t");
    assert(!vcat.commands[0].rootServer);
}

/// Object unions become flags (nwf's ConvergenceStart: `pr` or `url`).
unittest
{
    auto cat = buildCatalog(`{"paths": {
      "/start": {"post": {"operationId": "startLoop",
        "requestBody": {"required": true, "content": {"application/json": {"schema": {"oneOf": [
          {"type": "object", "required": ["pr", "mode"], "properties": {
            "pr": {"type": "string", "description": "PR reference."},
            "mode": {"type": "string"}, "rounds": {"type": "integer"}}},
          {"type": "object", "required": ["url", "mode"], "properties": {
            "url": {"type": "string"}, "mode": {"type": "string"},
            "rounds": {"type": "string"}}}]}}}},
        "responses": {"200": {"description": "ok"}}}},
      "/shared": {"post": {"operationId": "startShared",
        "requestBody": {"content": {"application/json": {"schema": {"anyOf": [
          {"allOf": [{"$ref": "#/components/schemas/Base"}, {"properties": {"a": {"type": "string"}}}]},
          {"allOf": [{"$ref": "#/components/schemas/Base"}, {"properties": {"b": {"type": "string"}}}]}]}}}},
        "responses": {"200": {"description": "ok"}}}},
      "/mixed": {"post": {"operationId": "startMixed",
        "requestBody": {"content": {"application/json": {"schema": {"oneOf": [
          {"type": "string"}, {"type": "object", "properties": {"x": {"type": "string"}}}]}}}},
        "responses": {"200": {"description": "ok"}}}}},
      "components": {"schemas": {"Base": {"type": "object", "required": ["tenant"],
        "properties": {"tenant": {"type": "string"}}}}}}`);
    assert(cat.commands[0].bodyFields == [
        ModelField("pr", "string", false, "PR reference."),
        ModelField("mode", "string", true, ""),
        ModelField("rounds", "integer", false, ""),
        ModelField("url", "string", false, ""),
    ], "every variant's fields; required only when every variant requires it; first declaration wins");
    // Both variants see the shared base (own `seen` per variant).
    assert(cat.commands[1].bodyFields == [
        ModelField("tenant", "string", true, ""),
        ModelField("a", "string", false, ""),
        ModelField("b", "string", false, ""),
    ]);
    // A non-object variant: --body only.
    assert(cat.commands[2].bodyFields.length == 0);
}

/// Response field selection (#21): target derivation per response shape.
unittest
{
    enum spec = `{
      "paths": {
        "/search": {"post": {"operationId": "searchThings",
          "responses": {"200": {"description": "ok", "content": {"application/json":
            {"schema": {"$ref": "#/components/schemas/SearchResult"}}}}}}},
        "/list": {"get": {"operationId": "listThings",
          "responses": {"200": {"description": "ok", "content": {"application/json":
            {"schema": {"type": "array", "items": {"$ref": "#/components/schemas/Thing"}}}}}}}},
        "/one": {"get": {"operationId": "getThing",
          "responses": {"200": {"description": "ok", "content": {"application/json":
            {"schema": {"$ref": "#/components/schemas/Thing"}}}}}}},
        "/status": {"get": {"operationId": "getStatus",
          "responses": {"200": {"description": "ok", "content": {"application/json":
            {"schema": {"$ref": "#/components/schemas/Status"}}}}}}},
        "/plain": {"get": {"operationId": "getPlain",
          "responses": {"200": {"description": "ok", "content": {"application/json":
            {"schema": {"type": "string"}}}}}}},
        "/empty": {"get": {"operationId": "deleteThing",
          "responses": {"204": {"description": "gone"}}}}
      },
      "components": {"schemas": {
        "SearchResult": {"type": "object", "properties": {
          "items": {"type": "array", "items": {"$ref": "#/components/schemas/Thing"}},
          "page": {"type": "object", "properties": {
            "totalItems": {"type": "integer"}, "limit": {"type": "integer"}}}}},
        "Thing": {"type": "object", "properties": {
          "key": {"type": "string"}, "state": {"type": "string"},
          "spec": {"type": "object", "properties": {"name": {"type": "string"}}}}},
        "Status": {"type": "object", "properties": {
          "prs": {"type": "array", "items": {"type": "object", "properties": {
            "prKey": {"type": "string"}, "status": {"type": "string"}}}},
          "deliveries": {"type": "array", "items": {"type": "object", "properties": {
            "id": {"type": "string"}}}},
          "count": {"type": "integer"}}}
      }}}`;
    auto cat = buildCatalog(spec, null, "t");

    // One array-of-objects property → items target; page's children are not
    // selectable (the items are the target), but the item's object field is.
    auto search = cat.commands[0];
    assert(search.responseTarget == "items");
    assert(search.responseFields.map!(f => f.name).array == ["key", "state", "spec"]);
    assert(search.responseFields[2].children == ["name"]);

    // A bare array → each item is trimmed.
    auto list = cat.commands[1];
    assert(list.responseTarget == "array");
    assert(list.responseFields.map!(f => f.name).array == ["key", "state", "spec"]);

    // A plain object → the object itself is trimmed; nested names ride along.
    auto one = cat.commands[2];
    assert(one.responseTarget == "object");
    assert(one.responseFields.map!(f => f.name).array == ["key", "state", "spec"]);

    // Two arrays of objects → multi: the fields are the array names, the
    // children their item fields (nwf status: prs + deliveries).
    auto status = cat.commands[3];
    assert(status.responseTarget == "multi");
    assert(status.responseFields.map!(f => f.name).array == ["prs", "deliveries"]);
    assert(status.responseFields[0].children == ["prKey", "status"]);
    assert(status.responseFields[1].children == ["id"]);

    // A scalar JSON response and a 204 have no selection target.
    assert(cat.commands[4].responseTarget == "");
    assert(cat.commands[5].responseTarget == "");
}
