/// Look up generated commands. Order of resource/verb is a parser concern.
///
/// Every lookup takes an optional overlay catalog (a runtime extension's
/// model, #9); when set, it replaces the built-in table. Operator-audience
/// rows are invisible unless `includeOperator` — help and completion hide
/// them, and the parser refuses them without `--operator`.
module d8ctl.catalog;

@safe:

import d8ctl.generated.catalog;
import d8ctl.specmodel : Catalog, ModelCommand;
import d8ctl.util : eqIgnoreCase;

import std.algorithm : canFind, sort, uniq;
import std.array : array;

public import d8ctl.generated.catalog : BodyField, Command, catalog, catalogOperationCount, catalogSpecHash;

/// Copy a model row into a `Command` (the generated table's row type).
Command toCommand(const ref ModelCommand c)
{
    Command r;
    r.operationId = c.operationId;
    r.namespace = c.namespace;
    r.resource = c.resource;
    r.verb = c.verb;
    r.method = c.method;
    r.path = c.path;
    r.summary = c.summary;
    r.addedInVersion = c.addedInVersion;
    r.kind = c.kind;
    r.hasBody = c.hasBody;
    r.pathParams = c.pathParams.dup;
    r.requiredQuery = c.requiredQuery.dup;
    r.optionalQuery = c.optionalQuery.dup;
    foreach (f; c.bodyFields)
        r.bodyFields ~= BodyField(f.name, f.kind, f.required, f.doc);
    r.rootServer = c.rootServer;
    r.operatorOnly = c.operatorOnly;
    r.positional = c.positional.dup;
    return r;
}

/// A runtime extension's commands as a `Command` table (owned by the caller).
Command[] overlayRows(const(Catalog)* overlay)
{
    Command[] rows;
    if (overlay is null)
        return rows;
    foreach (ref c; overlay.commands)
        rows ~= toCommand(c);
    return rows;
}

private const(Command)[] rowsOf(const(Catalog)* overlay, const(Command)[] overlayRows_)
{
    return overlay is null ? catalog : overlayRows_;
}

const(Command)* findExact(string ns, string resource, string verb,
    const(Catalog)* overlay = null, const(Command)[] overlayRows_ = null,
    bool includeOperator = false)
{
    if (overlay !is null)
    {
        // The overlay's own rows are the table (and stay alive via the Result).
        foreach (i, ref c; overlayRows_)
        {
            if (eqIgnoreCase(c.namespace, ns)
                && eqIgnoreCase(c.resource, resource)
                && eqIgnoreCase(c.verb, verb))
            {
                if (!includeOperator && c.operatorOnly)
                    return null;
                return &overlayRows_[i];
            }
        }
        return null;
    }
    foreach (i, ref c; catalog)
        if (eqIgnoreCase(c.namespace, ns)
            && eqIgnoreCase(c.resource, resource)
            && eqIgnoreCase(c.verb, verb))
            return &catalog[i];
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

string[] resourcesIn(string ns, const(Catalog)* overlay = null,
    const(Command)[] overlayRows_ = null, bool includeOperator = false)
{
    string[] names;
    foreach (ref c; rowsOf(overlay, overlayRows_))
        if (eqIgnoreCase(c.namespace, ns) && (overlay is null || includeOperator || !c.operatorOnly))
            names ~= c.resource.dup;
    names.sort();
    return names.uniq.array;
}

const(Command)[] commandsIn(string ns, const(Catalog)* overlay = null,
    const(Command)[] overlayRows_ = null, bool includeOperator = false)
{
    const(Command)[] out_;
    foreach (ref c; rowsOf(overlay, overlayRows_))
        if (eqIgnoreCase(c.namespace, ns) && (overlay is null || includeOperator || !c.operatorOnly))
            out_ ~= c;
    return out_;
}

const(Command)[] commandsFor(string ns, string resource, const(Catalog)* overlay = null,
    const(Command)[] overlayRows_ = null, bool includeOperator = false)
{
    const(Command)[] out_;
    foreach (ref c; rowsOf(overlay, overlayRows_))
        if (eqIgnoreCase(c.namespace, ns) && eqIgnoreCase(c.resource, resource)
            && (overlay is null || includeOperator || !c.operatorOnly))
            out_ ~= c;
    return out_;
}

bool isNamespace(string s)
{
    foreach (n; namespaces())
        if (eqIgnoreCase(n, s)) return true;
    return false;
}

bool isVerb(string s, const(Catalog)* overlay = null, const(Command)[] overlayRows_ = null)
{
    foreach (ref c; rowsOf(overlay, overlayRows_))
        if (eqIgnoreCase(c.verb, s)) return true;
    return false;
}

unittest
{
    assert(catalogOperationCount > 200); // moves with the upstream spec
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
    assert(resourcesIn("cluster").canFind("jobs"));
    assert(findExact("cluster", "jobs", "activate") !is null);
    assert(findExact("job", "jobs", "activate") is null);
}

unittest
{
    // Overlay catalogs (runtime extensions): lookups walk the overlay, and
    // operator-only rows are hidden unless asked for.
    import d8ctl.specmodel : buildCatalog;

    auto cat = buildCatalog(`{"paths": {
        "/status": {"get": {"operationId": "getStatus", "responses": {"200": {"description": "ok"}}}},
        "/doors": {"post": {"operationId": "openDoor",
            "x-cli": {"command": "door open", "audience": "operator"},
            "responses": {"200": {"description": "ok"}}}}}}`, null, "t");
    auto overlay = new Catalog;
    *overlay = cat;
    auto rows = overlayRows(overlay);
    assert(rows.length == 2);
    assert(rows[0].namespace == "t" && rows[0].resource == "status" && rows[0].verb == "get");
    assert(!rows[0].operatorOnly);
    assert(rows[1].resource == "door" && rows[1].verb == "open" && rows[1].operatorOnly);
    auto sg = findExact("t", "status", "get", overlay, rows);
    assert(sg !is null, "status get not found");
    assert(sg.operationId == "getStatus");
    // The reverse order is a different (nonexistent) command.
    assert(findExact("t", "get", "status", overlay, rows) is null);
    assert(findExact("t", "door", "open", overlay, rows) is null); // operator-only hidden
    assert(findExact("t", "door", "open", overlay, rows, true) !is null);
    assert(commandsIn("t", overlay, rows).length == 1);
    assert(commandsIn("t", overlay, rows, true).length == 2);
    assert(!resourcesIn("t", overlay, rows).canFind("door"));
    assert(resourcesIn("t", overlay, rows, true).canFind("door"));
    assert(isVerb("open", overlay, rows));
    assert(!isVerb("open"));
}
