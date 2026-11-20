/// d8ctl — generated Camunda 8 Orchestration Cluster CLI (spike).
module d8ctl.app;

@safe:

import camunda.runtime;
import d8ctl.catalog : Command, catalogOperationCount, commandsFor, commandsIn, commandsUnderPath, namespaces;
import d8ctl.extensions;
import d8ctl.version_ : cliVersion;
import d8ctl.dispatch;
import d8ctl.help;
import d8ctl.parse;
import d8ctl.output;
import d8ctl.profiles;
import d8ctl.safeio : isTerminal, stdErr, stdOut;

int run(string[] args)
{
    return run(args, defaultDirs());
}

/// `run` against explicit profile/config dirs (tests pass a temp dir).
int run(string[] args, Dirs dirs)
{
    // args[0] is the program name.
    auto argv = args.length > 1 ? args[1 .. $] : (string[]).init;
    Result r;
    try
        r = parse(argv, dirs.d8ctl);
    catch (ExtensionException e)
        return fail(r, Failure(ErrorKind.config, e.msg));
    final switch (r.kind)
    {
    case Kind.helpRoot:
        if (r.flags.json)
        {
            const(Command)[] all;
            foreach (ns; namespaces()) all ~= commandsIn(ns);
            stdOut.writeln(commandsHelpJson(all));
        }
        else
            stdOut.writeln(rootHelp());
        return 0;
    case Kind.helpNs:
        if (r.flags.json)
            stdOut.writeln(commandsHelpJson(commandsIn(r.ns, r.extCatalog, r.extRows, r.flags.operator)));
        else
            stdOut.writeln(nsHelp(r.ns, r.flags.order, r.extCatalog, r.extRows, r.flags.operator));
        return 0;
    case Kind.helpResource:
        if (r.flags.json)
        {
            import std.array : split;

            auto cmds = commandsFor(r.ns, r.resource, r.extCatalog, r.extRows, r.flags.operator);
            if (!cmds.length && r.extCatalog !is null) // an x-cli command group
                cmds = commandsUnderPath(r.extRows, r.resource.split(" "), r.flags.operator);
            stdOut.writeln(commandsHelpJson(cmds));
        }
        else
            stdOut.writeln(resourceHelp(r.ns, r.resource, r.extCatalog, r.extRows, r.flags.operator));
        return 0;
    case Kind.helpCommand:
        {
            // An x-cli command that is also a group lists what is under it.
            const(Command)[] subs;
            if (r.extCatalog !is null && r.command.paths.length)
                subs = commandsUnderPath(r.extRows, r.command.paths[0], r.flags.operator);
            if (r.flags.json)
                stdOut.writeln(commandHelpJson(r.command, subs));
            else
                stdOut.writeln(commandHelp(r.command) ~ subcommandsText(subs));
        }
        return 0;
    case Kind.version_:
        stdOut.writeln(versionString);
        return 0;
    case Kind.helpProfile:
        stdOut.writeln(profileHelp());
        return 0;
    case Kind.helpExtension:
        stdOut.writeln(extensionHelp());
        return 0;
    case Kind.error:
        return fail(r, Failure(ErrorKind.usage, r.message));
    case Kind.profile:
        try
        {
            stdOut.write(profileCommand(dirs, r.positionals, r.flags.config,
                r.flags.bare, configFromEnv(), r.flags.headers));
            return 0;
        }
        catch (Exception e)
            return fail(r, classify(e, null));
    case Kind.extension:
        try
        {
            auto sources = loadSources(dirs);
            foreach (w; sources.warnings) warn(r, w);
            stdOut.write(extensionCommand(dirs.d8ctl, sources, r.positionals,
                r.flags.named, r.flags.bare, &fetchSpecHttp, r.flags.profile,
                r.flags.config, r.flags.headers));
            return 0;
        }
        catch (Exception e)
            return fail(r, classify(e, null));
    case Kind.invoke:
        try
        {
            import std.process : environment;

            auto sources = loadSources(dirs);
            foreach (w; sources.warnings) warn(r, w);
            if (r.extCatalog !is null)
                return invokeExtension(dirs, sources, r);
            auto conn = resolveConnection(sources, r.flags.profile,
                environment.get("D8CTL_PROFILE"), r.flags.config,
                (string k) => environment.get(k), r.flags.headers);
            auto client = Transport.fromEnv(conn.overrides);
            client.userAgent = "d8ctl/" ~ cliVersion;
            // Dry-run preview: env-only CAMUNDA_DEFAULT_HEADERS never enter
            // conn.overrides (resolveConnection leaves them to the SDK), but
            // Transport.fromEnv still sends them — show them either way.
            auto previewHeaders = conn.overrides.get(headersKey,
                environment.get(headersKey, null));
            writeResult(invoke(client, r, previewHeaders, null, prettyJson(r)));
            return 0;
        }
        catch (Exception e)
            return fail(r, classify(e, r.command is null ? null : r.command.operationId));
    }
}

