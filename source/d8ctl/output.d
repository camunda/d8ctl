/// The agent output contract (#16): what d8ctl writes and how it exits.
///
/// - stdout: the API response unchanged (no envelope, so the OpenAPI spec is
///   the output schema). Compact JSON unless pretty is asked for or stdout is
///   a terminal.
/// - stderr: an error as one JSON line (`{"error":{…}}`), or as text in a
///   terminal. `--output=json|text` overrides.
/// - exit code: by error kind (see `exitCode`).
module d8ctl.output;

@safe:

import std.json;

/// What went wrong, as the `error.kind` field and the exit code.
enum ErrorKind
{
    other,
    usage,
    config,
    auth,
    notFound,
    conflict,
    client,
    server,
    network,
}

/// The process exit code for an error of `kind`.
int exitCode(ErrorKind kind) pure nothrow
{
    final switch (kind)
    {
    case ErrorKind.other: return 1;
    case ErrorKind.usage, ErrorKind.config: return 2;
    case ErrorKind.auth: return 3;
    case ErrorKind.notFound: return 4;
    case ErrorKind.conflict, ErrorKind.client: return 5;
    case ErrorKind.server: return 6;
    case ErrorKind.network: return 7;
    }
}

/// The `error.kind` spelling.
string kindName(ErrorKind kind) pure nothrow
{
    final switch (kind)
    {
    case ErrorKind.other: return "other";
    case ErrorKind.usage: return "usage";
    case ErrorKind.config: return "config";
    case ErrorKind.auth: return "auth";
    case ErrorKind.notFound: return "not-found";
    case ErrorKind.conflict: return "conflict";
    case ErrorKind.client: return "client";
    case ErrorKind.server: return "server";
    case ErrorKind.network: return "network";
    }
}

/// The kind of an HTTP error status.
ErrorKind kindOfStatus(int status) pure nothrow
{
    if (status == 401 || status == 403) return ErrorKind.auth;
    if (status == 404) return ErrorKind.notFound;
    if (status == 409) return ErrorKind.conflict;
    if (status >= 500) return ErrorKind.server;
    if (status >= 400) return ErrorKind.client;
    return ErrorKind.other;
}

/// One error, ready to print.
struct Failure
{
    ErrorKind kind;
    string message;
    /// HTTP status, or 0 when the request never got a response.
    int status;
    /// The command's operationId, when known.
    string operation;
    /// The response body, when there was one (an RFC 9457 problem, usually).
    string body_;
}

/// How to write errors.
enum ErrorFormat
{
    auto_,
    json,
    text,
}

/// The JSON error line: `{"error":{kind,message[,status][,operation]
/// [,title,detail,type,instance][,body]}}`. Fields of an RFC 9457 problem
/// body are carried over; a body that isn't a JSON object goes in `body`.
string errorJson(const ref Failure f)
{
    JSONValue e = ["kind": kindName(f.kind), "message": f.message];
    if (f.status) e["status"] = f.status;
    if (f.operation.length) e["operation"] = f.operation;
    if (f.body_.length)
    {
        JSONValue problem;
        bool parsed;
        try
        {
            problem = parseJSON(f.body_);
            parsed = problem.type == JSONType.object;
        }
        catch (JSONException) {}
        if (parsed)
        {
            foreach (key; ["title", "detail", "type", "instance"])
                if (auto v = key in problem.objectNoRef)
                    e[key] = *v;
            // The body's fields are carried over, so the message need not
            // repeat it: `HTTP 404: Process instance not found`.
            if (f.status)
                if (auto t = "title" in problem.objectNoRef)
                    if (t.type == JSONType.string)
                    {
                        import std.format : format;
                        e["message"] = format("HTTP %s: %s", f.status, t.str);
                    }
        }
        else
            e["body"] = f.body_;
    }
    JSONValue root = ["error": e];
    return root.toString(JSONOptions.doNotEscapeSlashes);
}

/// The error as d8ctl's text line (`d8ctl: <message>`).
string errorText(const ref Failure f)
{
    return "d8ctl: " ~ f.message;
}

/// A JSON response for stdout: pretty or compact.
string formatJson(const JSONValue v, bool pretty)
{
    return pretty ? v.toPrettyString(JSONOptions.doNotEscapeSlashes) : v.toString(JSONOptions.doNotEscapeSlashes);
}

// ---- Response field selection (`--fields`, #21) ----

import d8ctl.catalog : Command, ResponseField;

/// A `--fields` usage error (classified as exit code 2, like UsageException).
class FieldsException : Exception
{
    this(string msg) { super(msg); }
}

