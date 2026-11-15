/// Argv parser. Accepts resource-then-verb *and* verb-then-resource.
///
///   d8ctl cluster topology get
///   d8ctl cluster get topology
///
/// `--help` / `-h` at any depth prints help for that depth and exits the
/// parse as a Help result. `--order=resource|verb` only changes how help
/// lists commands; both orders always parse.
module d8ctl.parse;

@safe:

import d8ctl.extensions : Extension, ExtensionException;
import d8ctl.profiles : Header, parseHeaderSwitch, ProfileException, switchToKey;
import d8ctl.catalog;
import d8ctl.specmodel : Catalog;
import d8ctl.util : eqIgnoreCase;
import std.algorithm : canFind, startsWith;
import std.string : indexOf;

enum Order
{
    resource,
    verb,
}

struct Flags
{
    bool help;
    bool version_;
    bool dryRun;
    /// Reveal and allow operator-audience extension operations (per-invocation).
    bool operator;
    Order order = Order.resource;
    string[string] named;
    string bodyJson;
    /// `--profile=<name>`.
    string profile;
    /// `--camunda-<key>=<value>` switches, keyed by SDK config key.
    string[string] config;
    /// `--header 'Name: value'` (repeatable), in argv order.
    Header[] headers;
    /// Value-less `--flag`s. Only `profile`/`extension` subcommands accept them.
    bool[string] bare;
}

enum Kind
{
    helpRoot,
    helpNs,
    helpResource,
    helpCommand,
    version_,
    invoke,
    profile,
    helpProfile,
    extension,
    helpExtension,
    error,
}

struct Result
{
    Kind kind;
    string message;
    string ns;
    string resource;
    string verb;
    const(Command)* command;
    /// Set when `ns` is a runtime extension: the model built from its cache.
    const(Catalog)* extCatalog;
    /// `extCatalog` materialized as a `Command` table; `command` points into it.
    const(Command)[] extRows;
    Flags flags;
    string[] positionals;
}

Result parse(string[] args)
{
    import d8ctl.profiles : configDir;

    return parse(args, configDir());
}

