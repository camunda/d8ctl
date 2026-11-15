/// d8ctl — generated Camunda 8 Orchestration Cluster CLI (spike).
module d8ctl.app;

@safe:

import camunda.runtime;
import d8ctl.catalog : catalogOperationCount;
import d8ctl.extensions;
import d8ctl.version_ : cliVersion;
import d8ctl.dispatch;
import d8ctl.help;
import d8ctl.parse;
import d8ctl.profiles;
import d8ctl.safeio : stdErr, stdOut;

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
    {
        stdErr.writeln("d8ctl: ", e.msg);
        return 2;
    }
    final switch (r.kind)
    {
    case Kind.helpRoot:
        stdOut.writeln(rootHelp());
        return 0;
    case Kind.helpNs:
        stdOut.writeln(nsHelp(r.ns, r.flags.order, r.extCatalog, r.extRows, r.flags.operator));
        return 0;
    case Kind.helpResource:
        stdOut.writeln(resourceHelp(r.ns, r.resource, r.extCatalog, r.extRows, r.flags.operator));
        return 0;
    case Kind.helpCommand:
        stdOut.writeln(commandHelp(r.command));
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
        stdErr.writeln("d8ctl: ", r.message);
        return 2;
    case Kind.profile:
        try
        {
            stdOut.write(profileCommand(dirs, r.positionals, r.flags.config,
                r.flags.bare, configFromEnv(), r.flags.headers));
            return 0;
        }
        catch (ProfileException e)
        {
            stdErr.writeln("d8ctl: ", e.msg);
            return 2;
        }
    case Kind.extension:
        try
        {
            auto sources = loadSources(dirs);
            foreach (w; sources.warnings) stdErr.writeln("d8ctl: warning: ", w);
            stdOut.write(extensionCommand(dirs.d8ctl, sources, r.positionals,
                r.flags.named, r.flags.bare, &fetchSpecHttp, r.flags.profile,
                r.flags.config, r.flags.headers));
            return 0;
        }
        catch (ExtensionException e)
        {
            stdErr.writeln("d8ctl: ", e.msg);
            return 2;
        }
        catch (ProfileException e)
        {
            stdErr.writeln("d8ctl: ", e.msg);
            return 2;
        }
    case Kind.invoke:
        try
        {
            import std.process : environment;

            auto sources = loadSources(dirs);
            foreach (w; sources.warnings) stdErr.writeln("d8ctl: warning: ", w);
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
            auto out_ = invoke(client, r, previewHeaders);
            if (out_.length) stdOut.write(out_);
            if (out_.length && out_[$ - 1] != '\n') stdOut.writeln();
            return 0;
        }
        catch (ProfileException e)
        {
            stdErr.writeln("d8ctl: ", e.msg);
            return 2;
        }
        catch (ExtensionException e)
        {
            stdErr.writeln("d8ctl: ", e.msg);
            return 2;
        }
        catch (UsageException e)
        {
            stdErr.writeln("d8ctl: ", e.msg);
            return 2;
        }
        catch (CamundaException e)
        {
            stdErr.writeln("d8ctl: ", e.msg);
            return 1;
        }
    }
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
    auto out_ = invoke(client, r, previewHeaders, base);
    if (out_.length) stdOut.write(out_);
    if (out_.length && out_[$ - 1] != '\n') stdOut.writeln();
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
    assert(catalogOperationCount > 200); // moves with the upstream spec
}