private const(ResponseField)* findResponseField(const(Command)* c, string name)
{
    foreach (i, ref f; c.responseFields)
        if (f.name == name)
            return &c.responseFields[i];
    return null;
}

private bool nameIn(const string[] xs, string x)
{
    import std.algorithm.searching : canFind;

    return xs.canFind(x);
}

/// Usage error (exit 2) with the valid field names, as the issue asks.
private noreturn throwFieldsError(const(Command)* c, string what)
{
    import std.array : join;

    string[] valid;
    foreach (f; c.responseFields)
    {
        valid ~= f.name;
        foreach (ch; f.children)
            valid ~= f.name ~ "." ~ ch;
    }
    throw new FieldsException(what ~ ". Valid --fields for " ~ c.operationId
        ~ ": " ~ valid.join(", "));
}

/// Project `obj` to the selected top-level `fields` (dotted `a.b` paths keep
/// the nesting). Unknown names are a usage error listing the valid ones; a
/// dotted path needs an object child declared in the schema. Fields absent
/// from this particular response are simply not printed.
JSONValue projectObject(const JSONValue obj, const string[] fields, const(Command)* c)
{
    import std.string : indexOf;

    JSONValue out_ = parseJSON("{}");
    foreach (f; fields)
    {
        string head = f;
        string rest;
        const dot = f.indexOf('.');
        if (dot >= 0)
        {
            head = f[0 .. dot];
            rest = f[dot + 1 .. $];
        }
        auto rf = findResponseField(c, head);
        if (rf is null)
            throwFieldsError(c, "unknown field '" ~ head ~ "'");
        auto v = head in obj.objectNoRef;
        if (v is null)
            continue; // absent from this response: nothing to keep
        if (rest.length)
        {
            if (!rf.children.length)
                throwFieldsError(c, "'" ~ head ~ "' has no nested fields ('" ~ f ~ "')");
            if (!nameIn(rf.children, rest))
                throwFieldsError(c, "unknown field '" ~ f ~ "' — '" ~ head
                    ~ "' has no '" ~ rest ~ "'");
            if (v.type == JSONType.object)
            {
                if (auto cv = rest in v.objectNoRef)
                {
                    auto slot = head in out_.objectNoRef;
                    if (slot is null)
                    {
                        JSONValue child = parseJSON("{}");
                        child[rest] = *cv;
                        out_[head] = child;
                    }
                    else
                    {
                        auto merged = *slot;
                        merged[rest] = *cv;
                        out_[head] = merged;
                    }
                }
                continue;
            }
            // The server sent a non-object where the schema declares one:
            // keep the value as-is rather than drop it.
        }
        out_[head] = *v;
    }
    return out_;
}