// ---- Output contract (#16; see d8ctl.output) ----

/// Pretty JSON on stdout: `--pretty`, or a terminal unless `--compact`.
private bool prettyJson(const ref Result r)
{
    if (r.flags.pretty) return true;
    if (r.flags.compact) return false;
    return isTerminal(stdOut);
}

/// JSON errors: `--output=json`, or stderr is not a terminal unless `--output=text`.
private bool jsonErrors(const ref Result r)
{
    if (r.flags.errorFormat == ErrorFormat.json) return true;
    if (r.flags.errorFormat == ErrorFormat.text) return false;
    return !isTerminal(stdErr);
}

/// Write `f` to stderr in the chosen format; its exit code.
private int fail(const ref Result r, Failure f)
{
    stdErr.writeln(jsonErrors(r) ? errorJson(f) : errorText(f));
    return exitCode(f.kind);
}

/// A non-fatal warning: `{"warning":"…"}` or `d8ctl: warning: …`.
private void warn(const ref Result r, string message)
{
    import std.json : JSONOptions, JSONValue;

    if (jsonErrors(r))
    {
        JSONValue w = ["warning": message];
        stdErr.writeln(w.toString(JSONOptions.doNotEscapeSlashes));
    }
    else
        stdErr.writeln("d8ctl: warning: ", message);
}

private void writeResult(string out_)
{
    if (out_.length) stdOut.write(out_);
    if (out_.length && out_[$ - 1] != '\n') stdOut.writeln();
}

/// The failure for an exception from parsing, config or a request.
Failure classify(Exception e, string operation)
{
    Failure f;
    f.message = e.msg;
    f.operation = operation;
    if (auto api = cast(ApiException) e)
    {
        f.kind = kindOfStatus(api.status);
        f.status = api.status;
        f.body_ = api.body_;
    }
    else if (cast(UsageException) e || cast(ValidationException) e)
        f.kind = ErrorKind.usage;
    else if (cast(ProfileException) e || cast(ExtensionException) e || cast(ConfigException) e)
        f.kind = ErrorKind.config;
    else if (cast(AuthException) e)
        f.kind = ErrorKind.auth;
    else if (cast(NetworkException) e)
        f.kind = ErrorKind.network;
    else if (cast(BackpressureException) e)
        f.kind = ErrorKind.server;
    else
        f.kind = ErrorKind.other;
    return f;
}

/// Run one extension command against its own base URL. The profile (the
/// manifest's default or `--profile`) supplies only auth and headers — never
/// its cluster address; `--camunda-*` switches and `--header` apply on top.
/// With no profile, requests send no auth and no ambient default headers.
/// The manifest is the snapshot parsed with the command model (one cache
/// generation): an update between parse and invoke never pairs an old model
/// with a new base URL or profile.
private int invokeExtension(Dirs dirs, const ref Sources sources, const ref Result r)
{
    Manifest m;
    if (r.extManifest !is null)
        m = *r.extManifest;
    else
        m = readManifest(dirs.d8ctl, r.ns); // defensive: parse always sets it
    auto profileName = r.flags.profile.length ? r.flags.profile : m.profile;
    // Root-server operations go to the bare origin, not the spec's
    // top-level server path (which need not end in the SDK's `/v2`).
    auto base = r.command !is null && r.command.rootServer ? originOf(m.baseUrl) : m.baseUrl;
    auto overrides = extensionConnection(sources, profileName, r.flags.config,
        r.flags.headers, base);
    auto client = extensionTransport(overrides);
    client.userAgent = "d8ctl/" ~ cliVersion;
    auto previewHeaders = overrides.get(headersKey, null);
    writeResult(invoke(client, r, previewHeaders, base, prettyJson(r)));
    return 0;
}

unittest
{
    assert(run(["d8ctl", "--version"]) == 0);
    assert(run(["d8ctl", "--help"]) == 0);
    assert(run(["d8ctl", "cluster"]) == 0);
    assert(run(["d8ctl", "cluster", "topology"]) == 0);
    assert(run(["d8ctl", "cluster", "topology", "get", "--help"]) == 0);
    assert(run(["d8ctl", "nope"]) == 2);
    // Output contract (#16).
    assert(run(["d8ctl", "cluster", "topology", "get", "--help", "--json"]) == 0);
    assert(run(["d8ctl", "cluster", "topology", "--help", "--json"]) == 0);
    assert(run(["d8ctl", "cluster", "topology", "get", "--pretty", "--compact"]) == 2);
    assert(run(["d8ctl", "cluster", "topology", "get", "--output=yaml"]) == 2);
    assert(run(["d8ctl", "cluster", "topology", "get", "--output"]) == 2);
    assert(catalogOperationCount > 200); // moves with the upstream spec
}