/// Full parse. `cfgDir` locates installed runtime extensions (`<cfgDir>/extensions/`);
/// production passes `configDir()`, tests a temp dir.
Result parse(string[] args, string cfgDir)
{
    Result r;
    Flags flags;
    string[] pos;

    // c8ctl spelling: `--profile <name>` (space-separated).
    string[] joined;
    for (size_t i = 0; i < args.length; i++)
    {
        if (args[i] == "--profile" && i + 1 < args.length && !args[i + 1].startsWith("-"))
        {
            joined ~= "--profile=" ~ args[i + 1];
            i++;
        }
        else if ((args[i] == "--header" || args[i] == "-H") && i + 1 < args.length)
        {
            joined ~= "--header=" ~ args[i + 1];
            i++;
        }
        else
            joined ~= args[i];
    }
    args = joined;

    foreach (a; args)
    {
        if (a == "--help" || a == "-h")
        {
            flags.help = true;
            continue;
        }
        if (a == "--version")
        {
            flags.version_ = true;
            continue;
        }
        if (a == "--dry-run")
        {
            flags.dryRun = true;
            continue;
        }
        if (a == "--operator")
        {
            flags.operator = true;
            continue;
        }
        if (a.startsWith("--order="))
        {
            auto v = a[8 .. $];
            if (v == "verb") flags.order = Order.verb;
            else if (v == "resource") flags.order = Order.resource;
            else
            {
                r.kind = Kind.error;
                r.message = "unknown --order=" ~ v ~ " (expected resource or verb)";
                return r;
            }
            continue;
        }
        if (a.startsWith("--body="))
        {
            flags.bodyJson = a[7 .. $];
            continue;
        }
        if (a.startsWith("--header="))
        {
            try flags.headers ~= parseHeaderSwitch(a[9 .. $]);
            catch (ProfileException e)
            {
                r.kind = Kind.error;
                r.message = e.msg;
                return r;
            }
            continue;
        }
        if (a.startsWith("--profile="))
        {
            flags.profile = a[10 .. $];
            if (!flags.profile.length)
            {
                r.kind = Kind.error;
                r.message = "--profile= needs a profile name";
                return r;
            }
            continue;
        }
        if (a.startsWith("--") && a.length > 2)
        {
            auto rest = a[2 .. $];
            auto eq = rest.indexOf('=');
            if (eq < 0)
            {
                if (rest.startsWith("camunda-") || rest == "profile" || rest == "header")
                {
                    r.kind = Kind.error;
                    r.message = "flag --" ~ rest ~ " needs a value (--" ~ rest ~ "=…)";
                    return r;
                }
                flags.bare[rest] = true;
                continue;
            }
            if (rest.startsWith("camunda-") && eq > 8)
            {
                flags.config[switchToKey(rest[8 .. eq])] = rest[eq + 1 .. $];
                continue;
            }
            flags.named[rest[0 .. eq]] = rest[eq + 1 .. $];
            continue;
        }
        if (a.startsWith("-") && a != "-")
        {
            r.kind = Kind.error;
            r.message = "unknown flag " ~ a;
            return r;
        }
        pos ~= a;
    }
    r.flags = flags;

    if (flags.version_ && pos.length == 0)
    {
        r.kind = Kind.version_;
        return r;
    }

    if (pos.length == 0)
    {
        r.kind = Kind.helpRoot;
        return r;
    }

    // c8ctl spelling: `list profiles`, `use profile <name>`, `add profile …`.
    if (pos.length >= 2 && (pos[1] == "profile" || pos[1] == "profiles")
        && ["list", "show", "add", "use", "remove", "rm", "delete"].canFind(pos[0]))
        pos = ["profile", pos[0]] ~ pos[2 .. $];

    if (pos[0] == "profile")
    {
        r.positionals = pos[1 .. $];
        r.kind = flags.help ? Kind.helpProfile : Kind.profile;
        return r;
    }

    if (pos[0] == "help" && pos.length >= 2 && (pos[1] == "extensions" || pos[1] == "extension"))
    {
        r.kind = Kind.helpExtension;
        return r;
    }

    if (pos[0] == "extension" || pos[0] == "extensions")
    {
        r.positionals = pos[1 .. $];
        r.kind = flags.help ? Kind.helpExtension : Kind.extension;
        return r;
    }

    // Value-less flags are only meaningful to `profile`/`extension` subcommands.
    foreach (k, _; flags.bare)
    {
        r.kind = Kind.error;
        r.message = "flag --" ~ k ~ " needs a value (--" ~ k ~ "=…)";
        return r;
    }

    const(Command)* cmd;
    const(Catalog)* extCat;
    const(Command)[] extRows;
    if (!isNamespace(pos[0]))
    {
        // Runtime extensions: a cached spec becomes a namespace (#9).
        if (auto e = tryLoadExtension(cfgDir, pos[0]))
        {
            r.ns = pos[0];
            auto catCopy = new Catalog;
            *catCopy = e.catalog;
            extCat = catCopy;
            extRows = overlayRows(extCat);
            r.extCatalog = extCat;
            r.extRows = extRows;
            goto extensionNs;
        }
        r.kind = Kind.error;
        r.message = "unknown namespace '" ~ pos[0] ~ "'. See `d8ctl --help`.";
        return r;
    }
    r.ns = pos[0];

extensionNs:
    if (pos.length == 1)
    {
        r.kind = Kind.helpNs;
        return r;
    }

    // Explicit x-cli command paths (nano-ide ADR 0068): matched word-for-word
    // as authored, longest first; never reordered.
    if (extCat !is null)
    {
        size_t used;
        auto hit = findPath(extRows, pos[1 .. $], used, flags.operator);
        if (hit is null && !flags.operator)
        {
            size_t hidden;
            auto op = findPath(extRows, pos[1 .. $], hidden, true);
            if (op !is null)
            {
                import std.array : join;

                r.kind = Kind.error;
                r.message = "operation " ~ pos[1 .. 1 + hidden].join(" ")
                    ~ " is operator-only; re-run with --operator";
                return r;
            }
        }
        if (hit !is null)
        {
            r.command = hit;
            r.resource = hit.resource;
            r.verb = hit.verb;
            r.positionals = pos[1 + used .. $];
            r.kind = flags.help ? Kind.helpCommand : Kind.invoke;
            return r;
        }
        // A strict prefix of a path is a command group: show its leaves.
        if (commandsUnderPath(extRows, pos[1 .. $], flags.operator).length)
        {
            import std.array : join;

            r.resource = pos[1 .. $].join(" ");
            r.kind = Kind.helpResource;
            return r;
        }
    }

    auto a = pos[1];
    string b = pos.length > 2 ? pos[2] : null;

    // Prefer the order that actually matches a command. Operator-only rows
    // stay invisible without --operator — even from lookup.
    if (b.length)
    {
        cmd = findExact(r.ns, a, b, extCat, extRows, flags.operator);
        if (cmd !is null)
        {
            r.resource = a;
            r.verb = b;
        }
        else
        {
            cmd = findExact(r.ns, b, a, extCat, extRows, flags.operator);
            if (cmd !is null)
            {
                r.resource = b;
                r.verb = a;
            }
        }
    }
    if (cmd is null && !b.length)
    {
        // `d8ctl cluster topology` — resource help if it is a resource.
        auto res = commandsFor(r.ns, a, extCat, extRows, flags.operator);
        if (res.length)
        {
            r.resource = a;
            r.kind = flags.help ? Kind.helpResource : Kind.helpResource;
            return r;
        }
        // `d8ctl cluster get` — verb help (list resources that accept get).
        if (isVerb(a, extCat, extRows))
        {
            r.verb = a;
            r.kind = Kind.helpNs;
            r.message = a;
            return r;
        }
        r.kind = Kind.error;
        r.message = "unknown resource or verb '" ~ a ~ "' in namespace '" ~ r.ns ~ "'.";
        return r;
    }
    if (cmd is null)
    {
        // An operator-only row exists but is hidden: say so, don't say "unknown".
        if (extCat !is null && !flags.operator)
        {
            auto hit = findExact(r.ns, a, b, extCat, extRows, true);
            if (hit is null && b.length)
                hit = findExact(r.ns, b, a, extCat, extRows, true);
            if (hit !is null)
            {
                r.kind = Kind.error;
                r.message = "operation " ~ hit.resource ~ " " ~ hit.verb
                    ~ " is operator-only; re-run with --operator";
                return r;
            }
        }
        r.kind = Kind.error;
        r.message = "unknown command in namespace '" ~ r.ns ~ "': " ~ a
            ~ (b.length ? " " ~ b : "");
        return r;
    }

    r.command = cmd;
    r.resource = cmd.resource;
    r.verb = cmd.verb;
    if (pos.length > 3) r.positionals = pos[3 .. $];
    r.kind = flags.help ? Kind.helpCommand : Kind.invoke;
    return r;
}

