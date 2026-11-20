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

private void collectPaths(const(ResponseField)[] fields, string prefix, ref string[] out_)
{
    foreach (f; fields)
    {
        out_ ~= prefix ~ f.name;
        collectPaths(f.children, prefix ~ f.name ~ ".", out_);
    }
}

/// Usage error (exit 2) with the valid field names, as the issue asks.
private noreturn throwFieldsError(const(Command)* c, string what)
{
    import std.array : join;

    string[] valid;
    collectPaths(c.responseFields, null, valid);
    throw new FieldsException(what ~ ". Valid --fields for " ~ c.operationId
        ~ ": " ~ valid.join(", "));
}

/// Split `path` at the first dot: (`head`, `rest`), rest empty without one.
private string[2] splitPath(string path)
{
    import std.string : indexOf;

    const dot = path.indexOf('.');
    if (dot < 0)
        return [path, null];
    return [path[0 .. dot], path[dot + 1 .. $]];
}

/// Schema-aware head match: the declared field whose name is all of `sel`
/// or a `name.` prefix of it, longest name first, so a declared property
/// whose name itself contains dots (e.g. `camunda.document.type`) is
/// selectable. `rest` receives the remaining dotted suffix (empty if none).
private const(ResponseField)* matchHead(const(ResponseField)[] fields, string sel, out string rest)
{
    import std.algorithm.searching : startsWith;

    const(ResponseField)* best;
    foreach (i, ref f; fields)
    {
        const n = f.name;
        if (best !is null && n.length <= best.name.length)
            continue;
        if (sel == n)
            best = &fields[i];
        else if (sel.length > n.length && sel.startsWith(n) && sel[n.length] == '.')
            best = &fields[i];
    }
    if (best !is null)
        rest = sel.length > best.name.length ? sel[best.name.length + 1 .. $] : null;
    return best;
}

/// Validate one selection against the schema fields: every dotted step must
/// be a declared object/array-of-objects property.
private void validatePath(const(Command)* c, const(ResponseField)[] fields, string sel)
{
    string rest;
    auto f = matchHead(fields, sel, rest);
    if (f is null)
        throwFieldsError(c, "unknown field '" ~ splitPath(sel)[0] ~ "'");
    if (!rest.length)
        return;
    if (!f.children.length)
        throwFieldsError(c, "'" ~ f.name ~ "' has no nested fields ('" ~ sel ~ "')");
    validatePath(c, f.children, rest);
}

/// Validate the complete `--fields` selection against the command's response
/// schema — before any request is sent, so a mistyped selection on a mutating
/// command fails as a usage error instead of creating the resource and then
/// hiding its key. Independent of the (possibly empty) response contents.
void validateFields(const(Command)* c, const string[] fields)
{
    import std.array : join;

    if (!fields.length)
        return;
    switch (c.responseTarget)
    {
    case "array":
    case "object":
        foreach (f; fields)
            validatePath(c, c.responseFields, f);
        return;
    case "items":
        // A bare item-field name selects inside the array's items; every
        // other envelope field (including the array property itself) is
        // addressed by name or dotted path.
        auto arr = findResponseField(c, c.selection);
        foreach (f; fields)
        {
            auto hr = splitPath(f);
            if (hr[0] == c.selection)
            {
                if (!hr[1].length)
                    continue; // `items` alone keeps the whole array
                validatePath(c, arr.children, hr[1]);
            }
            else if (findResponseField(c, hr[0]) !is null)
                validatePath(c, c.responseFields, f);
            else if (isItemField(arr, f))
                validatePath(c, arr.children, f);
            else
                throwFieldsError(c, "unknown field '" ~ hr[0] ~ "'");
        }
        return;
    case "multi":
        // Every selection must be prefixed with one of the array names; a
        // bare name is a usage error that lists the arrays.
        string[] arrays;
        foreach (f; c.responseFields)
            arrays ~= f.name;
        foreach (f; fields)
        {
            auto hr = splitPath(f);
            auto rf = findResponseField(c, hr[0]);
            if (!hr[1].length || rf is null)
                throw new FieldsException("--fields on " ~ c.operationId
                    ~ " needs an array prefix (" ~ arrays.join(", ") ~ "), e.g. "
                    ~ arrays[0] ~ "." ~ c.responseFields[0].children[0].name ~ " — got '" ~ f ~ "'");
            validatePath(c, rf.children, hr[1]);
        }
        return;
    default:
        throw new FieldsException(c.operationId
            ~ " has no selectable JSON response fields; --fields does not apply.");
    }
}

private bool isItemField(const(ResponseField)* arr, string sel)
{
    string rest;
    return arr !is null && matchHead(arr.children, sel, rest) !is null;
}

