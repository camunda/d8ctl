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
