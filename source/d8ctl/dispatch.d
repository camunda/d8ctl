/// Dispatch a parsed command through the D SDK's generic HTTP surface.
///
/// Every catalog row is live: we substitute path params, attach query flags
/// and an optional JSON body, and call Transport.requestJson / requestVoid
/// / requestText. Multipart ops are refused until we grow a file-flag story.
module d8ctl.dispatch;

@safe:

import camunda.runtime;
import d8ctl.catalog : BodyField, Command;
import d8ctl.parse : Result;
import std.json;
import std.string : replace;
import std.uri : encodeComponent;

class UsageException : Exception
{
    this(string msg) { super(msg); }
}

string substitutePath(string path, const string[] names, const string[] values)
{
    if (names.length != values.length)
        throw new UsageException("internal: path param count mismatch");
    auto out_ = path;
    foreach (i, name; names)
        out_ = out_.replace("{" ~ name ~ "}", encodeComponent(values[i]));
    return out_;
}

string invoke(Transport client, const ref Result r, string headersJson = null, string baseUrl = null,
    bool pretty = true, RetryStats stats = null)
{
    auto c = r.command;
    if (c is null) throw new UsageException("no command");
    if (c.kind == "multipart")
        throw new UsageException(
            c.operationId ~ " is multipart; file flags are not in this spike. "
            ~ "Use the SDK's deployResources helper or wait for the next slice.");

    // Positional arguments: path parameters in path order, or the order
    // x-cli.positional declares (runtime extensions, #9).
    auto posNames = c.positional.length ? c.positional : c.pathParams;

    // Path parameters are always required positionally. An x-cli.positional
    // query/body field may be omitted (or given as a flag / via --body); the
    // query and body validation below still enforces the required ones.
    size_t needed;
    foreach (i, p; posNames)
        if (isPathParam(c, p))
            needed = i + 1;
    if (r.positionals.length < needed)
        throw new UsageException(
            "missing positional argument(s). Need: " ~ joinComma(posNames[0 .. needed])
            ~ ". See `d8ctl " ~ c.namespace ~ " " ~ c.resource ~ " " ~ c.verb ~ " --help`.");

    if (r.positionals.length > posNames.length)
        throw new UsageException("unexpected extra argument(s).");

    // Bind positionals: path parameters fill the path; with x-cli.positional
    // a name may also be a query parameter or a body field, which binds it
    // exactly like the matching `--name=` flag (before any validation).
    string[string] named;
    foreach (k, v; r.flags.named)
        named[k] = v;
    string[] pathNames, pathValues;
    foreach (i, p; posNames[0 .. r.positionals.length])
    {
        if (isPathParam(c, p))
        {
            pathNames ~= p;
            pathValues ~= r.positionals[i];
            continue;
        }
        if (p in named)
            throw new UsageException("'" ~ p ~ "' was given both positionally and as --" ~ p ~ "=.");
        named[p] = r.positionals[i];
    }
    foreach (p; c.pathParams)
        if (!isPathParam(pathNames, p))
            throw new UsageException("internal: path parameter '" ~ p ~ "' has no positional binding");

    foreach (q; c.requiredQuery)
        if (q !in named)
            throw new UsageException("missing required flag --" ~ q ~ "=…");

    string[string] query;
    foreach (q; c.requiredQuery)
        query[q] = named[q];
    foreach (q; c.optionalQuery)
        if (q in named) query[q] = named[q];

    JSONValue body_ = JSONValue(null);
    if (c.hasBody)
        body_ = buildBody(c, named, r.flags.bodyJson);
    else if (r.flags.bodyJson.length)
        throw new UsageException("this operation does not take --body.");
    else
    {
        foreach (name, _; named)
            if (!isQueryFlag(c, name))
                throw new UsageException(
                    "unknown flag --" ~ name ~ "=. See `d8ctl "
                    ~ c.namespace ~ " " ~ c.resource ~ " " ~ c.verb ~ " --help`.");
    }

    auto path = substitutePath(c.path, pathNames, pathValues);

    // --fields (#21): only JSON responses are selectable, and the whole
    // selection is validated against the response schema up front — a typo
    // must fail as a usage error before a mutating request creates anything,
    // never after (the returned key would be hidden and a retry would
    // duplicate the creation).
    if (r.flags.fields.length)
    {
        if (c.kind != "json")
            throw new UsageException("--fields does not apply to " ~ c.operationId
                ~ " (its response is " ~ c.kind ~ ", not JSON).");
        import d8ctl.output : validateFields;

        validateFields(c, r.flags.fields);
    }

    if (r.flags.dryRun)
        return formatDryRun(c, path, query, body_, headersJson, baseUrl, r.flags.fields);

    // Cluster-admin operations live at the bare root, not under /v2.
    const server = c.rootServer ? ServerBase.root : ServerBase.api;

    if (c.kind == "void")
    {
        retrying!bool(client, stats, c.method, {
            client.requestVoid(c.method, path, body_, query, server);
            return true;
        });
        return "";
    }
    if (c.kind == "text")
        return retrying!string(client, stats, c.method,
            () => client.requestText(c.method, path, body_, query, server));
    auto payload = retrying!JSONValue(client, stats, c.method,
        () => client.requestJson(c.method, path, body_, query, server));
    // The response unchanged: the spec is the output schema (#16) — except
    // --fields, which trims it client-side to the schema's names (#21).
    import d8ctl.output : formatJson, selectFields;
    auto out_ = r.flags.fields.length ? selectFields(payload, r.flags.fields, c) : payload;
    return formatJson(out_, pretty);
}

