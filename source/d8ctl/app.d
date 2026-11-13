/// d8ctl — generated Camunda 8 Orchestration Cluster CLI (spike).
module d8ctl.app;

@safe:

import camunda.runtime;
import d8ctl.catalog : catalogOperationCount;
import d8ctl.version_ : cliVersion;
import d8ctl.dispatch;
import d8ctl.help;
import d8ctl.parse;
import d8ctl.safeio : stdErr, stdOut;

int run(string[] args)
{
    // args[0] is the program name.
    auto argv = args.length > 1 ? args[1 .. $] : (string[]).init;
    auto r = parse(argv);
    final switch (r.kind)
    {
    case Kind.helpRoot:
        stdOut.writeln(rootHelp());
        return 0;
    case Kind.helpNs:
        stdOut.writeln(nsHelp(r.ns, r.flags.order));
        return 0;
    case Kind.helpResource:
        stdOut.writeln(resourceHelp(r.ns, r.resource));
        return 0;
    case Kind.helpCommand:
        stdOut.writeln(commandHelp(r.command));
        return 0;
    case Kind.version_:
        stdOut.writeln(versionString);
        return 0;
    case Kind.error:
        stdErr.writeln("d8ctl: ", r.message);
        return 2;
    case Kind.invoke:
        try
        {
            auto client = Transport.fromEnv();
            client.userAgent = "d8ctl/" ~ cliVersion;
            auto out_ = invoke(client, r);
            if (out_.length) stdOut.write(out_);
            if (out_.length && out_[$ - 1] != '\n') stdOut.writeln();
            return 0;
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
