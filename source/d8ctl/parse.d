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

import d8ctl.profiles : Header, parseHeaderSwitch, ProfileException, switchToKey;
import d8ctl.catalog;
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
    Order order = Order.resource;
    string[string] named;
    string bodyJson;
    /// `--profile=<name>`.
    string profile;
    /// `--camunda-<key>=<value>` switches, keyed by SDK config key.
    string[string] config;
    /// `--header 'Name: value'` (repeatable), in argv order.
    Header[] headers;
    /// Value-less `--flag`s. Only `profile` subcommands accept them.
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
    Flags flags;
    string[] positionals;
}

Result parse(string[] args)
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

    // Value-less flags are only meaningful to `profile` subcommands.
    foreach (k, _; flags.bare)
    {
        r.kind = Kind.error;
        r.message = "flag --" ~ k ~ " needs a value (--" ~ k ~ "=…)";
        return r;
    }

    if (!isNamespace(pos[0]))
    {
        r.kind = Kind.error;
        r.message = "unknown namespace '" ~ pos[0] ~ "'. See `d8ctl --help`.";
        return r;
    }
    r.ns = pos[0];

    if (pos.length == 1)
    {
        r.kind = Kind.helpNs;
        return r;
    }

    auto a = pos[1];
    string b = pos.length > 2 ? pos[2] : null;

    // Prefer the order that actually matches a command.
    const(Command)* cmd;
    if (b.length)
    {
        cmd = findExact(r.ns, a, b);
        if (cmd !is null)
        {
            r.resource = a;
            r.verb = b;
        }
        else
        {
            cmd = findExact(r.ns, b, a);
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
        auto res = commandsFor(r.ns, a);
        if (res.length)
        {
            r.resource = a;
            r.kind = flags.help ? Kind.helpResource : Kind.helpResource;
            return r;
        }
        // `d8ctl cluster get` — verb help (list resources that accept get).
        if (isVerb(a))
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