/// The extension named `name`, or null when none is installed. A corrupt
/// cache is a parse error naming the fix.
private Extension* tryLoadExtension(string cfgDir, string name)
{
    import d8ctl.extensions : isValidExtensionName, loadExtension;

    if (!isValidExtensionName(name))
        return null;
    import std.file : exists;

    if (!exists(manifestPathOf(cfgDir, name)))
        return null;
    auto loaded = new Extension;
    *loaded = loadExtension(cfgDir, name);
    return loaded;
}

private string manifestPathOf(string cfgDir, string name)
{
    import d8ctl.extensions : manifestPath;

    return manifestPath(cfgDir, name);
}

unittest
{
    auto r = parse(["cluster", "topology", "get"]);
    assert(r.kind == Kind.invoke);
    assert(r.command !is null);
    assert(r.command.operationId == "getTopology");

    auto v = parse(["cluster", "get", "topology"]);
    assert(v.kind == Kind.invoke);
    assert(v.command.operationId == "getTopology");

    auto h = parse(["--help"]);
    assert(h.kind == Kind.helpRoot);

    auto n = parse(["cluster"]);
    assert(n.kind == Kind.helpNs);

    auto res = parse(["cluster", "topology"]);
    assert(res.kind == Kind.helpResource);

    auto bad = parse(["nope"]);
    assert(bad.kind == Kind.error);

    auto jobs = parse(["cluster", "jobs", "activate"]);
    assert(jobs.kind == Kind.invoke);
    assert(jobs.command.operationId == "activateJobs");

    auto sw = parse(["--profile=saas", "--camunda-rest-address=http://h:1", "cluster", "topology", "get"]);
    assert(sw.kind == Kind.invoke);
    assert(sw.flags.profile == "saas");
    assert(sw.flags.config["CAMUNDA_REST_ADDRESS"] == "http://h:1");
    assert("camunda-rest-address" !in sw.flags.named);

    auto pr = parse(["profile", "add", "x", "--from-env", "--camunda-auth-strategy=NONE"]);
    assert(pr.kind == Kind.profile && pr.positionals == ["add", "x"]);
    assert("from-env" in pr.flags.bare && pr.flags.config["CAMUNDA_AUTH_STRATEGY"] == "NONE");
    assert(parse(["profile", "--help"]).kind == Kind.helpProfile);
    auto c8 = parse(["use", "profile", "prod"]);
    assert(c8.kind == Kind.profile && c8.positionals == ["use", "prod"]);
    assert(parse(["list", "profiles"]).positionals == ["list"]);
    auto sp = parse(["--profile", "prod", "cluster", "topology", "get"]);
    assert(sp.kind == Kind.invoke && sp.flags.profile == "prod");
    assert(parse(["cluster", "topology", "get", "--profile"]).kind == Kind.error);
    assert(parse(["cluster", "topology", "get", "--from-env"]).kind == Kind.error);
    assert(parse(["--camunda-rest-address", "cluster"]).kind == Kind.error);

    // --header: both spellings, repeatable, order kept; malformed is an error.
    auto hd = parse(["--header", "X-Api-Key: abc", "--header=x-trace:  t1 ", "-H", "A:b:c",
        "cluster", "topology", "get"]);
    assert(hd.kind == Kind.invoke && hd.flags.headers.length == 3);
    assert(hd.flags.headers[0] == Header("X-Api-Key", "abc"));
    assert(hd.flags.headers[1] == Header("x-trace", "t1"));
    assert(hd.flags.headers[2] == Header("A", "b:c"));
    assert(parse(["--header=novalue", "cluster", "topology", "get"]).kind == Kind.error);
    assert(parse(["--header=: v", "cluster", "topology", "get"]).kind == Kind.error);
    assert(parse(["--header=Bad Name: v", "cluster", "topology", "get"]).kind == Kind.error);
    assert(parse(["cluster", "topology", "get", "--header"]).kind == Kind.error);
    auto ph = parse(["profile", "add", "x", "--header", "X-A: 1"]);
    assert(ph.kind == Kind.profile && ph.flags.headers == [Header("X-A", "1")]);

    auto jobsVerb = parse(["cluster", "activate", "jobs"]);
    assert(jobsVerb.kind == Kind.invoke);
    assert(jobsVerb.command.operationId == "activateJobs");
}

