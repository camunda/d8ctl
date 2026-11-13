/// Dispatch a parsed command through the D SDK's generic HTTP surface.
///
/// Every catalog row is live: we substitute path params, attach query flags
/// and an optional JSON body, and call CamundaClient.requestJson / requestVoid
/// / requestText. Multipart ops are refused until we grow a file-flag story.
module d8ctl.dispatch;

@safe:

import camunda;
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

string invoke(CamundaClient client, const ref Result r)
{
    auto c = r.command;
    if (c is null) throw new UsageException("no command");
    if (c.kind == "multipart")
        throw new UsageException(
            c.operationId ~ " is multipart; file flags are not in this spike. "
            ~ "Use the SDK's deployResources helper or wait for the next slice.");

    if (r.positionals.length < c.pathParams.length)
        throw new UsageException(
            "missing path parameter(s). Need: " ~ joinComma(c.pathParams)
            ~ ". See `d8ctl " ~ c.namespace ~ " " ~ c.resource ~ " " ~ c.verb ~ " --help`.");

    auto extra = r.positionals.length - c.pathParams.length;
    if (extra > 0)
        throw new UsageException("unexpected extra argument(s).");

    foreach (q; c.requiredQuery)
        if (q !in r.flags.named)
            throw new UsageException("missing required flag --" ~ q ~ "=…");

    string[string] query;
    foreach (q; c.requiredQuery)
        query[q] = r.flags.named[q];
    foreach (q; c.optionalQuery)
        if (q in r.flags.named) query[q] = r.flags.named[q];

    JSONValue body_ = JSONValue(null);
    if (c.hasBody)
        body_ = buildBody(c, r);
    else if (r.flags.bodyJson.length)
        throw new UsageException("this operation does not take --body.");
    else
    {
        foreach (name, _; r.flags.named)
            if (!isQueryFlag(c, name))
                throw new UsageException(
                    "unknown flag --" ~ name ~ "=. See `d8ctl "
                    ~ c.namespace ~ " " ~ c.resource ~ " " ~ c.verb ~ " --help`.");
    }

    auto path = substitutePath(c.path, c.pathParams, r.positionals[0 .. c.pathParams.length]);

    if (r.flags.dryRun)
        return formatDryRun(c, path, query, body_);

    if (c.kind == "void")
    {
        client.requestVoid(c.method, path, body_, query);
        return "";
    }
    if (c.kind == "text")
        return client.requestText(c.method, path, body_, query);
    auto payload = client.requestJson(c.method, path, body_, query);
    return payload.toPrettyString;
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
    auto obj = emptyObject();

    foreach (name, raw; r.flags.named)
    {
        if (isQueryFlag(c, name)) continue;
        auto f = findBodyField(c, name);
        if (f is null)
            throw new UsageException(
                "unknown flag --" ~ name ~ "=. See `d8ctl "
                ~ c.namespace ~ " " ~ c.resource ~ " " ~ c.verb ~ " --help`.");
        obj[name] = parseTyped(f, raw);
    }

    if (r.flags.bodyJson.length)
    {
        auto extra = parseBodyObject(r.flags.bodyJson);
        foreach (k, v; extra.objectNoRef)
            obj[k] = v;
    }

    if (obj.objectNoRef.length == 0 && !r.flags.bodyJson.length && c.bodyFields.length == 0)
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

string formatDryRun(const Command* c, string path, string[string] query, JSONValue body_)
{
    import std.format : format;
    auto s = format("dry-run %s %s", c.method, path);
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
    if (body_.type != JSONType.null_)
        s ~= "\n" ~ body_.toPrettyString;
    else if (c.hasBody)
        s ~= "\n{}";
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
