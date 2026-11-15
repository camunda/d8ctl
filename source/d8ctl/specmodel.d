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

import std.array : appender, join;
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

/// Top-level properties after unfolding `allOf`; `isUnion` when a oneOf/anyOf blocks flattening.
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
    if (truthy(schema.get("oneOf")) || truthy(schema.get("anyOf")))
    {
        out_.isUnion = true;
        return out_;
    }
    J[] parts = itemsOf(schema.get("allOf")).dup ~ schema;
    foreach (part; parts)
    {
        if (part.has("$ref"))
        {
            const r = spec.refName(part);
            auto nested = r.length ? flattenSchema(spec, r, spec.schemas.get(r), seen, depth + 1) : Flat.init;
            if (nested.isUnion)
                return nested;
            foreach (pn; nested.names)
                out_.put(pn, nested.props[pn]);
            foreach (rn; nested.required.byKey)
                out_.required[rn] = true;
            // OpenAPI 3.1: sibling keywords next to `$ref` still apply.
        }
        if (truthy(part.get("oneOf")) || truthy(part.get("anyOf")))
        {
            out_.isUnion = true;
            return out_;
        }
        if (part !is schema && truthy(part.get("allOf")))
        {
            auto nested = flattenSchema(spec, null, part, seen, depth + 1);
            if (nested.isUnion)
                return nested;
            foreach (pn; nested.names)
                out_.put(pn, nested.props[pn]);
            foreach (rn; nested.required.byKey)
                out_.required[rn] = true;
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

/// Path part of the first server URL (`{schema}://{host}:{port}/v2` → `/v2`); null without servers.
private string serverPath(J servers)
{
    auto list = itemsOf(servers);
    if (!list.length)
        return null;
    string rest = list[0].get("url").orS("");
    const sep = rest.indexOf("://");
    if (sep >= 0)
        rest = rest[sep + 3 .. $];
    const i = rest.indexOf('/');
    if (i < 0)
        return "";
    string p = rest[i .. $];
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
    o.hasResponseSchema = truthy(op.get("successResponseSchemaRef"));
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
        try
            status = code.to!long;
        catch (ConvException)
            continue;
        auto resp = resolveComponent(spec, responses.fields[code], "responses", where ~ "/responses/" ~ code);
        auto media = jsonContent(resp.get("content"));
        const hasSchema = media !is null && truthy(media.get("schema"));
        // Rank: JSON schema > any body > no content.
        const rank = hasSchema ? 2 : (keysOf(resp.get("content")).length ? 1 : 0);
        if (!found || rank > bestRank)
        {
            o.successStatus = status;
            o.hasResponseSchema = hasSchema;
            bestRank = rank;
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
gets namespace `ns`.
*/
Catalog buildCatalog(Spec spec, string ns = "cluster")
{
    Catalog cat;
    cat.specHash = spec.meta.get("specHash").orS("");
    const fromMetadata = spec.meta.has("operations");
    bool[string] seen;
    foreach (i, raw; spec.operations)
    {
        auto op = fromMetadata ? fromMeta(raw, i) : fromPaths(spec, raw);
        auto vr = splitOp(op.operationId);
        const verb = vr[0];
        // Lookup matches verbs case-insensitively, so collision keys must too.
        const vkey = verb.toLower;
        string resource = kebab(vr[1]);
        if (!resource.length)
            resource = kebab(verb);
        if ((ns ~ "\0" ~ resource ~ "\0" ~ vkey) in seen)
            resource = kebab(op.operationId);
        if ((ns ~ "\0" ~ resource ~ "\0" ~ vkey) in seen)
            throw new SpecModelException("duplicate command '" ~ resource ~ " " ~ verb ~ "' for "
                ~ op.operationId, "#/paths/" ~ pointerEscape(op.path));
        seen[ns ~ "\0" ~ resource ~ "\0" ~ vkey] = true;
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
        c.pathParams = op.pathParams;
        c.requiredQuery = op.requiredQuery;
        c.optionalQuery = op.optionalQuery;
        c.bodyFields = bodyFieldsOf(spec, op);
        c.rootServer = isRootServer(spec, op);
        cat.commands ~= c;
    }
    return cat;
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
                c.rootServer ? "true" : "false"])
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
}