/// A whole-field selection: keep only schema-declared properties, recursing
/// through objects and arrays of objects. A field with no declared children
/// (scalar, opaque `json`, free-form map) is kept as-is.
private JSONValue filterSchema(const JSONValue v, const(ResponseField)[] fields)
{
    if (!fields.length)
        return v;
    if (v.type == JSONType.array)
    {
        JSONValue[] items;
        foreach (it; v.arrayNoRef)
            items ~= filterSchema(it, fields);
        return JSONValue(items);
    }
    if (v.type != JSONType.object)
        return v;
    JSONValue out_ = parseJSON("{}");
    foreach (ref f; fields)
        if (auto sv = f.name in v.objectNoRef)
            out_[f.name] = filterSchema(*sv, f.children);
    return out_;
}

/// Project `v` to the selected `paths` (dotted `a.b` paths keep the
/// nesting). Selections are grouped per declared property before recursing,
/// so deep siblings (`a.b.x,a.b.y`) all survive; arrays of objects are
/// projected element-wise. Callers validate first (`validateFields`);
/// fields absent from this particular response are simply not printed.
private JSONValue projectObject(const JSONValue v, const string[] paths, const(ResponseField)[] fields)
{
    foreach (p; paths)
        if (!p.length)
            return filterSchema(v, fields); // the whole field was selected
    if (v.type == JSONType.array)
    {
        JSONValue[] items;
        foreach (it; v.arrayNoRef)
            items ~= projectObject(it, paths, fields);
        return JSONValue(items);
    }
    if (v.type != JSONType.object)
        return v; // the server sent a non-object where the schema declares one
    string[] order;
    string[][string] groups;
    const(ResponseField)*[string] byName;
    foreach (p; paths)
    {
        string rest;
        auto rf = matchHead(fields, p, rest);
        if (rf is null)
            continue;
        if (rf.name !in groups)
        {
            order ~= rf.name;
            groups[rf.name] = null;
            byName[rf.name] = rf;
        }
        groups[rf.name] ~= rest;
    }
    JSONValue out_ = parseJSON("{}");
    foreach (name; order)
        if (auto sv = name in v.objectNoRef)
            out_[name] = projectObject(*sv, groups[name], byName[name].children);
    return out_;
}