// ---- CLI retry window (#29) ----

import camunda.config : RetryConfig;

/// The retry settings d8ctl applies when neither a `--camunda-*` switch, the
/// profile nor the environment sets them. A one-shot CLI should ride out a
/// few seconds of flaky link (a Tailscale Funnel TLS drop) rather than fail
/// in the SDK's ~0.3 s worker-sized window: worst case about 10 s.
immutable string[2][3] cliRetryDefaults = [
    ["CAMUNDA_SDK_HTTP_RETRY_MAX_ATTEMPTS", "6"],
    ["CAMUNDA_SDK_HTTP_RETRY_BASE_DELAY_MS", "250"],
    ["CAMUNDA_SDK_HTTP_RETRY_MAX_DELAY_MS", "4000"],
];

/// Fill the unset retry keys of `overrides` with `cliRetryDefaults`. A key
/// counts as set when the overrides or the environment (`getenv`, null for
/// none) have a non-blank value — the SDK treats blank as absent too.
void applyRetryDefaults(ref string[string] overrides, string delegate(string) @safe getenv = null)
{
    import std.string : strip;

    foreach (kv; cliRetryDefaults)
    {
        if (auto v = kv[0] in overrides)
            if ((*v).strip.length) continue;
        if (getenv !is null && getenv(kv[0]).strip.length) continue;
        overrides[kv[0]] = kv[1];
    }
}

/// What the retry loop of one CLI call did, for the error envelope.
final class RetryStats
{
    /// The resolved policy (the transport itself is built with one attempt).
    RetryConfig config;
    /// Attempts made, and the time from the first to the last one ending.
    uint attempts;
    long elapsedMs;
    string method;

    /// Whether the call was retried at all.
    bool retried() const { return attempts > 1; }

    /// Whether a retried write may already have been applied.
    bool mayHaveApplied() const
    {
        return retried && (method == "POST" || method == "PUT" || method == "PATCH");
    }

    /// " (after 6 attempts over 8.1 s; retried, the request may have been
    /// applied)" — empty when the call was not retried.
    string note() const
    {
        import std.format : format;

        if (!retried) return "";
        auto s = format(" (after %s attempts over %.1f s", attempts, elapsedMs / 1000.0);
        if (mayHaveApplied)
            s ~= "; retried, the request may have been applied — check state before retrying";
        return s ~ ")";
    }
}

