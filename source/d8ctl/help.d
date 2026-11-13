/// Progressive help. One screen per depth.
module d8ctl.help;

@safe:

import d8ctl.catalog;
import d8ctl.parse : Kind, Order, Result;
import d8ctl.util : eqIgnoreCase;
import d8ctl.version_ : cliVersion;
import std.algorithm : sort;
import std.array : appender;
import std.format : format;

enum versionString = "d8ctl " ~ cliVersion ~ " (catalog " ~ catalogSpecHash ~ ")";

string rootHelp()
{
    auto buf = appender!string();
    buf.put("d8ctl — Camunda 8 Orchestration Cluster CLI (spike)\n\n");
    buf.put("Usage:\n");
    buf.put("  d8ctl [--help] [--version] [--dry-run] [--order=resource|verb] cluster …\n\n");
    buf.put(format("The Orchestration Cluster surface is under `cluster` (%s operations).\n", catalogOperationCount));
    buf.put("Both `cluster <resource> <verb>` and `cluster <verb> <resource>` parse.\n");
    buf.put("`--order` only changes how help lists them (default: resource).\n");
    buf.put("See https://github.com/camunda/d8ctl/issues/1\n");
    buf.put("\nStart with: d8ctl cluster --help\n");
    return buf.data;
}

string nsHelp(string ns, Order order)
{
    auto buf = appender!string();
    auto cmds = commandsIn(ns);
    buf.put(format("d8ctl %s — %s operation(s)\n\n", ns, cmds.length));
    if (order == Order.resource)
    {
        buf.put("Usage: d8ctl " ~ ns ~ " <resource> <verb> [flags]\n\n");
        buf.put("Resources:\n");
        foreach (res; resourcesIn(ns))
        {
            auto here = commandsFor(ns, res);
            string verbs;
            foreach (c; here)
            {
                if (verbs.length) verbs ~= ", ";
                verbs ~= c.verb;
            }
            buf.put(format("  %-32s %s\n", res, verbs));
        }
    }
    else
    {
        buf.put("Usage: d8ctl " ~ ns ~ " <verb> <resource> [flags]\n\n");
        buf.put("Commands:\n");
        string[] lines;
        foreach (c; cmds)
            lines ~= format("  %-12s %-32s %s", c.verb, c.resource, c.summary);
        lines.sort();
        foreach (line; lines) { buf.put(line); buf.put("\n"); }
    }
    buf.put("\nPass --help after a resource or command for flags.\n");
    return buf.data;
}

string resourceHelp(string ns, string resource)
{
    auto buf = appender!string();
    auto cmds = commandsFor(ns, resource);
    buf.put(format("d8ctl %s %s — %s verb(s)\n\n", ns, resource, cmds.length));
    buf.put("Usage: d8ctl " ~ ns ~ " " ~ resource ~ " <verb> [flags]\n");
    buf.put("   or: d8ctl " ~ ns ~ " <verb> " ~ resource ~ " [flags]\n\n");
    buf.put("Verbs:\n");
    foreach (c; cmds)
    {
        auto ver = c.addedInVersion.length ? "  (since " ~ c.addedInVersion ~ ")" : "";
        buf.put(format("  %-12s %s %s%s\n", c.verb, c.method, c.path, ver));
        buf.put(format("               %s\n", c.summary));
    }
    return buf.data;
}

string commandHelp(const Command* c)
{
    auto buf = appender!string();
    buf.put(format("d8ctl %s %s %s\n\n", c.namespace, c.resource, c.verb));
    buf.put(c.summary);
    buf.put("\n\n");
    buf.put(format("  HTTP        %s %s\n", c.method, c.path));
    buf.put(format("  operation   %s\n", c.operationId));
    if (c.addedInVersion.length)
        buf.put(format("  added in    %s\n", c.addedInVersion));
    if (c.hasBody)
    {
        if (c.bodyFields.length)
            buf.put("  body        flags below, or --body='{…}' (wins on conflict)\n");
        else
            buf.put("  body        yes (--body='{…}')\n");
    }
    else
        buf.put("  body        no\n");
    if (c.pathParams.length)
    {
        buf.put("\nPath parameters (positional, in order):\n");
        foreach (p; c.pathParams)
            buf.put("  " ~ p ~ "\n");
    }
    if (c.requiredQuery.length)
    {
        buf.put("\nRequired query flags:\n");
        foreach (p; c.requiredQuery)
            buf.put("  --" ~ p ~ "=VALUE\n");
    }
    if (c.optionalQuery.length)
    {
        buf.put("\nOptional query flags:\n");
        foreach (p; c.optionalQuery)
            buf.put("  --" ~ p ~ "=VALUE\n");
    }
    if (c.bodyFields.length)
    {
        buf.put("\nBody flags (top-level JSON fields):\n");
        foreach (f; c.bodyFields)
        {
            auto star = f.required ? "*" : " ";
            auto hint = bodyKindHint(f.kind);
            buf.put(format(" %s --%s=%s\n", star, f.name, hint));
            if (f.doc.length)
                buf.put(format("               %s\n", f.doc));
        }
        buf.put("  * required unless supplied via --body.\n");
        buf.put("  Nested objects/arrays: pass JSON, e.g. --filter='{\"state\":\"ACTIVE\"}'.\n");
    }
    else if (c.hasBody)
        buf.put("\nThis body has no documented top-level fields; use --body='{…}'.\n");
    buf.put("\nGlobal flags: --dry-run  --help  --order=resource|verb\n");
    return buf.data;
}

string bodyKindHint(string kind)
{
    if (kind == "boolean") return "true|false";
    if (kind == "integer") return "INT";
    if (kind == "number") return "NUM";
    if (kind == "json") return "JSON";
    return "VALUE";
}

string render(const ref Result r)
{
    final switch (r.kind)
    {
    case Kind.helpRoot, Kind.version_:
        return r.kind == Kind.version_ ? versionString ~ "\n" : rootHelp();
    case Kind.helpNs:
        return nsHelp(r.ns, r.flags.order);
    case Kind.helpResource:
        return resourceHelp(r.ns, r.resource);
    case Kind.helpCommand:
        return commandHelp(r.command);
    case Kind.invoke, Kind.error:
        return r.message;
    }
}

unittest
{
    import d8ctl.parse : parse, Kind;
    auto r = parse(["--help"]);
    auto text = render(r);
    assert(text.length > 0);
    assert(text.canFind("cluster"));

    import d8ctl.catalog : findByOperationId;
    auto fail = findByOperationId("failJob");
    auto failHelp = commandHelp(fail);
    assert(failHelp.canFind("--retries="));
    assert(failHelp.canFind("--errorMessage="));
    assert(failHelp.canFind("--body="));

    auto create = findByOperationId("createProcessInstance");
    auto createHelp = commandHelp(create);
    assert(createHelp.canFind("no documented top-level fields"));
    assert(createHelp.canFind("--body='{…}'"));
}

private bool canFind(string hay, string needle)
{
    import std.algorithm : countUntil;
    return hay.countUntil(needle) >= 0;
}