/// Apply `--fields` to a decoded JSON response per the command's selection
/// target (#21): `array` trims each item; `items` trims the items of the one
/// array-of-objects property (other top-level fields stay); `object` trims
/// the response itself; `multi` requires `name.field` prefixes. Anything
/// else is a usage error.
JSONValue selectFields(const JSONValue payload, const string[] fields, const(Command)* c)
{
    validateFields(c, fields);
    switch (c.responseTarget)
    {
    case "array":
        if (payload.type != JSONType.array)
            return payload; // the server broke the contract; print it as-is
        JSONValue[] items;
        foreach (it; payload.arrayNoRef)
            items ~= it.type == JSONType.object ? projectObject(it, fields, c.responseFields) : it;
        return JSONValue(items);
    case "items":
        if (payload.type != JSONType.object)
            return payload;
        auto arr = findResponseField(c, c.selection);
        // Split the selection: item fields trim the array's items; other
        // envelope fields stay as-is. `items.a` is the same as `a`.
        // A bare `items` keeps the empty suffix: the whole (schema-filtered)
        // item wins over any sibling `items.x`, as in projectObject.
        string[] itemSel;
        string[] envOrder;
        string[][string] envSel;
        const(ResponseField)*[string] envField;
        foreach (f; fields)
        {
            auto hr = splitPath(f);
            if (hr[0] == c.selection)
                itemSel ~= hr[1];
            else if (isItemField(arr, f))
                itemSel ~= f;
            else
            {
                // An envelope path (`page.totalItems`): unselected envelope
                // fields stay, selected envelope objects are projected.
                string rest;
                auto rf = matchHead(c.responseFields, f, rest);
                if (rf is null)
                    continue;
                if (rf.name !in envSel)
                {
                    envOrder ~= rf.name;
                    envSel[rf.name] = null;
                    envField[rf.name] = rf;
                }
                envSel[rf.name] ~= rest;
            }
        }
        JSONValue out_ = payload;
        foreach (name; envOrder)
        {
            import std.algorithm.searching : canFind;

            auto sv = name in payload.objectNoRef;
            // A bare envelope selection keeps that field untouched.
            if (sv is null || envSel[name].canFind(""))
                continue;
            out_[name] = projectObject(*sv, envSel[name], envField[name].children);
        }
        if (!itemSel.length)
            return out_; // only envelope fields selected: items untouched
        auto slot = c.selection in payload.objectNoRef;
        if (slot is null || slot.type != JSONType.array)
            return out_; // the array is absent from this response
        JSONValue[] items;
        foreach (it; slot.arrayNoRef)
            items ~= it.type == JSONType.object ? projectObject(it, itemSel, arr.children) : it;
        out_[c.selection] = JSONValue(items);
        return out_;
    case "object":
        if (payload.type != JSONType.object)
            return payload;
        return projectObject(payload, fields, c.responseFields);
    case "multi":
        if (payload.type != JSONType.object)
            return payload;
        string[][string] byArray;
        foreach (f; fields)
        {
            auto hr = splitPath(f);
            byArray[hr[0]] ~= hr[1];
        }
        JSONValue out_ = payload;
        foreach (arr, sel; byArray)
        {
            auto rf = findResponseField(c, arr);
            auto slot = arr in out_.objectNoRef;
            if (slot is null || slot.type != JSONType.array)
                continue;
            JSONValue[] items;
            foreach (it; slot.arrayNoRef)
                items ~= it.type == JSONType.object ? projectObject(it, sel, rf.children) : it;
            out_[arr] = JSONValue(items);
        }
        return out_;
    default:
        assert(0, "validateFields rejects an empty responseTarget");
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
    assert(c.selection == "items");
    auto r = selectFields(parseJSON(`{"page":{"totalItems":1},"items":[{"a":"1","b":"2"}]}`),
        ["page.totalItems", "items.a"], c);
    assert(r.toString == `{"items":[{"a":"1"}],"page":{"totalItems":1}}`, r.toString);
}

/// `--fields` validation is content-independent (#21 review): a typo fails
/// before any request, even when the response would be an empty array.
unittest
{
    import d8ctl.specmodel : buildCatalog;
    import d8ctl.catalog : toCommand;
    import std.exception : assertThrown;

    auto cat = buildCatalog(`{"paths": {"/s": {"post": {"operationId": "s",
        "responses": {"200": {"description": "ok", "content": {"application/json":
          {"schema": {"type": "object", "properties": {
            "page": {"type": "object", "properties": {"totalItems": {"type": "integer"}}},
            "items": {"type": "array", "items": {"type": "object", "properties": {
              "a": {"type": "string"}, "b": {"type": "string"}}}}}}}}}}}}}}`, null, "x");
    auto c = new Command;
    *c = toCommand(cat.commands[0]);

    // A mistyped item field is a usage error on an empty response too.
    assertThrown!FieldsException(selectFields(parseJSON(`{"items":[]}`), ["procesInstnaceKey"], c));
    // An undeclared envelope path never silently succeeds.
    assertThrown!FieldsException(selectFields(parseJSON(`{"items":[],"page":{"totalItems":0}}`),
        ["page.notAField"], c));
    assertThrown!FieldsException(selectFields(parseJSON(`{"items":[]}`), ["notAField"], c));
    // A dotted path into a scalar envelope field is a usage error.
    assertThrown!FieldsException(selectFields(parseJSON(`{"items":[]}`), ["page.totalItems.x"], c));
    // Valid selections pass validation regardless of content.
    validateFields(c, ["a", "items.b", "page.totalItems", "items", "page"]);
    auto r = selectFields(parseJSON(`{"page":{"totalItems":0},"items":[]}`), ["a"], c);
    assert(r.toString == `{"items":[],"page":{"totalItems":0}}`, r.toString);
    // Selecting only envelope fields leaves the array untouched.
    auto env = selectFields(parseJSON(`{"page":{"totalItems":1},"items":[{"a":"1","b":"2"}]}`),
        ["page.totalItems"], c);
    assert(env.toString == `{"items":[{"a":"1","b":"2"}],"page":{"totalItems":1}}`, env.toString);
}

/// Envelope projections and whole-array selections in the `items` target.
unittest
{
    import d8ctl.specmodel : buildCatalog;
    import d8ctl.catalog : toCommand;

    auto cat = buildCatalog(`{"paths": {"/s": {"post": {"operationId": "s",
        "responses": {"200": {"description": "ok", "content": {"application/json":
          {"schema": {"type": "object", "properties": {
            "page": {"type": "object", "properties": {"totalItems": {"type": "integer"},
              "endCursor": {"type": "string"}}},
            "items": {"type": "array", "items": {"type": "object", "properties": {
              "a": {"type": "string"}, "b": {"type": "string"}}}}}}}}}}}}}}`, null, "x");
    auto c = new Command;
    *c = toCommand(cat.commands[0]);
    const body_ = `{"page":{"totalItems":1,"endCursor":"z"},"items":[{"a":"1","b":"2"}]}`;
    // An explicit envelope path projects that envelope object.
    auto r = selectFields(parseJSON(body_), ["page.totalItems"], c);
    assert(r.toString == `{"items":[{"a":"1","b":"2"}],"page":{"totalItems":1}}`, r.toString);
    r = selectFields(parseJSON(body_), ["page.totalItems", "items.a"], c);
    assert(r.toString == `{"items":[{"a":"1"}],"page":{"totalItems":1}}`, r.toString);
    // A bare envelope selection keeps it whole, even beside a child path.
    r = selectFields(parseJSON(body_), ["page", "page.totalItems"], c);
    assert(r.toString == parseJSON(body_).toString, r.toString);
    // A whole-array selection wins over sibling item projections.
    r = selectFields(parseJSON(body_), ["items", "items.a"], c);
    assert(r.toString == parseJSON(body_).toString, r.toString);
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

/// Multi-array responses project dotted paths inside the items (#21 review):
/// the suffix is a nested path, not a literal property name.
unittest
{
    import d8ctl.specmodel : buildCatalog;
    import d8ctl.catalog : toCommand;
    import std.exception : assertThrown;

    auto cat = buildCatalog(`{"paths": {"/m": {"get": {"operationId": "getM",
        "responses": {"200": {"description": "ok", "content": {"application/json":
          {"schema": {"type": "object", "properties": {
            "prs": {"type": "array", "items": {"type": "object", "properties": {
              "prKey": {"type": "string"},
              "spec": {"type": "object", "properties": {"name": {"type": "string"},
                "extra": {"type": "string"}}}}}},
            "runs": {"type": "array", "items": {"type": "object", "properties": {
              "id": {"type": "string"}}}}}}}}}}}}}}`, null, "t");
    auto c = new Command;
    *c = toCommand(cat.commands[0]);
    assert(c.responseTarget == "multi");

    auto payload = parseJSON(`{"prs":[{"prKey":"1","spec":{"name":"n","extra":"e"}}],
        "runs":[{"id":"r1","z":0}]}`);
    auto got = selectFields(payload, ["prs.spec.name", "runs.id"], c);
    assert(formatJson(got, false)
        == `{"prs":[{"spec":{"name":"n"}}],"runs":[{"id":"r1"}]}`, formatJson(got, false));
    // An invalid nested suffix never silently passes.
    assertThrown!FieldsException(selectFields(payload, ["prs.spec.nope"], c));
    assertThrown!FieldsException(selectFields(payload, ["prs.nope.name"], c));
    // Deeper than the schema declares: `spec.name.x` has no object to enter.
    assertThrown!FieldsException(selectFields(payload, ["prs.spec.name.x"], c));
}

unittest
{
    // #22 round 3: literal dotted keys, deep siblings, nested arrays, and
    // whole-parent selections are all schema-filtered.
    auto c = new Command;
    c.operationId = "t";
    c.responseTarget = "object";
    ResponseField leaf(string n) { return ResponseField(n, "string", null); }
    c.responseFields = [
        ResponseField("doc", "object", [leaf("camunda.document.type"), leaf("camunda")]),
        ResponseField("a", "object", [ResponseField("b", "object", [leaf("x"), leaf("y")])]),
        ResponseField("parts", "array", [leaf("id"), leaf("role")]),
        ResponseField("spec", "object", [leaf("name")]),
        ResponseField("meta", "json", null),
    ];
    auto in_ = parseJSON(`{"doc":{"camunda.document.type":"t","camunda":"c"},
        "a":{"b":{"x":1,"y":2,"z":3}},"parts":[{"id":1,"role":"L","h":0}],
        "spec":{"name":"n","other":2},"meta":{"k":1}}`);
    auto r = selectFields(in_, ["doc.camunda.document.type"], c);
    assert(r["doc"].objectNoRef.length == 1 && r["doc"]["camunda.document.type"].str == "t");
    r = selectFields(in_, ["a.b.x", "a.b.y"], c);
    assert(r["a"]["b"]["x"].integer == 1 && r["a"]["b"]["y"].integer == 2
        && "z" !in r["a"]["b"].objectNoRef);
    r = selectFields(in_, ["parts.id"], c);
    assert(r["parts"][0].objectNoRef.length == 1 && r["parts"][0]["id"].integer == 1);
    r = selectFields(in_, ["spec", "parts", "meta"], c);
    assert("other" !in r["spec"].objectNoRef && "h" !in r["parts"][0].objectNoRef);
    assert(r["meta"]["k"].integer == 1);
    bool threw;
    try selectFields(in_, ["doc.camunda.nope"], c);
    catch (FieldsException) threw = true;
    assert(threw);
}
