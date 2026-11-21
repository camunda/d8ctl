/// Progressive help. One screen per depth.
module d8ctl.help;

@safe:

import d8ctl.profiles : profileHelp;
import d8ctl.catalog;
import d8ctl.parse : Kind, Order, Result;
import d8ctl.specmodel : Catalog, firstSentence;
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
    buf.put("  d8ctl [--help [--json]] [--version] [--dry-run] [--order=resource|verb]\n");
    buf.put("        [--pretty|--compact] [--output=json|text] [--fields=a,b.c]\n");
    buf.put("        [--profile=<name>] [--camunda-<key>=<value> …] cluster …\n");
    buf.put("  d8ctl profile list|show|add|use|remove …\n");
    buf.put("  d8ctl extension add|list|update|remove …\n\n");
    buf.put(format("The Orchestration Cluster surface is under `cluster` (%s operations).\n", catalogOperationCount));
    buf.put("Both `cluster <resource> <verb>` and `cluster <verb> <resource>` parse.\n");
    buf.put("`--order` only changes how help lists them (default: resource).\n");
    buf.put("Runtime extensions add namespaces from a server's OpenAPI spec; see\n");
    buf.put("`d8ctl extension --help` and `d8ctl help extensions`.\n");
    buf.put("See https://github.com/camunda/d8ctl/issues/1\n");
    buf.put("\nConnection: CAMUNDA_* env vars, a profile (--profile=<name> or the active\n");
    buf.put("one), or explicit switches such as --camunda-rest-address=<url>\n");
    buf.put("--camunda-client-id=… --camunda-client-secret=…. Switches win over the\n");
    buf.put("profile, which wins over env. See: d8ctl profile --help\n");
    buf.put("\nOutput: the API response JSON on stdout (compact unless a terminal);\n");
    buf.put("errors as JSON on stderr; exit codes by kind (2 usage, 3 auth, 4 not\n");
    buf.put("found, 5 client, 6 server, 7 network). See the README.\n");
    buf.put("\nStart with: d8ctl cluster --help\n");
    return buf.data;
}

/// A summary for a one-line listing: its first sentence, at most `max` chars.
/// Command help still shows the whole summary.
string brief(string summary, size_t max = 90)
{
    return firstSentence(summary, max);
}

unittest
{
    assert(brief("Cancel a run. Then more.") == "Cancel a run.");
    assert(brief("v1.2 is out") == "v1.2 is out");
    assert(brief("a b c d e", 6) == "a b c…");
    assert(brief("") == "");
}

