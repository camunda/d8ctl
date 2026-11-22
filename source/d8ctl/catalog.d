/// Look up generated commands. Order of resource/verb is a parser concern.
///
/// Every lookup takes an optional overlay catalog (a runtime extension's
/// model, #9); when set, it replaces the built-in table. Operator-audience
/// rows are invisible unless `includeOperator` — help and completion hide
/// them, and the parser refuses them without `--operator`.
module d8ctl.catalog;

@safe:

import d8ctl.generated.catalog;
import d8ctl.specmodel : Catalog, ModelCommand, ModelResponseField;
import d8ctl.util : eqIgnoreCase;

import std.algorithm : canFind, map, sort, uniq;
import std.array : array;

public import d8ctl.generated.catalog : BodyField, BodyVariant, Command, ResponseField, catalog, catalogOperationCount, catalogSpecHash;

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
        r.bodyFields ~= BodyField(f.name, f.kind, f.required, f.doc, f.values.dup);
    r.rootServer = c.rootServer;
    r.operatorOnly = c.operatorOnly;
    r.positional = c.positional.dup;
    foreach (p; c.paths)
        r.paths ~= p.dup;
    r.responseTarget = c.responseTarget;
    r.selection = c.selection;
    foreach (f; c.responseFields)
        r.responseFields ~= toResponseField(f);
    foreach (v; c.variants)
        r.variants ~= BodyVariant(v.name, v.required.dup);
    return r;
}

private ResponseField toResponseField(const ref ModelResponseField f)
{
    ResponseField r;
    r.name = f.name;
    r.kind = f.kind;
    foreach (ref ch; f.children)
        r.children ~= toResponseField(ch);
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
            if (!c.paths.length && eqIgnoreCase(c.namespace, ns)
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

/// Longest explicit `x-cli` command path that prefixes `words`, with the
/// number of words it consumed. Words are matched exactly as authored —
/// never reordered (nano-ide ADR 0068).
const(Command)* findPath(const(Command)[] rows, const(string)[] words,
    out size_t consumed, bool includeOperator = false)
{
    const(Command)* best;
    foreach (i, ref c; rows)
    {
        if (!includeOperator && c.operatorOnly)
            continue;
        foreach (p; c.paths)
        {
            if (p.length > words.length || p.length <= consumed)
                continue;
            bool ok = true;
            foreach (j, w; p)
                if (!eqIgnoreCase(w, words[j]))
                    ok = false;
            if (ok)
            {
                best = &rows[i];
                consumed = p.length;
            }
        }
    }
    return best;
}

/// Leaf commands whose explicit path starts with group `words` (strictly longer).
const(Command)[] commandsUnderPath(const(Command)[] rows, const(string)[] words,
    bool includeOperator = false)
{
    const(Command)[] out_;
    foreach (ref c; rows)
    {
        if (!includeOperator && c.operatorOnly)
            continue;
        foreach (p; c.paths)
        {
            if (p.length <= words.length)
                continue;
            bool ok = true;
            foreach (j, w; words)
                if (!eqIgnoreCase(w, p[j]))
                    ok = false;
            if (ok)
            {
                out_ ~= c;
                break;
            }
        }
    }
    return out_;
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
        if (!c.paths.length && eqIgnoreCase(c.namespace, ns)
            && (overlay is null || includeOperator || !c.operatorOnly))
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
        if (!c.paths.length && eqIgnoreCase(c.namespace, ns) && eqIgnoreCase(c.resource, resource)
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
        if (!c.paths.length && eqIgnoreCase(c.verb, s)) return true;
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
            "x-cli": {"command": ["door", "open"], "audience": "operator"},
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
    // x-cli rows are reached only by their exact path, never resource/verb.
    assert(rows[1].paths == [["door", "open"]]);
    assert(findExact("t", "door", "open", overlay, rows, true) is null);
    size_t used;
    assert(findPath(rows, ["door", "open"], used) is null); // operator-only hidden
    assert(findPath(rows, ["door", "open", "x"], used, true) !is null && used == 2);
    assert(findPath(rows, ["open", "door"], used, true) is null); // never reordered
    assert(commandsIn("t", overlay, rows).length == 1);
    assert(commandsIn("t", overlay, rows, true).length == 2);
    assert(commandsUnderPath(rows, ["door"], true).length == 1);
    assert(commandsUnderPath(rows, ["door"]).length == 0);
    assert(isVerb("get", overlay, rows));
    assert(!isVerb("open", overlay, rows));
}

/// `--fields` model in the generated catalog (#21): searchProcessInstances
/// targets `items`; an nwf-like spec with two arrays requires a prefix.
unittest
{
    auto search = findByOperationId("searchProcessInstances");
    assert(search !is null);
    assert(search.responseTarget == "items");
    assert(search.selection == "items");
    // The envelope's fields are selectable; the array's children are the item
    // fields.
    string[] names;
    foreach (f; search.responseFields)
        names ~= f.name;
    import std.conv : to;

    assert(names.canFind("items") && names.canFind("page"), names.to!string);
    // The array's children are the item fields.
    string[] itemNames;
    foreach (f; search.responseFields)
        if (f.name == "items")
            foreach (ch; f.children)
                itemNames ~= ch.name;
    assert(itemNames.canFind("processInstanceKey"), itemNames.to!string);
    assert(itemNames.canFind("processDefinitionId"));
    assert(itemNames.canFind("startDate"));
    // The envelope's `page` object validates its own dotted children.
    string[] pageNames;
    foreach (f; search.responseFields)
        if (f.name == "page")
            foreach (ch; f.children)
                pageNames ~= ch.name;
    assert(pageNames.canFind("totalItems"), pageNames.to!string);

    // getTopology's envelope has one array of objects (brokers) plus scalars:
    // the items target trims the brokers.
    auto topo = findByOperationId("getTopology");
    assert(topo.responseTarget == "items");
    assert(topo.selection == "brokers");
    // …and the whole-cluster topology has two arrays of objects: multi.
    auto clusterTopo = findByOperationId("getClusterTopology");
    assert(clusterTopo.responseTarget == "multi");
    assert(clusterTopo.responseFields.map!(f => f.name).array.canFind("brokers"));

    // An nwf-like spec: `prs` + `deliveries` arrays → multi, prefix required.
    import d8ctl.specmodel : buildCatalog;

    auto cat = buildCatalog(`{"paths": {"/status": {"get": {"operationId": "getStatus",
        "responses": {"200": {"description": "ok", "content": {"application/json":
          {"schema": {"type": "object", "properties": {
            "prs": {"type": "array", "items": {"type": "object", "properties": {
              "prKey": {"type": "string"}, "status": {"type": "string"}}}},
            "deliveries": {"type": "array", "items": {"type": "object", "properties": {
              "id": {"type": "string"}}}}}}}}}}}}}}`, null, "nwf");
    assert(cat.commands[0].responseTarget == "multi");
    auto overlay = new Catalog;
    *overlay = cat;
    auto rows = overlayRows(overlay);
    assert(rows[0].responseTarget == "multi", "extensions carry the model");
    assert(rows[0].responseFields.length == 2
        && rows[0].responseFields[0].children.map!(f => f.name).array == ["prKey", "status"]);
}