/// Apply `--fields` to a decoded JSON response per the command's selection
/// target (#21): `array` trims each item; `items` trims the items of the one
/// array-of-objects property (other top-level fields stay); `object` trims
/// the response itself; `multi` requires `name.field` prefixes. Anything
/// else is a usage error.
JSONValue selectFields(const JSONValue payload, const string[] fields, const(Command)* c)
{
    import std.array : join;
    import std.string : indexOf;

    switch (c.responseTarget)
    {
    case "array":
        if (payload.type != JSONType.array)
            return payload; // the server broke the contract; print it as-is
        JSONValue[] items;
        foreach (it; payload.arrayNoRef)
            items ~= it.type == JSONType.object ? projectObject(it, fields, c) : it;
        return JSONValue(items);
    case "items":
        if (payload.type != JSONType.object)
            return payload;
        // The schema guarantees exactly one array-of-objects property; the
        // response's single matching array is the one to trim.
        foreach (k, v; payload.objectNoRef)
            if (v.type == JSONType.array)
            {
                // `items.x` is the same as `x`; a non-item top-level name
                // (`page.totalItems`) is accepted — those fields stay as-is.
                string[] sel;
                foreach (f; fields)
                {
                    const dot = f.indexOf('.');
                    const head = dot >= 0 ? f[0 .. dot] : f;
                    if (head == k && dot >= 0)
                        sel ~= f[dot + 1 .. $];
                    else if (head != k && findResponseField(c, head) is null
                        && (head in payload.objectNoRef) !is null)
                        continue;
                    else
                        sel ~= f;
                }
                JSONValue[] items;
                foreach (it; v.arrayNoRef)
                    items ~= it.type == JSONType.object ? projectObject(it, sel, c) : it;
                JSONValue out_ = payload;
                out_[k] = JSONValue(items);
                return out_;
            }
        return payload;
    case "object":
        if (payload.type != JSONType.object)
            return payload;
        return projectObject(payload, fields, c);
    case "multi":
        // Every selection must be prefixed with one of the array names; a
        // bare name is a usage error that lists the arrays.
        string[] arrays;
        foreach (f; c.responseFields)
            arrays ~= f.name;
        string[][string] byArray;
        foreach (f; fields)
        {
            const dot = f.indexOf('.');
            const head = dot >= 0 ? f[0 .. dot] : f;
            if (dot < 0 || !nameIn(arrays, head))
                throw new FieldsException("--fields on " ~ c.operationId
                    ~ " needs an array prefix (" ~ arrays.join(", ") ~ "), e.g. "
                    ~ arrays[0] ~ "." ~ c.responseFields[0].children[0] ~ " — got '" ~ f ~ "'");
            byArray[head] ~= f[dot + 1 .. $];
        }
        if (payload.type != JSONType.object)
            return payload;
        JSONValue out_ = payload;
        foreach (arr, sel; byArray)
        {
            auto rf = findResponseField(c, arr);
            foreach (s; sel)
            {
                const head = s.indexOf('.') >= 0 ? s[0 .. s.indexOf('.')] : s;
                if (!nameIn(rf.children, head))
                    throwFieldsError(c, "unknown field '" ~ arr ~ "." ~ head ~ "'");
            }
            auto slot = arr in out_.objectNoRef;
            if (slot is null || slot.type != JSONType.array)
                continue;
            JSONValue[] items;
            foreach (it; slot.arrayNoRef)
            {
                if (it.type != JSONType.object)
                {
                    items ~= it;
                    continue;
                }
                JSONValue trimmed = parseJSON("{}");
                foreach (s; sel)
                    if (auto v = s in it.objectNoRef)
                        trimmed[s] = *v;
                items ~= trimmed;
            }
            out_[arr] = JSONValue(items);
        }
        return out_;
    default:
        throw new FieldsException(c.operationId
            ~ " has no selectable JSON response fields; --fields does not apply.");
    }
}

unittest
{
    assert(exitCode(ErrorKind.usage) == 2 && exitCode(ErrorKind.config) == 2);
    assert(exitCode(kindOfStatus(401)) == 3 && exitCode(kindOfStatus(403)) == 3);
    assert(exitCode(kindOfStatus(404)) == 4);
    assert(exitCode(kindOfStatus(409)) == 5 && exitCode(kindOfStatus(400)) == 5);
    assert(exitCode(kindOfStatus(503)) == 6);
    assert(exitCode(ErrorKind.network) == 7 && exitCode(ErrorKind.other) == 1);
}

unittest
{
    auto f = Failure(ErrorKind.notFound, "API error: HTTP 404", 404, "getProcessInstance",
        `{"type":"about:blank","title":"NOT_FOUND","status":404,"detail":"no such instance","instance":"/v2/x","extra":1}`);
    auto j = parseJSON(errorJson(f))["error"];
    assert(j["kind"].str == "not-found");
    assert(j["status"].integer == 404);
    assert(j["operation"].str == "getProcessInstance");
    assert(j["title"].str == "NOT_FOUND" && j["detail"].str == "no such instance");
    assert(j["instance"].str == "/v2/x" && j["type"].str == "about:blank");
    assert(j["message"].str == "HTTP 404: NOT_FOUND");
    assert("extra" !in j.objectNoRef && "body" !in j.objectNoRef);

    auto plain = Failure(ErrorKind.server, "boom", 502, null, "<html>bad gateway</html>");
    auto p = parseJSON(errorJson(plain))["error"];
    assert(p["body"].str == "<html>bad gateway</html>" && "operation" !in p.objectNoRef);

    auto usage = Failure(ErrorKind.usage, "unknown command");
    auto u = errorJson(usage);
    assert(u == `{"error":{"kind":"usage","message":"unknown command"}}`, u);
    assert(errorText(usage) == "d8ctl: unknown command");
}

unittest
{
    auto v = parseJSON(`{"a":[1,2]}`);
    assert(formatJson(v, false) == `{"a":[1,2]}`);
    assert(formatJson(parseJSON(`{"p":"/v2/x"}`), false) == `{"p":"/v2/x"}`, "slashes are not escaped");
    assert(formatJson(v, true) != formatJson(v, false));
}