/// A transport whose own retry is off, with the policy it would have used in
/// `stats`: d8ctl retries in `invoke` so it can count the attempts. `make`
/// builds a transport from overrides (`Transport.fromEnv`, or the
/// environment-masked `extensionTransport`).
Transport countedTransport(string[string] overrides, RetryStats stats,
    scope Transport delegate(string[string]) @safe make)
{
    import std.conv : to;

    stats.config = make(overrides).config.retry;
    auto once = overrides.dup;
    once["CAMUNDA_SDK_HTTP_RETRY_MAX_ATTEMPTS"] = "1";
    return make(once);
}

/// Run `op` under `stats.config` (the SDK's backoff and retryable set),
/// recording the attempts. With no `stats`, `op` runs once (the transport's
/// own retry applies).
T retrying(T)(Transport client, RetryStats stats, string method, scope T delegate() @safe op)
{
    import camunda.retry : backoffDelayMs, isRetryable;

    if (stats is null) return op();
    stats.method = method;
    auto clock = client.clock;
    const start = clock.nowMs;
    const maxAttempts = stats.config.maxAttempts < 1 ? 1 : stats.config.maxAttempts;
    // Record the whole call (backoffs and the final attempt) on every exit.
    scope (exit) stats.elapsedMs = clock.nowMs - start;
    while (true)
    {
        stats.attempts += 1;
        try return op();
        catch (Exception err)
        {
            if (stats.attempts >= maxAttempts || !isRetryable(err)) throw err;
            clock.sleep(backoffDelayMs(stats.config, stats.attempts - 1));
        }
    }
}

bool isPathParam(const Command* c, string name)
{
    return isPathParam(c.pathParams, name);
}

bool isPathParam(const string[] names, string name)
{
    foreach (p; names)
        if (p == name) return true;
    return false;
}

bool isQueryFlag(const Command* c, string name)
{
    foreach (q; c.requiredQuery)
        if (q == name) return true;
    foreach (q; c.optionalQuery)
        if (q == name) return true;
    return false;
}

const(BodyField)* findBodyField(const Command* c, string name)
{
    foreach (i, ref f; c.bodyFields)
        if (f.name == name) return &c.bodyFields[i];
    return null;
}

JSONValue parseTyped(const BodyField* f, string raw)
{
    if (f.kind == "boolean")
    {
        if (raw == "true") return JSONValue(true);
        if (raw == "false") return JSONValue(false);
        throw new UsageException("--" ~ f.name ~ " expects true or false, got '" ~ raw ~ "'");
    }
    if (f.kind == "integer")
    {
        import std.conv : ConvException, to;
        try return JSONValue(to!long(raw));
        catch (ConvException)
            throw new UsageException("--" ~ f.name ~ " expects an integer, got '" ~ raw ~ "'");
    }
    if (f.kind == "number")
    {
        import std.conv : ConvException, to;
        try return JSONValue(to!double(raw));
        catch (ConvException)
            throw new UsageException("--" ~ f.name ~ " expects a number, got '" ~ raw ~ "'");
    }
    if (f.kind == "json")
    {
        try return parseJSON(raw);
        catch (Exception e)
            throw new UsageException("--" ~ f.name ~ " expects JSON: " ~ e.msg);
    }
    return JSONValue(raw);
}

JSONValue emptyObject()
{
    return parseJSON("{}");
}

JSONValue parseBodyObject(string raw)
{
    JSONValue v;
    try v = parseJSON(raw);
    catch (Exception e)
        throw new UsageException("invalid --body JSON: " ~ e.msg);
    if (v.type == JSONType.null_)
        return emptyObject();
    if (v.type != JSONType.object)
        throw new UsageException("--body must be a JSON object");
    return v;
}

JSONValue buildBody(const Command* c, const ref Result r)
{
    return buildBody(c, r.flags.named, r.flags.bodyJson);
}

