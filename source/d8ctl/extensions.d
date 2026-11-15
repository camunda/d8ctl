/// Runtime extensions: extra CLI namespaces generated at install time from a
/// running server's OpenAPI spec (d8ctl#9; first target: Nano Workforce).
///
/// `d8ctl extension add nwf --spec <url> [--profile merlin]` downloads the
/// spec, builds the command model with the same `specmodel` code path as the
/// built-in `cluster` catalog, and caches both under
/// `<configDir()>/extensions/<name>/` (`spec.json` byte for byte, plus an
/// `extension.json` manifest). Ordinary `d8ctl <name> …` commands read only
/// the cache — never the network. `extension update` re-downloads (skipping
/// on a matching sha256), `extension list [--check]` reports freshness, and
/// `extension remove` deletes the cache.
///
/// Naming: `x-cli.command` when the spec carries it (nano-ide#617), else the
/// operationId split. Operator-audience operations are hidden unless
/// `--operator`; `x-cli.exclude` removes them entirely.
module d8ctl.extensions;

@safe:

import camunda.openapi : J, Kind, OpenApiException, get, itemsOf, keysOf, orS, parseJson, truthy;
import camunda.runtime : Transport;
import d8ctl.dispatch : UsageException;
import d8ctl.profiles
    : Header, ProfileException, Sources, configDir, findProfile, headersKey, headersToJson,
    mergeHeaders, validateHeaders;
import d8ctl.safeio : sha256Hex;
import d8ctl.specmodel : Catalog, ModelCommand, buildCatalog, kebab;

import std.algorithm : canFind, sort;
import std.array : appender, replace;
import std.conv : to;
import std.json : JSONType, JSONValue, parseJSON;
import std.string : endsWith, indexOf, join, startsWith, strip, toLower;

/// Bad extension command, invalid name/spec, or unknown extension (exit 2).
class ExtensionException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow @nogc @safe
    {
        super(msg, file, line);
    }
}

/// The manifest: `<configDir>/extensions/<name>/extension.json`.
struct Manifest
{
    string name;
    string specUrl;
    string baseUrl;
    /// `baseUrl` came from the spec's `servers` (refreshed by `update`),
    /// not from `--base-url` (kept as given).
    bool baseUrlFromSpec;
    string profile;
    string sha256;
    string etag;
    string fetchedAt;
    string d8ctlVersion;
}

/// An installed extension: manifest plus the model built from its cached spec.
struct Extension
{
    Manifest manifest;
    Catalog catalog;
}