string nsHelp(string ns, Order order, const(Catalog)* overlay = null,
    const(Command)[] overlayRows_ = null, bool includeOperator = false)
{
    auto buf = appender!string();
    auto cmds = commandsIn(ns, overlay, overlayRows_, includeOperator);
    buf.put(format("d8ctl %s — %s operation(s)%s\n\n", ns, cmds.length,
        overlay !is null && !includeOperator ? " (operator-only hidden; pass --operator to show)" : ""));
    if (order == Order.resource)
    {
        auto resources = resourcesIn(ns, overlay, overlayRows_, includeOperator);
        buf.put(resources.length
            ? "Usage: d8ctl " ~ ns ~ " <resource> <verb> [flags]\n\n"
            : "Usage: d8ctl " ~ ns ~ " <command> [flags]\n");
        if (resources.length)
            buf.put("Resources:\n");
        foreach (res; resources)
        {
            auto here = commandsFor(ns, res, overlay, overlayRows_, includeOperator);
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
        {
            // Explicit x-cli paths parse only in their authored order, so a
            // verb-first table would list an uninvokable spelling; they are
            // listed verbatim in the x-cli-path section below instead.
            if (c.paths.length)
                continue;
            lines ~= format("  %-12s %-32s %s%s", c.verb, c.resource, brief(c.summary),
                c.operatorOnly ? "  [operator]" : "");
        }
        lines.sort();
        foreach (line; lines) { buf.put(line); buf.put("\n"); }
    }
    string[] pathLines;
    foreach (c; cmds)
        if (c.paths.length)
            pathLines ~= format("  %-32s %s%s", pathsText(c), brief(c.summary), c.operatorOnly ? "  [operator]" : "");
    if (pathLines.length)
    {
        pathLines.sort();
        buf.put("\nCommands (x-cli paths):\n");
        foreach (line; pathLines) { buf.put(line); buf.put("\n"); }
    }
    buf.put("\nPass --help after a resource or command for flags.\n");
    return buf.data;
}

/// `a b | c d` — a row's explicit command path and aliases, as authored.
private string pathsText(const ref Command c)
{
    import std.array : join;

    string[] alts;
    foreach (p; c.paths)
        alts ~= p.join(" ");
    return alts.join(" | ");
}

string resourceHelp(string ns, string resource, const(Catalog)* overlay = null,
    const(Command)[] overlayRows_ = null, bool includeOperator = false)
{
    auto buf = appender!string();
    auto cmds = commandsFor(ns, resource, overlay, overlayRows_, includeOperator);
    if (!cmds.length && overlay !is null)
    {
        // An x-cli command group: list the leaves under it.
        import d8ctl.catalog : commandsUnderPath;
        import std.array : split;

        auto under = commandsUnderPath(overlayRows_, resource.split(" "), includeOperator);
        buf.put(format("d8ctl %s %s — %s command(s)\n\n", ns, resource, under.length));
        foreach (c; under)
        {
            buf.put(format("  %-32s %s %s%s\n", pathsText(c), c.method, c.path,
                c.operatorOnly ? "  [operator]" : ""));
            buf.put(format("  %-32s %s\n", "", brief(c.summary)));
        }
        return buf.data;
    }
    buf.put(format("d8ctl %s %s — %s verb(s)\n\n", ns, resource, cmds.length));
    buf.put("Usage: d8ctl " ~ ns ~ " " ~ resource ~ " <verb> [flags]\n");
    buf.put("   or: d8ctl " ~ ns ~ " <verb> " ~ resource ~ " [flags]\n\n");
    buf.put("Verbs:\n");
    foreach (c; cmds)
    {
        auto ver = c.addedInVersion.length ? "  (since " ~ c.addedInVersion ~ ")" : "";
        auto op = c.operatorOnly ? "  [operator]" : "";
        buf.put(format("  %-12s %s %s%s%s\n", c.verb, c.method, c.path, ver, op));
        buf.put(format("               %s\n", c.summary));
    }
    // A derived resource can share its word with an x-cli command group:
    // list the group's explicit children too, never hide them.
    if (overlay !is null)
    {
        import d8ctl.catalog : commandsUnderPath;
        import std.array : split;

        bool first = true;
        foreach (c; commandsUnderPath(overlayRows_, resource.split(" "), includeOperator))
        {
            if (!c.paths.length)
                continue;
            if (first)
                buf.put("\nCommands:\n");
            first = false;
            buf.put(format("  %-32s %s %s%s\n", pathsText(c), c.method, c.path,
                c.operatorOnly ? "  [operator]" : ""));
            buf.put(format("  %-32s %s\n", "", c.summary));
        }
    }
    return buf.data;
}

string commandHelp(const Command* c)
{
    auto buf = appender!string();
    if (c.paths.length)
        buf.put(format("d8ctl %s %s\n\n", c.namespace, pathsText(*c)));
    else
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
    if (c.positional.length)
    {
        buf.put("\nPositional arguments (x-cli, in order):\n");
        foreach (p; c.positional)
            buf.put("  " ~ p ~ "\n");
    }
    if (c.operatorOnly)
        buf.put("\nOperator-only: hidden and refused unless you pass --operator.\n");
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
                buf.put(format("               %s\n", firstSentence(f.doc)));
        }
        buf.put("  * required unless supplied via --body.\n");
        buf.put("  Nested objects/arrays: pass JSON, e.g. --filter='{\"state\":\"ACTIVE\"}'.\n");
    }
    else if (c.hasBody)
        buf.put("\nThis body has no documented top-level fields; use --body='{…}'.\n");
    if (c.responseTarget.length)
    {
        buf.put("\nResponse fields (--fields=a,b.c selects; dotted paths keep nesting):\n");
        switch (c.responseTarget)
        {
        case "array":
            buf.put("  The response is an array; selection trims each item.\n");
            break;
        case "items":
            buf.put("  Selection trims each item of the response's array; other top-level fields stay.\n");
            break;
        case "multi":
            buf.put("  Several arrays: prefix every field with the array name (e.g. "
                ~ c.responseFields[0].name ~ "." ~ c.responseFields[0].children[0].name ~ ").\n");
            break;
        default:
            buf.put("  Selection trims the response object.\n");
            break;
        }
        foreach (f; c.responseFields)
            putResponseField(buf, f, "  ");
    }
    buf.put("\nGlobal flags: --dry-run  --fields=a,b.c  --header='Name: value'  --help [--json]\n"
        ~ "              --operator  --order=resource|verb  --profile=NAME\n"
        ~ "              --pretty|--compact  --output=json|text (errors)\n");
    return buf.data;
}