unittest
{
    import d8ctl.specmodel : buildCatalog;
    import d8ctl.catalog : toCommand;

    auto cat = buildCatalog(`{"paths": {"/s": {"post": {"operationId": "s",
        "responses": {"200": {"description": "ok", "content": {"application/json":
          {"schema": {"type": "object", "properties": {
            "page": {"type": "object", "properties": {"totalItems": {"type": "integer"}}},
            "items": {"type": "array", "items": {"type": "object", "properties": {
              "a": {"type": "string"}, "b": {"type": "string"}}}}}}}}}}}}}}`, null, "x");
    auto c = new Command;
    *c = toCommand(cat.commands[0]);
    assert(c.responseTarget == "items");
    auto r = selectFields(parseJSON(`{"page":{"totalItems":1},"items":[{"a":"1","b":"2"}]}`),
        ["page.totalItems", "items.a"], c);
    assert(r.toString == `{"items":[{"a":"1"}],"page":{"totalItems":1}}`, r.toString);
}

/// `--fields` projection (#21): each selection target, dotted paths, unknown
/// fields as usage errors with the valid names.
unittest
{
    import d8ctl.specmodel : buildCatalog;
    import d8ctl.catalog : toCommand;
    import std.exception : assertThrown;
    import std.string : indexOf;

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
            {"schema": {"$ref": "#/components/schemas/Status"}}}}}}}
      },
      "components": {"schemas": {
        "SearchResult": {"type": "object", "properties": {
          "items": {"type": "array", "items": {"$ref": "#/components/schemas/Thing"}},
          "page": {"type": "object", "properties": {"totalItems": {"type": "integer"}}}}},
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
    auto model = buildCatalog(spec, null, "t");
    auto cmds = new Command[4];
    foreach (i, ref mc; model.commands)
        cmds[i] = toCommand(mc);

    // items target: each item trimmed, other top-level fields kept.
    auto payload = parseJSON(`{"items":[{"key":"k1","state":"A","extra":1},
        {"key":"k2","state":"B","spec":{"name":"n","x":1}}],"page":{"totalItems":2}}`);
    auto got = selectFields(payload, ["key", "spec.name"], &cmds[0]);
    assert(formatJson(got, false) ==
        `{"items":[{"key":"k1"},{"key":"k2","spec":{"name":"n"}}],"page":{"totalItems":2}}`,
        formatJson(got, false));

    // array target.
    auto arr = parseJSON(`[{"key":"k1","state":"A"},{"key":"k2","state":"B"}]`);
    assert(formatJson(selectFields(arr, ["state"], &cmds[1]), false)
        == `[{"state":"A"},{"state":"B"}]`);

    // object target, with a dotted path into a nested object.
    auto one = parseJSON(`{"key":"k","state":"A","spec":{"name":"n","other":2}}`);
    assert(formatJson(selectFields(one, ["spec.name", "state"], &cmds[2]), false)
        == `{"spec":{"name":"n"},"state":"A"}`);

    // Unknown field: usage error listing the valid names.
    string emsg;
    try
        cast(void) selectFields(payload, ["kye"], &cmds[0]);
    catch (FieldsException e)
        emsg = e.msg;
    assert(emsg.indexOf("unknown field 'kye'") >= 0, emsg);
    assert(emsg.indexOf("key") >= 0 && emsg.indexOf("spec.name") >= 0, emsg);
    // A dotted path into a scalar is a usage error too.
    assertThrown!FieldsException(selectFields(one, ["key.name"], &cmds[2]));

    // multi target: bare names are a usage error listing the arrays.
    auto status = parseJSON(`{"prs":[{"prKey":"1","status":"open","x":1}],
        "deliveries":[{"id":"d1","y":2}],"count":3}`);
    string mmsg;
    try
        cast(void) selectFields(status, ["prKey"], &cmds[3]);
    catch (FieldsException e)
        mmsg = e.msg;
    assert(mmsg.indexOf("prs") >= 0 && mmsg.indexOf("deliveries") >= 0, mmsg);
    auto mgot = selectFields(status, ["prs.prKey", "prs.status", "deliveries.id"], &cmds[3]);
    auto mj = parseJSON(formatJson(mgot, false));
    assert(mj["prs"].arrayNoRef[0] == parseJSON(`{"prKey":"1","status":"open"}`));
    assert(mj["deliveries"].arrayNoRef[0] == parseJSON(`{"id":"d1"}`));
    assert(mj["count"].integer == 3); // untouched top-level fields stay
    assertThrown!FieldsException(selectFields(status, ["prs.nope"], &cmds[3]));

    // No selectable response: usage error.
    auto plain = buildCatalog(`{"paths": {"/p": {"get": {"operationId": "getP",
        "responses": {"204": {"description": "none"}}}}}}`, null, "t");
    auto pc = new Command;
    *pc = toCommand(plain.commands[0]);
    assertThrown!FieldsException(selectFields(parseJSON(`{}`), ["a"], pc));
}
