/// Dispatch a parsed command through the D SDK's generic HTTP surface.
///
/// Every catalog row is live: we substitute path params, attach query flags
/// and an optional JSON body, and call CamundaClient.requestJson / requestVoid
/// / requestText. Multipart ops are refused until we grow a file-flag story.
module d8ctl.dispatch;

@safe:

import camunda;
import d8ctl.catalog : Command;
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
    {
        if (!r.flags.bodyJson.length)
            throw new UsageException(
                "this operation has a JSON body; pass --body='{…}'.");
        try body_ = parseJSON(r.flags.bodyJson);
        catch (Exception e)
            throw new UsageException("invalid --body JSON: " ~ e.msg);
    }
    else if (r.flags.bodyJson.length)
        throw new UsageException("this operation does not take --body.");

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
}