/// One response field line in text help; children list their dotted paths.
private void putResponseField(ref typeof(appender!string()) buf, const ref ResponseField f, string indent)
{
    buf.put(format("%s%-28s %s\n", indent, f.name, f.kind));
    foreach (ref ch; f.children)
        putResponseField(buf, ch, indent ~ "  .");
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
    case Kind.helpProfile:
        return profileHelp();
    case Kind.helpExtension:
        import d8ctl.extensions : extensionHelp;

        return extensionHelp();
    case Kind.invoke, Kind.profile, Kind.extension, Kind.error:
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

    // A oneOf of object variants (by key or by BPMN process id) offers every
    // variant's fields as flags; --body still works.
    auto create = findByOperationId("createProcessInstance");
    auto createHelp = commandHelp(create);
    assert(createHelp.canFind("--processDefinitionId="));
    assert(createHelp.canFind("--processDefinitionKey="));
    assert(createHelp.canFind("--body='{…}'"));
}

unittest
{
    // PR #13 round 4: with --order=verb the resource/verb table must not list
    // explicit x-cli paths reversed (they parse only in their authored order);
    // they stay in the dedicated x-cli-path section.
    import d8ctl.parse : Order;
    import d8ctl.specmodel : buildCatalog;

    auto cat = new Catalog;
    *cat = buildCatalog(`{"openapi":"3.0.3","info":{"title":"T","version":"1"},
      "servers":[{"url":"http://h"}],
      "paths": {
        "/status": {"get": {"operationId": "getStatus",
            "responses": {"200": {"description": "ok"}}}},
        "/runs/{id}/cancel": {"post": {"operationId": "cancelRun",
            "x-cli": {"command": ["pr", "run", "cancel"], "positional": ["id"]},
            "parameters": [{"name": "id", "in": "path", "required": true}],
            "responses": {"200": {"description": "ok"}}}}
      }}`, null, "t");
    import d8ctl.catalog : overlayRows;

    auto rows = overlayRows(cat);
    auto verb = nsHelp("t", Order.verb, cat, rows);
    assert(!verb.canFind("cancel pr run") && !verb.canFind("cancel  pr"),
        verb);
    assert(verb.canFind("pr run cancel"), verb); // verbatim in the path section
    assert(verb.canFind("get"), verb); // derived commands still listed
    auto res = nsHelp("t", Order.resource, cat, rows);
    assert(res.canFind("pr run cancel"), res);
}

private bool canFind(string hay, string needle)
{
    import std.algorithm : countUntil;
    return hay.countUntil(needle) >= 0;
}

// ---- Machine-readable help (`--help --json`, #16) ----

import std.json : JSONOptions, JSONValue;

/// The words that invoke `c` (the first spelling when x-cli gives several).
private string invocation(const ref Command c)
{
    import std.array : join;

    if (c.paths.length)
        return "d8ctl " ~ c.namespace ~ " " ~ c.paths[0].join(" ");
    return "d8ctl " ~ c.namespace ~ " " ~ c.resource ~ " " ~ c.verb;
}

/// One command as JSON: a summary, plus its inputs when `detail`.
JSONValue commandJson(const ref Command c, bool detail)
{
    import std.array : join;

    JSONValue j = [
        "command": invocation(c),
        "operation": c.operationId,
        "summary": c.summary,
        "method": c.method,
        "path": c.path,
    ];
    if (!detail) return j;
    string[] aliases;
    foreach (i, p; c.paths)
        if (i) aliases ~= "d8ctl " ~ c.namespace ~ " " ~ p.join(" ");
    if (aliases.length) j["aliases"] = aliases;
    if (c.addedInVersion.length) j["addedInVersion"] = c.addedInVersion;
    j["operatorOnly"] = c.operatorOnly;
    // Positional arguments, in order: x-cli's, else the path parameters.
    j["positional"] = c.positional.length ? c.positional.dup : c.pathParams.dup;
    JSONValue[] flags;
    foreach (q; c.requiredQuery)
        flags ~= JSONValue(["name": JSONValue(q), "in": JSONValue("query"), "required": JSONValue(true)]);
    foreach (q; c.optionalQuery)
        flags ~= JSONValue(["name": JSONValue(q), "in": JSONValue("query"), "required": JSONValue(false)]);
    foreach (f; c.bodyFields)
    {
        JSONValue fj = ["name": JSONValue(f.name), "in": JSONValue("body"),
            "type": JSONValue(f.kind), "required": JSONValue(f.required)];
        if (f.doc.length) fj["description"] = f.doc;
        flags ~= fj;
    }
    j["flags"] = flags;
    j["body"] = c.hasBody; // --body='{…}' accepted (wins over body flags)
    // `json`: stdout is the response JSON; `text`: raw text; `void`: nothing.
    j["output"] = c.kind == "multipart" ? "json" : c.kind;
    if (c.responseTarget.length)
    {
        j["responseTarget"] = c.responseTarget;
        if (c.selection.length)
            j["selection"] = c.selection;
        JSONValue[] rfs;
        foreach (f; c.responseFields)
            rfs ~= responseFieldJson(f);
        j["responseFields"] = rfs;
    }
    return j;
}