JSONValue buildBody(const Command* c, const string[string] named, string bodyJson)
{
    auto obj = emptyObject();

    foreach (name, raw; named)
    {
        if (isQueryFlag(c, name)) continue;
        auto f = findBodyField(c, name);
        if (f is null)
            throw new UsageException(
                "unknown flag --" ~ name ~ "=. See `d8ctl "
                ~ c.namespace ~ " " ~ c.resource ~ " " ~ c.verb ~ " --help`.");
        obj[name] = parseTyped(f, raw);
    }

    if (bodyJson.length)
    {
        auto extra = parseBodyObject(bodyJson);
        foreach (k, v; extra.objectNoRef)
            obj[k] = v;
    }

    if (obj.objectNoRef.length == 0 && !bodyJson.length && c.bodyFields.length == 0)
        throw new UsageException(
            "this operation has a JSON body; pass --body='{…}'.");

    foreach (f; c.bodyFields)
    {
        if (!f.required) continue;
        if ((f.name in obj.objectNoRef) !is null) continue;
        throw new UsageException(
            "missing required --" ~ f.name ~ "=" ~ bodyKindHint(f.kind)
            ~ " (or pass it inside --body). See `d8ctl "
            ~ c.namespace ~ " " ~ c.resource ~ " " ~ c.verb ~ " --help`.");
    }
    return obj;
}

string bodyKindHint(string kind)
{
    if (kind == "boolean") return "true|false";
    if (kind == "integer") return "INT";
    if (kind == "number") return "NUM";
    if (kind == "json") return "JSON";
    return "VALUE";
}

string formatDryRun(const Command* c, string path, string[string] query, JSONValue body_,
    string headersJson = null, string baseUrl = null, const string[] fields = null)
{
    import d8ctl.profiles : headersFromJson;
    import std.format : format;
    auto s = format("dry-run %s %s%s", c.method, baseUrl.length ? baseUrl : "", path);
    if (c.rootServer && !baseUrl.length) s ~= " (root server, not under /v2)";
    if (query.length)
    {
        s ~= " ?";
        bool first = true;
        foreach (k, v; query)
        {
            if (!first) s ~= "&";
            first = false;
            s ~= k ~ "=" ~ v;
        }
    }
    // Custom headers: names only, values are treated as secrets.
    foreach (h; headersFromJson(headersJson))
        s ~= "\n" ~ h.name ~ ": ********";
    if (body_.type != JSONType.null_)
        s ~= "\n" ~ body_.toPrettyString(JSONOptions.doNotEscapeSlashes);
    else if (c.hasBody)
        s ~= "\n{}";
    if (fields.length)
    {
        import std.array : join;
        s ~= "\nfields: " ~ fields.join(",");
    }
    return s ~ "\n";
}

string joinComma(const string[] xs)
{
    string s;
    foreach (i, x; xs)
    {
        if (i) s ~= ", ";
        s ~= x;
    }
    return s;
}

unittest
{
    assert(substitutePath("/jobs/{jobKey}/completion", ["jobKey"], ["123"])
        == "/jobs/123/completion");
    assert(joinComma(["a", "b"]) == "a, b");

    import d8ctl.catalog : findByOperationId;
    import d8ctl.parse : parse, Kind;

    auto fail = findByOperationId("failJob");
    assert(fail !is null);
    auto parsed = parse([
        "cluster", "job", "fail", "99",
        "--retries=0",
        "--errorMessage=boom",
        "--dry-run",
    ]);
    assert(parsed.kind == Kind.invoke);
    auto built = buildBody(fail, parsed);
    assert(built["retries"].integer == 0);
    assert(built["errorMessage"].str == "boom");

    auto merged = parse([
        "cluster", "job", "fail", "99",
        "--retries=3",
        "--body={\"retries\":1,\"errorMessage\":\"from-body\"}",
        "--dry-run",
    ]);
    auto won = buildBody(fail, merged);
    assert(won["retries"].integer == 1);
    assert(won["errorMessage"].str == "from-body");

    auto search = findByOperationId("searchProcessInstances");
    auto emptySearch = parse(["cluster", "process-instances", "search", "--dry-run"]);
    auto emptyBody = buildBody(search, emptySearch);
    assert(emptyBody.type == JSONType.object);
    assert(emptyBody.objectNoRef.length == 0);

    auto filtered = parse([
        "cluster", "process-instances", "search",
        "--filter={\"state\":\"ACTIVE\"}",
        "--page={\"limit\":1}",
        "--dry-run",
    ]);
    auto searchBody = buildBody(search, filtered);
    assert(searchBody["filter"]["state"].str == "ACTIVE");
    assert(searchBody["page"]["limit"].integer == 1);

    bool threw;
    try
    {
        auto activate = findByOperationId("activateJobs");
        auto missing = parse(["cluster", "jobs", "activate", "--dry-run"]);
        cast(void) buildBody(activate, missing);
    }
    catch (UsageException) threw = true;
    assert(threw);
}