/// `^[a-z][a-z0-9-]{0,31}$`.
bool isValidExtensionName(string name) pure
{
    if (name.length < 1 || name.length > 32)
        return false;
    if (name[0] < 'a' || name[0] > 'z')
        return false;
    foreach (ch; name[1 .. $])
        if (!((ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9') || ch == '-'))
            return false;
    return true;
}

/// Names an extension may not take: built-in namespaces and top-level words.
immutable string[] RESERVED_NAMES = [
    "cluster", "extension", "extensions", "profile", "profiles",
    "help", "version", "completion",
    // `<verb> profile…` is rewritten to profile management before namespaces
    // are looked up (parse.d), so these would be shadowed.
    "list", "show", "add", "use", "remove", "rm", "delete",
];

void requireExtensionName(string name)
{
    if (!isValidExtensionName(name))
        throw new ExtensionException("invalid extension name '" ~ name
            ~ "' (want ^[a-z][a-z0-9-]{0,31}$)");
    if (RESERVED_NAMES.canFind(name))
        throw new ExtensionException("extension name '" ~ name ~ "' is reserved");
}

string extensionsRoot(string cfgDir)
{
    import std.path : buildPath;

    return buildPath(cfgDir, "extensions");
}

string extensionDir(string cfgDir, string name)
{
    import std.path : buildPath;

    return buildPath(extensionsRoot(cfgDir), name);
}

/// The directory holding the current cache generation of `name`, read once
/// from its atomically replaced `current` pointer. Readers that need both
/// files take this once and read both from it, so they never mix an old
/// manifest with a new spec. (A pointer-less directory is read in place.)
string generationDir(string cfgDir, string name)
{
    import std.file : exists, readText;
    import std.path : baseName, buildPath;
    import std.string : strip;

    auto dir = extensionDir(cfgDir, name);
    auto ptr = buildPath(dir, "current");
    if (!exists(ptr))
        return dir;
    string gen;
    try
        gen = readText(ptr).strip;
    catch (Exception e)
        throw new ExtensionException(ptr ~ " is unreadable: " ~ e.msg);
    if (!gen.length || gen != baseName(gen) || gen[0] == '.')
        throw new ExtensionException(ptr ~ " does not name a cache generation");
    return buildPath(dir, gen);
}

string specPath(string cfgDir, string name)
{
    import std.path : buildPath;

    return buildPath(generationDir(cfgDir, name), "spec.json");
}

string manifestPath(string cfgDir, string name)
{
    import std.path : buildPath;

    return buildPath(generationDir(cfgDir, name), "extension.json");
}

/// Installed extension names, sorted.
string[] listExtensionNames(string cfgDir)
{
    import std.file : DirEntry, exists, isDir, dirEntries, SpanMode;
    import std.path : baseName;

    string[] names;
    auto root = extensionsRoot(cfgDir);
    if (!exists(root))
        return names;
    foreach (DirEntry e; dirEntries(root, SpanMode.shallow))
        if (e.isDir && isValidExtensionName(baseName(e.name)))
            names ~= baseName(e.name);
    names.sort();
    return names;
}

/// The spec's `servers[0].url` resolved against the spec URL (server
/// variables take their defaults). For nwf, `<app>/api-docs/openapi.json`
/// plus `api` gives `<app>/api`: a bare relative name resolves against the
/// spec's parent directory (the app root), not the docs directory.
string resolveBaseUrl(string specJson, string specUrl)
{
    auto spec = parseJson(specJson);
    auto list = itemsOf(spec.get("servers"));
    if (!list.length)
        throw new ExtensionException("the spec declares no servers; pass --base-url=<url>");
    auto raw = list[0].get("url").orS("");
    if (!raw.length)
        throw new ExtensionException("the spec's servers[0].url is empty; pass --base-url=<url>");
    // Server variables: substitute each `{var}` with its declared default.
    if (auto vars = list[0].get("variables"))
        foreach (k; keysOf(vars))
        {
            auto d = vars.fields[k].get("default").orS("");
            raw = raw.replace("{" ~ k ~ "}", d);
        }
    if (raw.indexOf("://") >= 0)
        return stripRightSlash(raw); // absolute
    if (raw.startsWith("/"))
        return joinUrl(stripRightSlash(baseOf(specUrl)), raw); // root-relative
    // Bare name (e.g. nwf's `api`): resolve against the spec's parent dir.
    return joinUrl(stripRightSlash(baseOf(baseOf(specUrl))), raw);
}

private string stripRightSlash(string s)
{
    while (s.endsWith("/"))
        s = s[0 .. $ - 1];
    return s;
}

/// `http://host/dir/openapi.json` → `http://host/dir` (the "directory" of the
/// URL, per RFC 3986 relative resolution). Never strips into the authority:
/// `http://host/openapi.json` → `http://host`, and `http://host` stays.
string baseOf(string url)
{
    import std.string : lastIndexOf;

    auto end = url.length;
    foreach (c; ['?', '#'])
    {
        auto i = url.lastIndexOf(c);
        if (i >= 0 && i < end)
            end = i;
    }
    auto s = url[0 .. end].lastIndexOf('/');
    if (s < 0)
        return url;
    // Don't strip into the authority: in `scheme://host/…`, the path slash is
    // the first slash after schemeSep+2. `scheme://host` (no path) stays whole.
    const schemeSep = url.indexOf("://");
    if (schemeSep >= 0 && s <= schemeSep + 2)
        return url[0 .. end];
    return url[0 .. s];
}

/// `base` + `rel` per RFC 3986 (as much as a spec `servers` entry needs).
string joinUrl(string base, string rel)
{
    if (!rel.length || rel == ".")
        return base;
    if (rel.startsWith("//"))
    {
        const i = base.indexOf("://");
        return i < 0 ? rel : base[0 .. i] ~ ":" ~ rel;
    }
    if (rel.startsWith("/"))
    {
        const i = base.indexOf("://");
        if (i < 0)
            return rel;
        const after = base.indexOf('/', i + 3);
        return (after < 0 ? base : base[0 .. after]) ~ rel;
    }
    return stripRightSlash(base) ~ "/" ~ rel;
}

/// The result of downloading a spec.
struct FetchResult
{
    /// Response body; null when the server answered 304 to If-None-Match.
    string body_;
    string etag;
    bool notModified;
}

/// Function that downloads `url` (GET, `If-None-Match` when `etag` is set)
/// with the auth, TLS and headers of `conn` (see `extensionConnection`).
/// Injectable so unit tests never touch the network.
alias FetchFn = FetchResult function(string url, string etag, string[string] conn) @safe;

/// Live download over the SDK's curl layer, authenticated like the
/// extension's operations: `conn` supplies auth (Basic/OAuth), TLS and
/// custom headers; the request goes to the spec URL, never the base URL.
FetchResult fetchSpecHttp(string url, string etag, string[string] conn) @safe
{
    import camunda.errors : CamundaException;
    import camunda.http : HttpRequest, perform;
    import camunda.runtime : Transport;
    import camunda.transport : mergeHeadersCaseInsensitive;
    import d8ctl.version_ : cliVersion;

    HttpRequest req;
    req.method = "GET";
    req.url = url;
    int status;
    string bodyText;
    try
    {
        auto client = extensionTransport(conn);
        string[string] base = client.auth().headers();
        base["Accept"] = "application/json, */*";
        base["User-Agent"] = "d8ctl/" ~ cliVersion;
        if (etag.length)
            base["If-None-Match"] = etag;
        req.headers = mergeHeadersCaseInsensitive(base, client.headers);
        req.certPath = client.config.tls.certPath;
        req.keyPath = client.config.tls.keyPath;
        req.caPath = client.config.tls.caPath;
        req.keyPassphrase = client.config.tls.keyPassphrase;
        auto r = perform(req);
        status = r.status;
        bodyText = r.body_;
    }
    catch (CamundaException e)
        throw new ExtensionException("cannot download the spec from " ~ url ~ ": " ~ e.msg);
    // The pinned SDK's HttpResponse exposes no response headers, so no ETag
    // is captured; freshness is decided by the spec's sha256 instead. A
    // manifest that carries an ETag still revalidates with If-None-Match.
    if (status == 304)
        return FetchResult(null, etag, true);
    if (status < 200 || status >= 300)
        throw new ExtensionException("cannot download the spec from " ~ url
            ~ ": HTTP " ~ status.to!string);
    return FetchResult(bodyText, null, false);
}

/// Fail unless `profileName` (when set) names an existing profile.
void requireExtensionProfile(const ref Sources s, string profileName)
{
    if (profileName.length && findProfile(s, profileName) is null)
        throw new ExtensionException("profile '" ~ profileName
            ~ "' not found. See `d8ctl profile list`.");
}

/// A Transport resolved from `overrides` alone — never the process
/// environment. The SDK's `Transport.fromEnv(o)` treats an override that
/// strips to empty as absent and falls back to the environment, so even
/// fully pinned overrides could pick up ambient mTLS client certificates
/// (`CAMUNDA_MTLS_*`) or other cluster settings. The SDK offers no
/// environment-free Transport construction, so the ambient `CAMUNDA_*`
/// variables are removed for the duration of the constructor and restored
/// immediately after (d8ctl is single-threaded here). `extensionConnection`
/// has already validated and pinned auth, so the resulting config equals the
/// overrides wherever they have a value.
Transport extensionTransport(string[string] overrides) @safe
{
    import camunda.runtime : CamundaOptions;
    import d8ctl.safeio : getEnv, setEnv;

    static immutable keys = [
        "CAMUNDA_AUTH_STRATEGY",
        "CAMUNDA_BASIC_AUTH_PASSWORD",
        "CAMUNDA_BASIC_AUTH_USERNAME",
        "CAMUNDA_CLIENT_AUTH_CLIENTID",
        "CAMUNDA_CLIENT_AUTH_CLIENTSECRET",
        "CAMUNDA_CLIENT_ID",
        "CAMUNDA_CLIENT_SECRET",
        "CAMUNDA_DEFAULT_HEADERS",
        "CAMUNDA_DEFAULT_TENANT_ID",
        "CAMUNDA_MTLS_CA",
        "CAMUNDA_MTLS_CA_PATH",
        "CAMUNDA_MTLS_CERT",
        "CAMUNDA_MTLS_CERT_PATH",
        "CAMUNDA_MTLS_KEY",
        "CAMUNDA_MTLS_KEY_PASSPHRASE",
        "CAMUNDA_MTLS_KEY_PATH",
        "CAMUNDA_OAUTH_SCOPE",
        "CAMUNDA_OAUTH_URL",
        "CAMUNDA_REST_ADDRESS",
        "CAMUNDA_REST_ADDRESS_EXACT",
        "CAMUNDA_SDK_BACKPRESSURE_PROFILE",
        "CAMUNDA_SDK_EVENTUAL_POLL_DEFAULT_MS",
        "CAMUNDA_SDK_HTTP_RETRY_BASE_DELAY_MS",
        "CAMUNDA_SDK_HTTP_RETRY_MAX_ATTEMPTS",
        "CAMUNDA_SDK_HTTP_RETRY_MAX_DELAY_MS",
        "CAMUNDA_SDK_LOG_LEVEL",
        "CAMUNDA_TENANT_ID",
        "CAMUNDA_TENANT_IDS",
        "CAMUNDA_TOKEN_AUDIENCE",
        "ZEEBE_REST_ADDRESS",
    ];
    string[string] saved;
    foreach (k; keys)
    {
        saved[k] = getEnv(k);
        setEnv(k, null);
    }
    scope (exit)
        foreach (k, v; saved)
            setEnv(k, v);
    CamundaOptions o;
    o.config = overrides;
    return new Transport(o);
}

/// SDK config overrides for talking to an extension (its operations and its
/// spec URL). Layers: the named profile's auth/TLS/headers (never its cluster
/// address) < `--camunda-*` switches < `--header`. Ambient
/// `CAMUNDA_AUTH_STRATEGY`/credentials and `CAMUNDA_DEFAULT_HEADERS` from the
/// environment never apply: with no profile and no switch, requests send no
/// auth and no custom headers — cluster secrets must not leak to an
/// unrelated server. `baseUrl` (when set) becomes the exact REST address.
string[string] extensionConnection(const ref Sources s, string profileName,
    const string[string] switches = null, const Header[] headers = null, string baseUrl = null)
{
    import d8ctl.profiles : headersFromJson, requireKnownKey;

    string[string] o;
    if (profileName.length)
    {
        auto p = findProfile(s, profileName);
        if (p is null)
            throw new ExtensionException("profile '" ~ profileName
                ~ "' not found. See `d8ctl profile list`.");
        foreach (k, v; p.config)
            o[k] = v;
    }
    o.remove("CAMUNDA_REST_ADDRESS");
    o.remove("CAMUNDA_REST_ADDRESS_EXACT");
    if (auto sw = headersKey in switches)
    {
        requireKnownKey(headersKey);
        o[headersKey] = headersToJson(mergeHeaders(
            headersFromJson(o.get(headersKey, null)), headersFromJson(*sw)));
    }
    foreach (k, v; switches)
    {
        requireKnownKey(k);
        if (k == "CAMUNDA_REST_ADDRESS" || k == "CAMUNDA_REST_ADDRESS_EXACT")
            throw new ExtensionException("--camunda-rest-address does not apply to an extension; "
                ~ "it uses its own base URL (re-add it with --base-url=<url>)");
        if (k != headersKey)
            o[k] = v;
    }
    if (headers.length)
        o[headersKey] = headersToJson(mergeHeaders(headersFromJson(o.get(headersKey, null)), headers));
    // Fail closed against the ambient environment: an extension transport is
    // built with the environment masked (see extensionTransport), so it is
    // never consulted. The pins below decide the strategy and reject
    // half-configured credentials before that.
    pinExtensionAuth(o);
    if (!o.get(headersKey, null).length)
        o[headersKey] = "{}";
    if (baseUrl.length)
    {
        o["CAMUNDA_REST_ADDRESS"] = baseUrl;
        o["CAMUNDA_REST_ADDRESS_EXACT"] = "true";
    }
    return o;
}

/// Resolve the auth strategy from `o` (profile + switches) alone and pin it,
/// so `Transport.fromEnv` can never pick up ambient credentials: an explicit
/// strategy wins; otherwise client credentials mean OAUTH, basic credentials
/// mean BASIC, and nothing means NONE. The chosen strategy's required fields
/// must all come from `o` — a missing one would fall back to the environment,
/// so it is an error instead. Values are judged after the SDK's whitespace
/// stripping: a whitespace-only value falls back to the environment there,
/// so here it counts as absent (an error when the strategy needs it).
private void pinExtensionAuth(ref string[string] o)
{
    import std.string : toUpper;

    string pick(string a, string b)
    {
        auto v = o.get(a, null).strip;
        return v.length ? v : o.get(b, null).strip;
    }

    const id = pick("CAMUNDA_CLIENT_ID", "CAMUNDA_CLIENT_AUTH_CLIENTID");
    const secret = pick("CAMUNDA_CLIENT_SECRET", "CAMUNDA_CLIENT_AUTH_CLIENTSECRET");
    string strategy = o.get("CAMUNDA_AUTH_STRATEGY", null).strip.toUpper;
    if (!strategy.length)
    {
        if (id.length || secret.length)
            strategy = "OAUTH";
        else if (o.get("CAMUNDA_BASIC_AUTH_USERNAME", null).strip.length
                || o.get("CAMUNDA_BASIC_AUTH_PASSWORD", null).strip.length)
            strategy = "BASIC";
        else
            strategy = "NONE";
    }
    o["CAMUNDA_AUTH_STRATEGY"] = strategy;

    void need(string what, string v)
    {
        if (!v.strip.length)
            throw new ExtensionException("auth strategy " ~ strategy ~ " for an extension needs " ~ what
                ~ " from the profile or a --camunda-* switch (the environment is never used)");
    }

    if (strategy == "OAUTH")
    {
        need("a client id", id);
        need("a client secret", secret);
        need("an OAuth URL", o.get("CAMUNDA_OAUTH_URL", null));
        // Set both spellings so neither can be filled from the environment.
        o["CAMUNDA_CLIENT_ID"] = o["CAMUNDA_CLIENT_AUTH_CLIENTID"] = id;
        o["CAMUNDA_CLIENT_SECRET"] = o["CAMUNDA_CLIENT_AUTH_CLIENTSECRET"] = secret;
    }
    else if (strategy == "BASIC")
    {
        need("a basic-auth username", o.get("CAMUNDA_BASIC_AUTH_USERNAME", null));
        need("a basic-auth password", o.get("CAMUNDA_BASIC_AUTH_PASSWORD", null));
    }
    else if (strategy != "NONE")
        throw new ExtensionException("unsupported auth strategy '" ~ strategy ~ "' for an extension");
}

/// `scheme://authority` of `url` — the base for operations whose spec
/// server is the bare root (`rootServer`), whatever the top-level path is.
string originOf(string url)
{
    const i = url.indexOf("://");
    if (i < 0)
        return url;
    const slash = url.indexOf('/', i + 3);
    return slash < 0 ? url : url[0 .. slash];
}

/// A per-process, per-call unique suffix for staging paths.
private string uniqueSuffix()
{
    import std.process : thisProcessID;
    import std.random : uniform;

    return thisProcessID.to!string ~ "-" ~ uniform!uint().to!string;
}

/// Write a new private file (mode 0600 from the start; fails if it exists).
private void writeNewPrivate(string path, string content)
{
    import std.file : append, exists, setAttributes, write;

    if (exists(path))
        throw new ExtensionException("refusing to overwrite " ~ path);
    write(path, "");
    version (Posix)
        setAttributes(path, octal600);
    append(path, content);
}

private enum uint octal600 = 6 * 64;
private enum uint octal700 = 7 * 64;

private void makePrivateDir(string dir)
{
    import std.file : exists, mkdirRecurse, setAttributes;

    if (!exists(dir))
    {
        mkdirRecurse(dir);
        version (Posix)
            setAttributes(dir, octal700);
    }
}

private string nowIso()
{
    import std.datetime.systime : Clock;

    return Clock.currTime().toUTC().toISOExtString();
}

private string manifestJson(const ref Manifest m)
{
    JSONValue o = JSONValue(string[string].init);
    o["name"] = m.name;
    o["specUrl"] = m.specUrl;
    o["baseUrl"] = m.baseUrl;
    o["baseUrlSource"] = m.baseUrlFromSpec ? "spec" : "flag";
    if (m.profile.length)
        o["profile"] = m.profile;
    o["sha256"] = m.sha256;
    if (m.etag.length)
        o["etag"] = m.etag;
    o["fetchedAt"] = m.fetchedAt;
    o["d8ctlVersion"] = m.d8ctlVersion;
    return o.toPrettyString ~ "\n";
}

Manifest readManifest(string cfgDir, string name)
{
    import std.file : exists;

    if (!exists(extensionDir(cfgDir, name)))
        throw new ExtensionException("extension '" ~ name
            ~ "' is not installed. See `d8ctl extension list`.");
    return readManifestAt(generationDir(cfgDir, name), name);
}

private Manifest readManifestAt(string gen, string name)
{
    import std.file : exists, readText;
    import std.path : buildPath;

    auto path = buildPath(gen, "extension.json");
    if (!exists(path))
        throw new ExtensionException("extension '" ~ name
            ~ "' is not installed. See `d8ctl extension list`.");
    JSONValue j;
    try
        j = parseJSON(readText(path));
    catch (Exception e)
        throw new ExtensionException(path ~ " is not valid JSON: " ~ e.msg);
    if (j.type != JSONType.object)
        throw new ExtensionException(path ~ ": expected a JSON object");
    Manifest m;
    m.name = name;
    m.specUrl = j["specUrl"].str;
    m.baseUrl = j["baseUrl"].str;
    // Absent (older manifests): treat as explicit, never silently retarget.
    if (auto v = "baseUrlSource" in j.objectNoRef)
        m.baseUrlFromSpec = v.type == JSONType.string && v.str == "spec";
    m.sha256 = j["sha256"].str;
    if (auto v = "profile" in j.objectNoRef)
        m.profile = v.str;
    if (auto v = "etag" in j.objectNoRef)
        m.etag = v.str;
    if (auto v = "fetchedAt" in j.objectNoRef)
        m.fetchedAt = v.str;
    if (auto v = "d8ctlVersion" in j.objectNoRef)
        m.d8ctlVersion = v.str;
    return m;
}

/// Load an installed extension: manifest + model from the cached spec only.
Extension loadExtension(string cfgDir, string name)
{
    import std.file : exists, readText;

    requireExtensionName(name);
    import std.path : buildPath;

    Extension e;
    if (!exists(extensionDir(cfgDir, name)))
        throw new ExtensionException("extension '" ~ name
            ~ "' is not installed. See `d8ctl extension list`.");
    const gen = generationDir(cfgDir, name); // one generation for both files
    e.manifest = readManifestAt(gen, name);
    auto sp = buildPath(gen, "spec.json");
    if (!exists(sp))
        throw new ExtensionException(sp ~ " is missing; reinstall with `d8ctl extension remove "
            ~ name ~ "` and `extension add`.");
    try
        e.catalog = buildCatalog(readText(sp), null, name);
    catch (OpenApiException ex)
        throw new ExtensionException("cached spec of extension '" ~ name ~ "' no longer parses: "
            ~ ex.msg ~ " (run `d8ctl extension update " ~ name ~ "`)");
    return e;
}

/// Hold `<extensions>/.<name>.lock` (an exclusive mkdir) while `fn` runs,
/// so concurrent add/update/remove of one extension serialize instead of
/// interleaving their cache commits.
private T withExtensionLock(T)(string cfgDir, string name, scope T delegate() @safe fn)
{
    import std.file : FileException, mkdir, rmdirRecurse;
    import std.path : buildPath;

    makePrivateDir(extensionsRoot(cfgDir));
    auto lock = buildPath(extensionsRoot(cfgDir), "." ~ name ~ ".lock");
    try
        mkdir(lock);
    catch (FileException)
        throw new ExtensionException("extension '" ~ name ~ "' is being changed by another d8ctl"
            ~ " (if none is running, remove " ~ lock ~ ")");
    scope (exit)
        rmdirRecurse(lock);
    return fn();
}

/// Commit spec + manifest as one cache generation: both are written into a
/// fresh `g-<unique>` directory, then the `current` pointer is replaced by an
/// atomic rename. The namespace never disappears, a crash at any step leaves
/// the previous generation current, and readers resolve the pointer once
/// (`generationDir`). The two previous generations are kept, so a reader that
/// resolved the pointer before two quick updates still finds the generation
/// it picked; older ones are pruned. A first install stages the whole
/// directory (pointer included) and renames it into place. Callers hold the
/// lock.
private void install(string cfgDir, Manifest m, string specText)
{
    import std.file : DirEntry, dirEntries, exists, isDir, remove, rename, rmdirRecurse, SpanMode;
    import std.path : baseName, buildPath;

    makePrivateDir(extensionsRoot(cfgDir));
    const sfx = uniqueSuffix();
    const gen = "g-" ~ sfx;
    auto dest = extensionDir(cfgDir, m.name);

    void writeGeneration(string dir)
    {
        makePrivateDir(dir);
        writeNewPrivate(buildPath(dir, "spec.json"), specText);
        writeNewPrivate(buildPath(dir, "extension.json"), manifestJson(m));
    }

    if (!exists(dest))
    {
        auto stage = buildPath(extensionsRoot(cfgDir), "." ~ m.name ~ ".stage-" ~ sfx);
        makePrivateDir(stage);
        scope (failure)
            if (exists(stage))
                rmdirRecurse(stage);
        writeGeneration(buildPath(stage, gen));
        writeNewPrivate(buildPath(stage, "current"), gen ~ "\n");
        rename(stage, dest);
        return;
    }

    // Generations currently reachable by readers: the installed one and the
    // one before it (a reader may have resolved either pointer value).
    string[] keep;
    try
    {
        const cur = baseName(generationDir(cfgDir, m.name));
        keep ~= cur;
        auto prevPtr = buildPath(dest, cur, ".previous");
        if (exists(prevPtr))
        {
            import std.file : readText;
            import std.string : strip;

            const prev = readText(prevPtr).strip;
            if (prev.length && prev == baseName(prev) && prev[0] != '.')
                keep ~= prev;
        }
    }
    catch (Exception)
        keep = null; // an unreadable pointer is simply replaced
    auto genDir = buildPath(dest, gen);
    {
        scope (failure)
            if (exists(genDir))
                rmdirRecurse(genDir);
        writeGeneration(genDir);
        // Record the generation this one replaces, so the next prune keeps
        // the reader window one update deep.
        if (keep.length)
            writeNewPrivate(buildPath(genDir, ".previous"), keep[0] ~ "\n");
        auto tmp = buildPath(dest, ".current-" ~ sfx);
        scope (failure)
            if (exists(tmp))
                remove(tmp);
        writeNewPrivate(tmp, gen ~ "\n");
        rename(tmp, buildPath(dest, "current")); // the commit point
    }
    // Prune: keep the new generation and the recorded reader window; drop
    // everything else (a pre-pointer layout's loose files are left alone).
    foreach (DirEntry e; dirEntries(dest, SpanMode.shallow))
    {
        const b = baseName(e.name);
        if (e.isDir && b.length > 2 && b[0 .. 2] == "g-" && b != gen && !keep.canFind(b))
            rmdirRecurse(e.name);
    }
}

/// `d8ctl extension <sub> …`. Returns text for stdout. `fetch` downloads
/// specs; tests inject a fixture reader. `profileFlag` is the global
/// `--profile=<name>` switch (a default profile for `add`).
string extensionCommand(string cfgDir, const ref Sources sources, string[] args,
    string[string] named, const bool[string] bare, FetchFn fetch, string profileFlag = null,
    const string[string] switches = null, const Header[] headers = null)
{
    import d8ctl.version_ : cliVersion;

    auto sub = args.length ? args[0] : "list";
    auto rest = args.length ? args[1 .. $] : (string[]).init;

    string takeFlag(string key)
    {
        auto v = named.get(key, null);
        return v;
    }

    switch (sub)
    {
    case "add":
        if (rest.length != 1)
            throw new ExtensionException(
                "usage: d8ctl extension add <name> --spec=<url> [--base-url=<url>] [--profile=<name>]");
        auto name = rest[0];
        requireExtensionName(name);
        if (listExtensionNames(cfgDir).canFind(name))
            throw new ExtensionException("extension '" ~ name
                ~ "' is already installed. Use `d8ctl extension update " ~ name
                ~ "` to refresh it or `extension remove " ~ name ~ "` first (there is no --force).");
        auto specUrl = takeFlag("spec");
        if (!specUrl.length)
            throw new ExtensionException("extension add needs --spec=<url>");
        auto profile = takeFlag("profile").length ? takeFlag("profile") : profileFlag;
        requireExtensionProfile(sources, profile);
        auto baseOverride = takeFlag("base-url");
        auto got = fetch(specUrl, null, extensionConnection(sources, profile, switches, headers));
        if (got.notModified || !got.body_.length)
            throw new ExtensionException("the server returned no spec for " ~ specUrl);
        // Untrusted input: the hardened reader's limits apply; a bad spec
        // stops the add and leaves any existing cache untouched.
        Catalog cat;
        try
            cat = buildCatalog(got.body_, null, name);
        catch (OpenApiException e)
            throw new ExtensionException("the spec at " ~ specUrl ~ " is not usable: " ~ e.msg);
        Manifest m;
        m.name = name;
        m.specUrl = specUrl;
        m.baseUrl = baseOverride.length ? stripRightSlash(baseOverride)
            : resolveBaseUrl(got.body_, specUrl);
        m.baseUrlFromSpec = !baseOverride.length;
        m.profile = profile;
        m.sha256 = sha256Hex(got.body_);
        m.etag = got.etag;
        m.fetchedAt = nowIso();
        m.d8ctlVersion = cliVersion;
        withExtensionLock!int(cfgDir, name, () @safe {
            if (listExtensionNames(cfgDir).canFind(name))
                throw new ExtensionException("extension '" ~ name ~ "' was installed concurrently");
            install(cfgDir, m, got.body_);
            return 0;
        });
        return "Installed extension '" ~ name ~ "' (" ~ cat.commands.length.to!string
            ~ " commands) from " ~ specUrl ~ "\n  base URL: " ~ m.baseUrl
            ~ "\n  sha256:   " ~ m.sha256[0 .. 12] ~ "…\nTry: d8ctl " ~ name ~ " --help\n";

    case "list", "ls":
        auto names = listExtensionNames(cfgDir);
        if (!names.length)
            return "No extensions. Add one: d8ctl extension add <name> --spec=<url> [--profile=<name>]\n";
        auto buf = appender!string();
        foreach (n; names)
        {
            auto m = readManifest(cfgDir, n);
            buf.put(n ~ "  " ~ m.baseUrl ~ "  sha256:" ~ m.sha256[0 .. 12]
                ~ "…  fetched " ~ m.fetchedAt);
            if (m.profile.length)
                buf.put("  profile " ~ m.profile);
            if ("check" in bare)
            {
                auto got = fetch(m.specUrl, m.etag, extensionConnection(sources,
                    profileFlag.length ? profileFlag : m.profile, switches, headers));
                if (got.notModified)
                    buf.put("  [up to date]");
                else if (got.body_.length && sha256Hex(got.body_) == m.sha256)
                    buf.put("  [up to date]");
                else
                    buf.put("  [STALE — run: d8ctl extension update " ~ n ~ "]");
            }
            buf.put("\n");
        }
        return buf.data;

    case "update":
        string[] names;
        if ("all" in bare)
            names = listExtensionNames(cfgDir);
        else if (rest.length == 1)
            names = [rest[0]];
        else
            throw new ExtensionException("usage: d8ctl extension update [<name>|--all]");
        auto buf = appender!string();
        foreach (n; names)
        {
            // The whole read/fetch/commit lifecycle runs under the lock: a
            // `remove` finishing mid-download can no longer be silently
            // reinstalled, and a slower update cannot overwrite a newer one
            // (the manifest is read again inside the lock, after the fetch,
            // and the commit is abandoned when the installed generation
            // changed under us).
            auto line = withExtensionLock!string(cfgDir, n, () @safe {
                import std.file : exists;

                auto m = readManifest(cfgDir, n);
                // An explicit --profile wins (switch credentials, or recover
                // after the stored profile was removed); a rewritten cache keeps it.
                if (profileFlag.length)
                    m.profile = profileFlag;
                auto got = fetch(m.specUrl, m.etag, extensionConnection(sources, m.profile,
                    switches, headers));
                // A concurrent `remove` could not have run (we hold the lock),
                // but a stale reader of this code path could: re-verify the
                // install still names the generation we read before committing.
                if (!exists(extensionDir(cfgDir, n)))
                    throw new ExtensionException("extension '" ~ n
                        ~ "' was removed while updating; nothing was installed.");
                if (got.notModified)
                    return n ~ ": up to date (ETag matched)\n";
                if (!got.body_.length)
                    throw new ExtensionException("the server returned no spec for " ~ m.specUrl);
                const hash = sha256Hex(got.body_);
                if (hash == m.sha256)
                    return n ~ ": up to date (sha256 " ~ hash[0 .. 12] ~ "…)\n";
                Catalog cat;
                try
                    cat = buildCatalog(got.body_, null, n);
                catch (OpenApiException e)
                    throw new ExtensionException("the new spec at " ~ m.specUrl
                        ~ " is not usable: " ~ e.msg ~ " (the installed copy was kept)");
                m.sha256 = hash;
                m.etag = got.etag;
                m.fetchedAt = nowIso();
                m.d8ctlVersion = cliVersion;
                // A spec-derived base follows the new spec's servers; an explicit
                // --base-url is kept.
                if (m.baseUrlFromSpec || !m.baseUrl.length)
                {
                    m.baseUrl = resolveBaseUrl(got.body_, m.specUrl);
                    m.baseUrlFromSpec = true;
                }
                install(cfgDir, m, got.body_);
                return n ~ ": updated to sha256 " ~ hash[0 .. 12] ~ "… ("
                    ~ cat.commands.length.to!string ~ " commands)\n";
            });
            buf.put(line);
        }
        return buf.data;

    case "remove", "rm", "delete":
        if (rest.length != 1)
            throw new ExtensionException("usage: d8ctl extension remove <name>");
        auto name = rest[0];
        if (!listExtensionNames(cfgDir).canFind(name))
            throw new ExtensionException("extension '" ~ name
                ~ "' is not installed. See `d8ctl extension list`.");
        import std.file : rmdirRecurse;

        withExtensionLock!int(cfgDir, name, () @safe {
            rmdirRecurse(extensionDir(cfgDir, name));
            return 0;
        });
        return "Removed extension '" ~ name ~ "'\n";

    default:
        throw new ExtensionException("unknown extension command '" ~ sub
            ~ "'. See `d8ctl extension --help`.");
    }
}

/// `d8ctl extension --help`.
string extensionHelp()
{
    auto buf = appender!string();
    buf.put("d8ctl extension — namespaces generated from a server's OpenAPI spec\n\n");
    buf.put("Usage:\n");
    buf.put("  d8ctl extension add <name> --spec=<url> [--base-url=<url>] [--profile=<name>]\n");
    buf.put("                            Download the spec, generate commands, cache them\n");
    buf.put("  d8ctl extension list [--check]            Installed extensions (age, sha256, source)\n");
    buf.put("  d8ctl extension update [<name>|--all]     Re-download (skips on a matching sha256)\n");
    buf.put("  d8ctl extension remove <name>\n\n");
    buf.put("An extension <name> becomes a namespace next to `cluster`: `d8ctl <name>\n");
    buf.put("<resource> <verb>` (either order), with help, --dry-run and body flags from\n");
    buf.put("the cached spec. Commands read only the cache — never the network.\n\n");
    buf.put("Naming comes from the spec's x-cli.command (an array of words, used as an\n");
    buf.put("exact command path: `d8ctl <name> w1 ... wn`; x-cli.aliases add more paths)\n");
    buf.put("when present, else from the operationId. Operations with x-cli.audience: operator (or excluded from the\n");
    buf.put("MCP surface with no x-cli) are hidden unless you pass --operator; x-cli.exclude\n");
    buf.put("removes them completely. Reserved names: " ~ RESERVED_NAMES.join(", ") ~ ".\n\n");
    buf.put("The namespace has its own base URL (the spec's servers[0].url resolved\n");
    buf.put("against the spec URL, or --base-url). A profile supplies only auth and\n");
    buf.put("headers — never its cluster address. With no profile, requests send no auth\n");
    buf.put("and no CAMUNDA_DEFAULT_HEADERS from the environment. --camunda-* switches and\n");
    buf.put("--header apply on top; spec downloads use the same connection.\n");
    return buf.data;
}

private string joinNames(const string[] names)
{
    string s;
    foreach (i, n; names)
    {
        if (i)
            s ~= ", ";
        s ~= n;
    }
    return s;
}

version (unittest)
{
    import std.file : mkdirRecurse, write;
    import std.path : baseName, buildPath;

    /// A tiny x-cli-bearing spec (the nwf fixture has none yet).
    enum xcliSpec = `{
      "openapi": "3.0.3",
      "info": {"title": "T", "version": "1"},
      "servers": [{"url": "api"}],
      "paths": {
        "/status": {"get": {"operationId": "listActivePrs", "summary": "Fleet status",
          "responses": {"200": {"description": "ok",
            "content": {"application/json": {"schema": {"type": "object"}}}}}}},
        "/things/{thingId}": {"get": {"operationId": "getThing",
          "x-cli": {"command": ["thing", "show"], "positional": ["thingId"]},
          "parameters": [{"name": "thingId", "in": "path", "required": true}],
          "responses": {"200": {"description": "ok"}}}},
        "/doors": {"post": {"operationId": "openDoor",
          "x-cli": {"command": ["door", "open"], "audience": "operator"},
          "responses": {"200": {"description": "ok"}}}},
        "/hooks/x": {"post": {"operationId": "hookX",
          "x-cli": {"exclude": true},
          "responses": {"200": {"description": "ok"}}}}
      }
    }`;

    private string fixtureSpec()
    {
        import std.file : readText;
        import std.path : buildPath, dirName;

        return readText(buildPath(__FILE_FULL_PATH__.dirName.dirName.dirName,
            "test", "fixtures", "openapi", "nano-workforce-0.210.2.json"));
    }

    private string testDir(string tag)
    {
        import std.file : tempDir;
        import std.process : thisProcessID;

        return buildPath(tempDir, "d8ctl-ext-test-" ~ tag ~ "-" ~ thisProcessID.to!string);
    }

    // Fake fetch: tests set the body/304 the next calls return. Module-global
    // is fine — dub runs one module's unittests single-threaded.
    private string fakeBody;
    private bool fakeNotModified;
    private string sRemoveDir;

    private FetchResult fakeFetchImpl(string url, string etag, string[string] conn) @safe
    {
        return FetchResult(fakeNotModified ? null : fakeBody, null, fakeNotModified);
    }

    private FetchFn fakeFetch(string body_)
    {
        fakeBody = body_;
        fakeNotModified = false;
        return &fakeFetchImpl;
    }

    private FetchFn fakeFetch304()
    {
        fakeNotModified = true;
        return &fakeFetchImpl;
    }
}

unittest
{
    import std.exception : assertThrown;

    assert(isValidExtensionName("nwf") && isValidExtensionName("a") && isValidExtensionName("a-b-c9"));
    assert(!isValidExtensionName("") && !isValidExtensionName("Nwf") && !isValidExtensionName("-a"));
    assert(!isValidExtensionName("a_b") && !isValidExtensionName("a".repeat32plus));
    foreach (n; RESERVED_NAMES)
        assertThrown!ExtensionException(requireExtensionName(n));
    assertThrown!ExtensionException(requireExtensionName("Bad Name"));

    // Base URL resolution: relative, absolute, root-relative, variables.
    const u = "http://merlin.local:8080/console/app-view/Workforce/app/api-docs/openapi.json";
    auto resolved = resolveBaseUrl(`{"servers": [{"url": "api"}]}`, u);
    assert(resolved == "http://merlin.local:8080/console/app-view/Workforce/app/api", resolved);
    assert(resolveBaseUrl(`{"servers": [{"url": "/v1"}]}`, u) == "http://merlin.local:8080/v1");
    assert(resolveBaseUrl(`{"servers": [{"url": "https://x.example/api/"}]}`, u)
        == "https://x.example/api");
    assert(resolveBaseUrl(`{"servers": [{"url": "{protocol}://h/{ver}", "variables":
        {"protocol": {"default": "https"}, "ver": {"default": "v9"}}}]}`, u) == "https://h/v9");
    assertThrown!ExtensionException(resolveBaseUrl(`{}`, u));
}

unittest
{
    // add/list/update/remove against a fake fetch; files are 0600 in a 0700 dir.
    import std.exception : assertThrown;
    import std.file : exists, getAttributes, readText;

    auto dir = testDir("cmd");
    scope (exit)
        cleanupDir(dir);
    auto sources = Sources.init;

    auto out_ = extensionCommand(dir, sources, ["add", "t"], ["spec": "http://h/openapi.json"],
        null, fakeFetch(xcliSpec));
    assert(out_.indexOf("3 commands") >= 0, out_); // hookX is x-cli.excluded
    auto m = readManifest(dir, "t");
    // http://h/openapi.json + bare `api` → parent of the root dir → http://h/api
    assert(m.baseUrl == "http://h/api", m.baseUrl);
    assert(m.sha256 == sha256Hex(xcliSpec));
    version (Posix)
    {
        assert((getAttributes(manifestPath(dir, "t")) & 0x1FF) == octal600);
        assert((getAttributes(specPath(dir, "t")) & 0x1FF) == octal600);
        assert((getAttributes(extensionDir(dir, "t")) & 0x1FF) == octal700);
    }

    // Duplicate add is refused and points at update/remove.
    assertThrown!ExtensionException(extensionCommand(dir, sources, ["add", "t"],
        ["spec": "http://h/openapi.json"], null, fakeFetch(xcliSpec)));
    // Reserved and invalid names are refused.
    assertThrown!ExtensionException(extensionCommand(dir, sources, ["add", "cluster"],
        ["spec": "http://h/o.json"], null, fakeFetch(xcliSpec)));
    // A bad spec leaves the cache untouched.
    assertThrown!ExtensionException(extensionCommand(dir, sources, ["add", "u"],
        ["spec": "http://h/o.json"], null, fakeFetch(`{"paths": `)));
    assert(!exists(extensionDir(dir, "u")));

    // list shows age + short sha; --check compares fingerprints.
    auto listed = extensionCommand(dir, sources, ["list"], null, null, fakeFetch(xcliSpec));
    assert(listed.indexOf("t  http://h/api  sha256:" ~ m.sha256[0 .. 12]) >= 0, listed);
    auto checked = extensionCommand(dir, sources, ["list"], null, ["check": true], fakeFetch(xcliSpec));
    assert(checked.indexOf("[up to date]") >= 0, checked);
    auto stale = extensionCommand(dir, sources, ["list"], null, ["check": true],
        fakeFetch(xcliSpec ~ " "));
    assert(stale.indexOf("[STALE") >= 0, stale);

    // update: same body → no rewrite; changed body → new fingerprint.
    auto same = extensionCommand(dir, sources, ["update", "t"], null, null, fakeFetch(xcliSpec));
    assert(same.indexOf("up to date") >= 0, same);
    auto changed = extensionCommand(dir, sources, ["update", "t"], null, null,
        fakeFetch(xcliSpec.replace(`"T"`, `"T2"`)));
    assert(changed.indexOf("updated to sha256") >= 0, changed);
    assert(readManifest(dir, "t").sha256 == sha256Hex(xcliSpec.replace(`"T"`, `"T2"`)));
    // Generations: the pointer moved; the reader window (new + two previous)
    // is kept, older ones pruned.
    {
        import std.file : DirEntry, dirEntries, SpanMode;

        size_t countGens()
        {
            size_t k;
            foreach (DirEntry e; dirEntries(extensionDir(dir, "t"), SpanMode.shallow))
                if (e.isDir && baseName(e.name).startsWith("g-"))
                    k++;
            return k;
        }

        assert(exists(buildPath(extensionDir(dir, "t"), "current")));
        auto gens = countGens();
        assert(gens == 2, gens.to!string);
        extensionCommand(dir, sources, ["update", "t"], null, null,
            fakeFetch(xcliSpec.replace(`"T"`, `"T3"`)));
        gens = countGens();
        assert(gens == 3, gens.to!string); // reader window: new + two previous
        extensionCommand(dir, sources, ["update", "t"], null, null,
            fakeFetch(xcliSpec.replace(`"T"`, `"T4"`)));
        gens = countGens();
        assert(gens == 3, gens.to!string); // the oldest fell out of the window
        auto loaded = loadExtension(dir, "t"); // manifest + spec from one generation
        assert(loaded.manifest.sha256 == sha256Hex(xcliSpec.replace(`"T"`, `"T4"`)));
    }
    // A spec-derived base URL follows the new spec's servers on update.
    assert(readManifest(dir, "t").baseUrlFromSpec);
    extensionCommand(dir, sources, ["update", "t"], null, null,
        fakeFetch(xcliSpec.replace(`"url": "api"`, `"url": "/v2"`)));
    assert(readManifest(dir, "t").baseUrl == "http://h/v2", readManifest(dir, "t").baseUrl);
    // An explicit --base-url is kept across updates.
    extensionCommand(dir, sources, ["add", "e"], ["spec": "http://h/openapi.json",
        "base-url": "http://fixed/x/"], null, fakeFetch(xcliSpec));
    assert(!readManifest(dir, "e").baseUrlFromSpec);
    extensionCommand(dir, sources, ["update", "e"], null, null,
        fakeFetch(xcliSpec.replace(`"url": "api"`, `"url": "/v2"`)));
    assert(readManifest(dir, "e").baseUrl == "http://fixed/x", readManifest(dir, "e").baseUrl);
    fakeFetch(xcliSpec);

    // A 304 keeps everything.
    auto notMod = extensionCommand(dir, sources, ["update", "t"], null, null, fakeFetch304());
    assert(notMod.indexOf("ETag matched") >= 0, notMod);

    // remove.
    auto rm = extensionCommand(dir, sources, ["remove", "t"], null, null, fakeFetch(xcliSpec));
    assert(rm.indexOf("Removed") >= 0 && !exists(extensionDir(dir, "t")));
    assertThrown!ExtensionException(extensionCommand(dir, sources, ["remove", "t"],
        null, null, fakeFetch(xcliSpec)));
}

unittest
{
    // The committed nwf fixture: 52 operations, operator gate on x-mcp excludes.
    auto cat = buildCatalog(fixtureSpec(), null, "nwf");
    assert(cat.commands.length == 52, cat.commands.length.to!string);
    size_t operator;
    bool sawDispatch;
    foreach (c; cat.commands)
    {
        if (c.operatorOnly)
            operator++;
        if (c.operationId == "dispatchDeliveryGraph")
        {
            sawDispatch = true;
            assert(c.operatorOnly);
            assert(c.resource == "delivery-graph" && c.verb == "dispatch");
        }
    }
    assert(sawDispatch);
    assert(operator == 5, operator.to!string); // the five x-mcp excludes
    // operationId fallback naming.
    bool sawStatus, sawStart;
    foreach (c; cat.commands)
    {
        if (c.operationId == "listActivePrs")
        {
            sawStatus = true;
            assert(c.resource == "active-prs" && c.verb == "list");
        }
        if (c.operationId == "startFeature")
        {
            sawStart = true;
            assert(c.resource == "feature" && c.verb == "start");
            assert(c.hasBody && !c.operatorOnly);
        }
    }
    assert(sawStatus && sawStart);
}

private void cleanupDir(string dir)
{
    import std.file : exists, rmdirRecurse;

    if (exists(dir))
        rmdirRecurse(dir);
}

private string repeat32plus(string s)
{
    foreach (_; 0 .. 33)
        s ~= "a";
    return s;
}

unittest
{
    // Review regressions (PR #13): connection isolation, switches, origin.
    import std.exception : assertThrown;

    Sources none;
    auto bare = extensionConnection(none, null);
    assert(bare["CAMUNDA_AUTH_STRATEGY"] == "NONE"); // ambient auth never applies
    assert(bare[headersKey] == "{}"); // nor ambient CAMUNDA_DEFAULT_HEADERS
    assert("CAMUNDA_REST_ADDRESS" !in bare);

    auto sw = extensionConnection(none, null, ["CAMUNDA_AUTH_STRATEGY": "BASIC",
        "CAMUNDA_BASIC_AUTH_USERNAME": "u", "CAMUNDA_BASIC_AUTH_PASSWORD": "p",
        headersKey: `{"X-A":"1"}`], [Header("x-a", "2"), Header("X-B", "3")], "http://h/api");
    assert(sw["CAMUNDA_AUTH_STRATEGY"] == "BASIC");
    assert(sw[headersKey].indexOf(`"x-a":"2"`) >= 0 && sw[headersKey].indexOf("X-B") >= 0, sw[headersKey]);
    assert(sw["CAMUNDA_REST_ADDRESS"] == "http://h/api" && sw["CAMUNDA_REST_ADDRESS_EXACT"] == "true");
    assertThrown!ExtensionException(extensionConnection(none, null,
        ["CAMUNDA_REST_ADDRESS": "http://elsewhere"]));
    assertThrown!ExtensionException(extensionConnection(none, "missing"));

    // Auth is pinned from profile + switches only; ambient secrets never fill gaps.
    Sources withProfiles;
    withProfiles.store.profiles["hdr"] = [headersKey: `{"X-T":"1"}`];
    withProfiles.store.profiles["oauth"] = ["CAMUNDA_CLIENT_ID": "id", "CAMUNDA_CLIENT_SECRET": "s",
        "CAMUNDA_OAUTH_URL": "https://idp/token"];
    withProfiles.store.profiles["half"] = ["CAMUNDA_AUTH_STRATEGY": "OAUTH", "CAMUNDA_CLIENT_ID": "id"];
    withProfiles.store.profiles["basicNoPw"] = ["CAMUNDA_BASIC_AUTH_USERNAME": "u"];
    assert(extensionConnection(withProfiles, "hdr")["CAMUNDA_AUTH_STRATEGY"] == "NONE");
    auto oa = extensionConnection(withProfiles, "oauth");
    assert(oa["CAMUNDA_AUTH_STRATEGY"] == "OAUTH");
    assert(oa["CAMUNDA_CLIENT_AUTH_CLIENTID"] == "id" && oa["CAMUNDA_CLIENT_AUTH_CLIENTSECRET"] == "s");
    assertThrown!ExtensionException(extensionConnection(withProfiles, "half"));
    assertThrown!ExtensionException(extensionConnection(withProfiles, "basicNoPw"));
    assertThrown!ExtensionException(extensionConnection(none, null, ["CAMUNDA_AUTH_STRATEGY": "BASIC"]));
    assert(extensionConnection(none, null, ["CAMUNDA_AUTH_STRATEGY": "basic",
        "CAMUNDA_BASIC_AUTH_USERNAME": "u", "CAMUNDA_BASIC_AUTH_PASSWORD": "p"])["CAMUNDA_AUTH_STRATEGY"] == "BASIC");

    assert(originOf("https://h:8/api/v1") == "https://h:8");
    assert(originOf("https://h") == "https://h");

    // Profile-alias verbs are reserved (parse.d rewrites `list profile…`).
    foreach (n; ["list", "show", "add", "use", "remove", "rm", "delete"])
        assertThrown!ExtensionException(requireExtensionName(n));
}

version (unittest)
{
    private string lastConnAuth;

    private FetchResult recordingFetch(string url, string etag, string[string] conn) @safe
    {
        lastConnAuth = conn.get("CAMUNDA_AUTH_STRATEGY", null);
        return FetchResult(fakeBody, null, false);
    }
}

unittest
{
    // A held lock refuses concurrent changes; a commit leaves no staging dirs.
    import std.exception : assertThrown;
    import std.file : dirEntries, mkdir, rmdir, SpanMode;

    auto dir = testDir("lock");
    scope (exit)
        cleanupDir(dir);
    Sources sources;
    fakeBody = xcliSpec;
    extensionCommand(dir, sources, ["add", "t"], ["spec": "http://h/o.json"], null, &recordingFetch);
    assert(lastConnAuth == "NONE");
    auto lock = buildPath(extensionsRoot(dir), ".t.lock");
    mkdir(lock);
    fakeBody = xcliSpec.replace(`"T"`, `"T3"`);
    assertThrown!ExtensionException(extensionCommand(dir, sources, ["update", "t"], null, null,
        &recordingFetch));
    assert(readManifest(dir, "t").sha256 == sha256Hex(xcliSpec)); // previous generation kept
    assertThrown!ExtensionException(extensionCommand(dir, sources, ["remove", "t"], null, null,
        &recordingFetch));
    rmdir(lock);
    auto upd = extensionCommand(dir, sources, ["update", "t"], null, null, &recordingFetch);
    assert(upd.indexOf("updated") >= 0, upd);
    size_t entries;
    foreach (e; dirEntries(extensionsRoot(dir), SpanMode.shallow))
        entries++;
    assert(entries == 1); // only `t`: no .stage-/.old-/.lock leftovers
    // An explicit --profile that does not exist is honoured (and fails),
    // rather than silently using the stored one.
    assertThrown!ExtensionException(extensionCommand(dir, sources, ["update", "t"], null, null,
        &recordingFetch, "ghost"));
    assertThrown!ExtensionException(extensionCommand(dir, sources, ["list"], null, ["check": true],
        &recordingFetch, "ghost"));
}

unittest
{
    // Review regressions (PR #13 round 4): env-free transports, whitespace
    // credentials, update locking, and the reader window of generations.
    import camunda.runtime : AuthStrategy;
    import std.exception : assertThrown;
    import std.file : exists, readText;

    // Whitespace-only credentials count as absent (the SDK strips overrides
    // and would fall back to the environment), so they fail before any
    // request instead of silently authenticating with cluster secrets.
    Sources ws;
    ws.store.profiles["wsBasic"] = ["CAMUNDA_BASIC_AUTH_USERNAME": "u",
        "CAMUNDA_BASIC_AUTH_PASSWORD": " "];
    ws.store.profiles["wsOauth"] = ["CAMUNDA_CLIENT_ID": "id",
        "CAMUNDA_CLIENT_SECRET": " ", "CAMUNDA_OAUTH_URL": "https://idp/token"];
    assertThrown!ExtensionException(extensionConnection(ws, "wsBasic"));
    assertThrown!ExtensionException(extensionConnection(ws, "wsOauth"));
    const(Sources) noSources = Sources.init;
    assertThrown!ExtensionException(extensionConnection(noSources, null,
        ["CAMUNDA_AUTH_STRATEGY": "BASIC", "CAMUNDA_BASIC_AUTH_USERNAME": "u",
         "CAMUNDA_BASIC_AUTH_PASSWORD": "  "]));

    // The extension transport never consults the environment: ambient mTLS
    // (and any other CAMUNDA_*) must not reach the resolved config, and the
    // process environment is restored afterwards.
    import d8ctl.safeio : getEnv, setEnv;

    void withEnv(string k, string v, scope void delegate() @safe fn)
    {
        auto saved = getEnv(k);
        setEnv(k, v);
        scope (exit)
            setEnv(k, saved);
        fn();
    }

    withEnv("CAMUNDA_MTLS_CERT", "cluster-cert", {
        withEnv("CAMUNDA_MTLS_KEY", "cluster-key", {
            withEnv("CAMUNDA_MTLS_CERT_PATH", "/cluster/cert.pem", {
                withEnv("CAMUNDA_MTLS_KEY_PATH", "/cluster/key.pem", {
                    auto t = extensionTransport(extensionConnection(noSources, null));
                    assert(!t.config.tls.cert.length, t.config.tls.cert);
                    assert(!t.config.tls.key.length);
                    assert(!t.config.tls.certPath.length, t.config.tls.certPath);
                    assert(!t.config.tls.keyPath.length);
                    assert(t.config.authStrategy == AuthStrategy.none);
                });
            });
            // A profile's own mTLS settings do apply. (Equal-length paths:
            // the pinned SDK's validate() XORs the two lengths.)
            Sources tls;
            tls.store.profiles["mtls"] = ["CAMUNDA_MTLS_CERT_PATH": "/ext/crt.pem",
                "CAMUNDA_MTLS_KEY_PATH": "/ext/key.pem"];
            auto t2 = extensionTransport(extensionConnection(tls, "mtls"));
            assert(t2.config.tls.certPath == "/ext/crt.pem", t2.config.tls.certPath);
            assert(!t2.config.tls.cert.length); // inline cert not set by the profile
        });
    });
    assert(getEnv("CAMUNDA_MTLS_CERT") is null); // restored (was unset here)

    // update holds the lock across the fetch: a fetch that removes the
    // extension mid-flight (a concurrent `remove` that got the lock first)
    // makes the update fail instead of silently reinstalling it.
    auto dir = testDir("r4");
    scope (exit)
        cleanupDir(dir);
    Sources sources;
    extensionCommand(dir, sources, ["add", "t"], ["spec": "http://h/o.json"],
        null, fakeFetch(xcliSpec));
    static size_t sFetches;
    static FetchResult removingFetchImpl(string url, string etag, string[string] conn) @safe
    {
        sFetches++;
        if (sFetches > 0)
        {
            // Simulate the concurrent remove: it holds no lock here because
            // the test runs single-threaded, but the update must notice the
            // vanished install when it re-reads under its own lock.
            import std.file : rmdirRecurse;

            rmdirRecurse(extensionDir(sRemoveDir, "t"));
        }
        return FetchResult(xcliSpec.replace(`"T"`, `"T9"`), null, false);
    }

    sFetches = 0;
    sRemoveDir = dir;
    string rmOut;
    ExtensionException rmErr;
    try
        rmOut = extensionCommand(dir, sources, ["update", "t"],
            (string[string]).init, (bool[string]).init, &removingFetchImpl);
    catch (ExtensionException e)
        rmErr = e;
    assert(rmErr !is null, "update should have thrown; fetches=" ~ sFetches.to!string
        ~ " out=" ~ rmOut ~ " exists=" ~ exists(extensionDir(dir, "t")).to!string);
    assert(!exists(extensionDir(dir, "t"))); // not reinstalled by the stale update

    // The reader window: a generation resolved before two quick updates is
    // still on disk (the reader's manifest and spec stay consistent).
    extensionCommand(dir, sources, ["add", "w"], ["spec": "http://h/o.json"],
        null, fakeFetch(xcliSpec));
    const genA = generationDir(dir, "w");
    extensionCommand(dir, sources, ["update", "w"], null, null,
        fakeFetch(xcliSpec.replace(`"T"`, `"T2"`)));
    const genB = generationDir(dir, "w");
    extensionCommand(dir, sources, ["update", "w"], null, null,
        fakeFetch(xcliSpec.replace(`"T"`, `"T3"`)));
    assert(genA != genB);
    assert(exists(buildPath(genA, "spec.json")) && exists(buildPath(genA, "extension.json")),
        "reader's generation pruned under it");
    // The manifest a reader took from genA still matches genA's spec.
    assert(readText(buildPath(genA, "spec.json")) == xcliSpec);
    // A third update finally reclaims genA.
    extensionCommand(dir, sources, ["update", "w"], null, null,
        fakeFetch(xcliSpec.replace(`"T"`, `"T4"`)));
    assert(!exists(genA), "stale generation never reclaimed");
    assert(exists(buildPath(genB, "spec.json")));
}