private JSONValue responseFieldJson(const ref ResponseField f)
{
    JSONValue fj = ["name": JSONValue(f.name), "type": JSONValue(f.kind)];
    if (f.children.length)
    {
        JSONValue[] chs;
        foreach (ref ch; f.children)
            chs ~= responseFieldJson(ch);
        fj["children"] = chs;
    }
    return fj;
}

/// `--help --json` for one command. `subcommands`: the commands under it
/// when its x-cli path is also a group (`guide` over `guide skill`).
string commandHelpJson(const Command* c, const(Command)[] subcommands = null)
{
    auto j = commandJson(*c, true);
    if (subcommands.length)
    {
        JSONValue[] list;
        foreach (ref s; subcommands)
            list ~= commandJson(s, false);
        j["subcommands"] = list;
    }
    return j.toString(JSONOptions.doNotEscapeSlashes);
}

/// The text help's "Subcommands:" block for a command that is also a group.
string subcommandsText(const(Command)[] subcommands)
{
    if (!subcommands.length) return null;
    auto buf = appender!string();
    buf.put("\nSubcommands:\n");
    foreach (ref s; subcommands)
        buf.put(format("  %-32s %s\n", pathsText(s), brief(s.summary)));
    return buf.data;
}

/// `--help --json` for a list of commands: `{"commands":[summary…]}`.
string commandsHelpJson(const(Command)[] cmds)
{
    JSONValue[] list;
    foreach (ref c; cmds)
        list ~= commandJson(c, false);
    JSONValue root = ["commands": list];
    return root.toString(JSONOptions.doNotEscapeSlashes);
}

unittest
{
    import std.json : JSONType, parseJSON;

    auto c = findByOperationId("getTopology");
    assert(c !is null);
    auto j = parseJSON(commandHelpJson(c));
    assert(j["operation"].str == "getTopology");
    assert(j["command"].str == "d8ctl cluster topology get");
    assert(j["output"].str == "json" && j["body"].type == JSONType.false_);
    assert(j["flags"].arrayNoRef.length == 0);

    const(Command)* create;
    foreach (ref row; commandsIn("cluster"))
        if (row.bodyFields.length) { create = &row; break; }
    assert(create !is null);
    auto cj = parseJSON(commandHelpJson(create));
    bool sawBodyFlag;
    foreach (f; cj["flags"].arrayNoRef)
        if (f["in"].str == "body") sawBodyFlag = true;
    assert(sawBodyFlag && cj["body"].type == JSONType.true_);

    auto list = parseJSON(commandsHelpJson([*c, *create]));
    assert(list["commands"].arrayNoRef.length == 2);
    assert("flags" !in list["commands"][0].objectNoRef, "lists carry summaries only");
}

// #23: `--help --json` carries a body field's whole description; text help
// shows its first sentence on one line.
unittest
{
    import std.algorithm : canFind;
    import std.json : parseJSON;

    const(Command)* cmd;
    string field, doc;
    outer: foreach (ref row; commandsIn("cluster"))
        foreach (f; row.bodyFields)
            if (f.doc.length > 120)
            {
                cmd = &row;
                field = f.name;
                doc = f.doc;
                break outer;
            }
    assert(cmd !is null, "the generated catalog has a long field description");

    bool found;
    foreach (f; parseJSON(commandHelpJson(cmd))["flags"].arrayNoRef)
        if (f["in"].str == "body" && f["name"].str == field)
        {
            assert(f["description"].str == doc, "JSON help keeps the whole description");
            found = true;
        }
    assert(found);

    auto text = commandHelp(cmd);
    assert(text.canFind(firstSentence(doc)));
    assert(!text.canFind(doc), "text help shows only the first sentence");
}