/// Runtime extensions (#9): a cached spec becomes a namespace; the operator
/// gate hides and refuses operator-only operations without --operator.
unittest
{
    import d8ctl.extensions : extensionCommand, FetchFn, FetchResult;
    import d8ctl.profiles : Sources;
    import std.file : exists, rmdirRecurse, tempDir;
    import std.path : buildPath;
    import std.process : thisProcessID;
    import std.conv : to;

    auto dir = buildPath(tempDir, "d8ctl-parse-ext-" ~ thisProcessID.to!string);
    scope (exit)
        if (exists(dir)) rmdirRecurse(dir);

    // Install a tiny x-cli extension via a fake fetch (no network).
    static string body_;
    static FetchResult ff(string, string, string[string]) @safe
    {
        return FetchResult(body_, null, false);
    }
    body_ = `{"openapi":"3.0.3","info":{"title":"T","version":"1"},"servers":[{"url":"api"}],
      "paths": {
        "/status": {"get": {"operationId": "getStatus", "responses": {"200": {"description": "ok"}}}},
        "/things/{id}": {"get": {"operationId": "getThing",
            "x-cli": {"command": ["thing", "show"], "positional": ["id"]},
            "parameters": [{"name": "id", "in": "path", "required": true}],
            "responses": {"200": {"description": "ok"}}}},
        "/doors": {"post": {"operationId": "openDoor",
            "x-cli": {"command": ["door", "open"], "audience": "operator"},
            "responses": {"200": {"description": "ok"}}}},
        "/search": {"get": {"operationId": "searchThings",
            "x-cli": {"command": ["things", "search"], "positional": ["q"]},
            "parameters": [{"name": "q", "in": "query"}],
            "responses": {"200": {"description": "ok"}}}},
        "/notes/{id}": {"post": {"operationId": "addNote",
            "x-cli": {"command": ["note", "add"], "positional": ["id", "text"]},
            "parameters": [{"name": "id", "in": "path", "required": true}],
            "requestBody": {"required": true, "content": {"application/json": {"schema":
              {"type": "object", "required": ["text"], "properties": {"text": {"type": "string"}}}}}},
            "responses": {"200": {"description": "ok"}}}},
        "/runs/{id}/cancel": {"post": {"operationId": "cancelRun",
            "x-cli": {"command": ["pr", "run", "cancel"], "positional": ["id"],
              "aliases": [["cancel", "run"]]},
            "parameters": [{"name": "id", "in": "path", "required": true}],
            "responses": {"200": {"description": "ok"}}}}
      }}`;
    auto sources = Sources.init;
    extensionCommand(dir, sources, ["add", "t"], ["spec": "http://h/openapi.json"], null, &ff);

    // The namespace parses; both orders; x-cli naming and positional.
    auto st = parse(["t", "status", "get"], dir);
    assert(st.kind == Kind.invoke && st.extCatalog !is null);
    assert(st.command.operationId == "getStatus");
    auto th = parse(["t", "thing", "show", "42"], dir);
    assert(th.kind == Kind.invoke && th.command.operationId == "getThing");
    assert(th.positionals == ["42"]);
    // x-cli paths are matched as authored, never reordered (ADR 0068).
    assert(parse(["t", "show", "thing", "42"], dir).kind == Kind.error);
    // A 3-word path: groups `pr run`, leaf `cancel`; plus an alias path.
    auto cr = parse(["t", "pr", "run", "cancel", "9"], dir);
    assert(cr.kind == Kind.invoke && cr.command.operationId == "cancelRun");
    assert(cr.positionals == ["9"]);
    auto ca = parse(["t", "cancel", "run", "9"], dir);
    assert(ca.kind == Kind.invoke && ca.command.operationId == "cancelRun" && ca.positionals == ["9"]);
    assert(parse(["t", "run", "cancel", "9"], dir).kind == Kind.error);
    // Group prefixes show group help.
    auto grp = parse(["t", "pr", "run"], dir);
    assert(grp.kind == Kind.helpResource && grp.resource == "pr run");
    assert(parse(["t", "pr"], dir).kind == Kind.helpResource);
    {
        import d8ctl.help : resourceHelp, nsHelp;

        auto gh = resourceHelp("t", "pr run", grp.extCatalog, grp.extRows);
        assert(gh.indexOf("pr run cancel | cancel run") >= 0, gh);
        auto nh = nsHelp("t", Order.resource, grp.extCatalog, grp.extRows);
        assert(nh.indexOf("pr run cancel") >= 0, nh);
    }
    auto ch = parse(["t", "pr", "run", "cancel", "--help"], dir);
    assert(ch.kind == Kind.helpCommand && ch.command.operationId == "cancelRun");

    // Positionals bind query parameters and body fields too (x-cli.positional).
    {
        import camunda.runtime : Transport;
        import d8ctl.dispatch : invoke, UsageException;
        import std.exception : assertThrown;

        auto client = Transport.fromEnv(["CAMUNDA_AUTH_STRATEGY": "NONE",
            "CAMUNDA_REST_ADDRESS": "http://h/api", "CAMUNDA_REST_ADDRESS_EXACT": "true"]);
        auto sq = parse(["t", "things", "search", "foo", "--dry-run"], dir);
        auto dq = invoke(client, sq, null, "http://h/api");
        assert(dq.indexOf("GET http://h/api/search ?q=foo") >= 0, dq);
        auto na = parse(["t", "note", "add", "7", "hello", "--dry-run"], dir);
        auto dn = invoke(client, na, null, "http://h/api");
        assert(dn.indexOf("POST http://h/api/notes/7") >= 0 && dn.indexOf(`"text": "hello"`) >= 0, dn);
        auto both = parse(["t", "things", "search", "foo", "--q=bar", "--dry-run"], dir);
        assertThrown!UsageException(invoke(client, both, null, "http://h/api"));
    }

    // Operator-only: refused without --operator, allowed with it.
    auto door = parse(["t", "door", "open"], dir);
    assert(door.kind == Kind.error && door.message.indexOf("operator-only") >= 0);
    auto doorOp = parse(["t", "door", "open", "--operator"], dir);
    assert(doorOp.kind == Kind.invoke && doorOp.command.operationId == "openDoor");

    // Namespace help lists it; operator rows hidden unless --operator.
    assert(parse(["t"], dir).kind == Kind.helpNs);
    assert(parse(["t", "--operator"], dir).flags.operator);

    // Unknown namespace still errors; reserved name never parses as extension.
    assert(parse(["nope"], dir).kind == Kind.error);
    assert(parse(["cluster", "topology", "get"], dir).extCatalog is null);
}
