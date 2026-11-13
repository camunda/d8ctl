/// Look up generated commands. Order of resource/verb is a parser concern.
module d8ctl.catalog;

@safe:

import d8ctl.generated.catalog;
import d8ctl.util : eqIgnoreCase;

import std.algorithm : canFind, sort, uniq;
import std.array : array;

public import d8ctl.generated.catalog : BodyField, Command, catalog, catalogOperationCount, catalogSpecHash;

const(Command)* findExact(string ns, string resource, string verb)
{
    foreach (i, ref c; catalog)
    {
        if (eqIgnoreCase(c.namespace, ns)
            && eqIgnoreCase(c.resource, resource)
            && eqIgnoreCase(c.verb, verb))
            return &catalog[i];
    }
    return null;
}

const(Command)* findByOperationId(string operationId)
{
    foreach (i, ref c; catalog)
        if (c.operationId == operationId) return &catalog[i];
    return null;
}

string[] namespaces()
{
    string[] names;
    foreach (ref c; catalog)
        names ~= c.namespace.dup;
    names.sort();
    return names.uniq.array;
}

string[] resourcesIn(string ns)
{
    string[] names;
    foreach (ref c; catalog)
        if (eqIgnoreCase(c.namespace, ns)) names ~= c.resource.dup;
    names.sort();
    return names.uniq.array;
}

const(Command)[] commandsIn(string ns)
{
    const(Command)[] out_;
    foreach (ref c; catalog)
        if (eqIgnoreCase(c.namespace, ns)) out_ ~= c;
    return out_;
}

const(Command)[] commandsFor(string ns, string resource)
{
    const(Command)[] out_;
    foreach (ref c; catalog)
        if (eqIgnoreCase(c.namespace, ns) && eqIgnoreCase(c.resource, resource))
            out_ ~= c;
    return out_;
}

bool isNamespace(string s)
{
    foreach (n; namespaces())
        if (eqIgnoreCase(n, s)) return true;
    return false;
}

bool isVerb(string s)
{
    foreach (ref c; catalog)
        if (eqIgnoreCase(c.verb, s)) return true;
    return false;
}

unittest
{
    assert(catalogOperationCount == 244);
    assert(findByOperationId("getTopology") !is null);
    auto t = findByOperationId("getTopology");
    assert(t.namespace == "cluster");
    assert(t.resource == "topology");
    assert(t.verb == "get");
    assert(t.kind == "json");
    assert(!t.hasBody);
    assert(t.bodyFields.length == 0);
    auto fail = findByOperationId("failJob");
    assert(fail !is null);
    assert(fail.hasBody);
    assert(fail.bodyFields.length > 0);
    assert(findExact("cluster", "topology", "get") is t);
    assert(isNamespace("cluster"));
    assert(isVerb("get"));
    assert(resourcesIn("cluster").canFind("topology"));
}