unittest
{
    // SDK #6: cluster-admin commands are resolved against the bare root.
    import d8ctl.catalog : findByOperationId;
    auto status = findByOperationId("getClusterStatus");
    assert(status !is null && status.rootServer);
    auto topo = findByOperationId("getTopology");
    auto dry = formatDryRun(topo, "/topology", null, JSONValue(null), `{"X-Api-Key":"s3cret"}`);
    import std.string : indexOf;
    assert(dry.indexOf("s3cret") < 0 && dry.indexOf("X-Api-Key: ********") >= 0);
    // Case variants collapse to one preview line, like the SDK's send path.
    auto dup = formatDryRun(topo, "/topology", null, JSONValue(null),
        `{"X-Api-Key":"a","x-api-key":"b"}`);
    assert(dup.indexOf("X-Api-Key") < 0 && dup.indexOf("x-api-key: ********") >= 0);
    // Whitespace-only CAMUNDA_DEFAULT_HEADERS is unset, not a parse error.
    auto blank = formatDryRun(topo, "/topology", null, JSONValue(null), "   ");
    assert(blank.indexOf("********") < 0);
    assert(topo !is null && !topo.rootServer);
}

/// Dry-run previews show the body as sent: `/` is not escaped (#16).
unittest
{
    import d8ctl.catalog : findByOperationId;
    import std.string : indexOf;

    auto c = findByOperationId("searchProcessInstances");
    auto preview = formatDryRun(c, "/process-instances/search", null,
        parseJSON(`{"filter":{"processDefinitionId":"a/b"}}`));
    assert(preview.indexOf(`"a/b"`) >= 0, preview);
    assert(preview.indexOf(`\/`) < 0, preview);
}

/// #29: CLI retry defaults fill only what nothing else set.
unittest
{
    string[string] o;
    applyRetryDefaults(o);
    assert(o["CAMUNDA_SDK_HTTP_RETRY_MAX_ATTEMPTS"] == "6");
    assert(o["CAMUNDA_SDK_HTTP_RETRY_BASE_DELAY_MS"] == "250");
    assert(o["CAMUNDA_SDK_HTTP_RETRY_MAX_DELAY_MS"] == "4000");

    string[string] p = ["CAMUNDA_SDK_HTTP_RETRY_MAX_ATTEMPTS": "2", "CAMUNDA_SDK_HTTP_RETRY_MAX_DELAY_MS": " "];
    applyRetryDefaults(p, (string k) => k == "CAMUNDA_SDK_HTTP_RETRY_BASE_DELAY_MS" ? "7" : null);
    assert(p["CAMUNDA_SDK_HTTP_RETRY_MAX_ATTEMPTS"] == "2"); // profile/switch wins
    assert(("CAMUNDA_SDK_HTTP_RETRY_BASE_DELAY_MS" in p) is null); // env wins
    assert(p["CAMUNDA_SDK_HTTP_RETRY_MAX_DELAY_MS"] == "4000"); // blank is unset

    auto s = new RetryStats;
    s.attempts = 1;
    assert(s.note == "");
    s.attempts = 6;
    s.elapsedMs = 8123;
    s.method = "GET";
    assert(s.note == " (after 6 attempts over 8.1 s)", s.note);
    s.method = "POST";
    import std.string : indexOf;
    assert(s.note.indexOf("may have been applied") >= 0);
}
