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

import d8ctl.catalog;
import d8ctl.util : eqIgnoreCase;
import std.algorithm : startsWith;
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
}

enum Kind
{
    helpRoot,
    helpNs,
    helpResource,
    helpCommand,
    version_,
    invoke,
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
        if (a.startsWith("--") && a.length > 2)
        {
            auto rest = a[2 .. $];
            auto eq = rest.indexOf('=');
            if (eq < 0)
            {
                r.kind = Kind.error;
                r.message = "flag --" ~ rest ~ " needs a value (--" ~ rest ~ "=…)";
                return r;
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
}
