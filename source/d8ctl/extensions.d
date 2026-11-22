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
import std.json : JSONOptions, JSONType, JSONValue, parseJSON;
import std.string : endsWith, indexOf, join, startsWith, strip, toLower;

/// Bad extension command, invalid name/spec, or unknown extension (exit 2).
class ExtensionException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow @nogc @safe
    {
        super(msg, file, line);
    }
}

/// A spec download that failed, with what its retry loop did (attempts and
/// elapsed time) for the error envelope, like a failed API call.
class SpecDownloadException : ExtensionException
{
    import d8ctl.dispatch : RetryStats;

    RetryStats stats;

    this(string msg, RetryStats stats, string file = __FILE__, size_t line = __LINE__) @safe
    {
        super(msg, file, line);
        this.stats = stats;
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
    /// Profile-relative (#25): `specUrl` and `baseUrl` are root-relative
    /// paths, resolved per call against the origin of the selected profile's
    /// REST address. The route (and its credentials) follow the profile.
    bool relative;
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

/// The spec's base (see `resolveBaseUrl`) as a root-relative path, for a
/// profile-relative extension fetched from `fetchUrl` on `origin`. A server
/// on another host cannot follow the profile, so it is an error.
string relativeBase(string specJson, string fetchUrl, string origin)
{
    auto abs = resolveBaseUrl(specJson, fetchUrl);
    if (originOf(abs) != origin)
        throw new ExtensionException("the spec's server " ~ abs ~ " is not on the profile's host "
            ~ origin ~ "; pass --base-url=<path>");
    return abs[origin.length .. $]; // "" is the origin itself
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
    import camunda.errors : ApiException, CamundaException;
    import d8ctl.safeio : boundedGet;
    import camunda.runtime : Transport;
    import camunda.transport : mergeHeadersCaseInsensitive;
    import d8ctl.version_ : cliVersion;

    import d8ctl.dispatch : RetryStats, countedTransport, retrying;

    int status;
    string bodyText;
    string gotEtag;
    auto stats = new RetryStats;
    try
    {
        auto client = countedTransport(conn, stats,
            (string[string] o) => extensionTransport(o));
        string[string] base = client.auth().headers();
        base["Accept"] = "application/json, */*";
        base["User-Agent"] = "d8ctl/" ~ cliVersion;
        if (etag.length)
            base["If-None-Match"] = etag;
        auto hdrs = mergeHeadersCaseInsensitive(base, client.headers);
        // Same retry as API calls (the SDK's policy and the profile's
        // CAMUNDA_SDK_HTTP_RETRY_*): network errors and 429/502/503/504.
        import d8ctl.safeio : BoundedResponse;

        // Counted, so a failure reports its attempts and elapsed time.
        auto r = retrying!BoundedResponse(client, stats, "GET", () @safe {
            // Bounded while receiving: the hardened reader's own size limit
            // runs only after the download, too late to stop a memory blow-up.
            auto got = boundedGet(url, hdrs, MAX_SPEC_BYTES, client.config.tls.certPath,
                client.config.tls.keyPath, client.config.tls.caPath, client.config.tls.keyPassphrase);
            // Every failure status (not only retryable ones) goes through the
            // counted path, so a 503-then-404 still reports its attempts.
            // The retry policy itself retries only transient statuses.
            if (got.status != 304 && (got.status < 200 || got.status >= 300))
                throw new ApiException(got.status, got.body_);
            return got;
        });
        status = r.status;
        gotEtag = r.etag;
        bodyText = r.body_;
    }
    catch (ApiException e)
        throw new SpecDownloadException("cannot download the spec from " ~ url
            ~ ": HTTP " ~ e.status.to!string, stats);
    catch (CamundaException e)
        throw new SpecDownloadException("cannot download the spec from " ~ url ~ ": " ~ e.msg, stats);
    if (status == 304)
        return FetchResult(null, etag, true);
    return FetchResult(bodyText, gotEtag, false);
}

/// Upper bound on a downloaded spec, matching the hardened reader's default.
enum size_t MAX_SPEC_BYTES = 64 * 1024 * 1024;

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
    import d8ctl.safeio : envNames, getEnv, setEnv;

    // Every CAMUNDA_* / ZEEBE_* variable, not a fixed list: the SDK also
    // reads e.g. CAMUNDA_OAUTH_CACHE_DIR (a shared token cache keyed without
    // scope/secret) and CAMUNDA_WORKER_*, and future keys must not leak.
    string[string] saved;
    foreach (k; envNames())
    {
        import std.algorithm : startsWith;

        if (!k.startsWith("CAMUNDA_") && !k.startsWith("ZEEBE_"))
            continue;
        saved[k] = getEnv(k);
        setEnv(k, null);
    }
    scope (exit)
        foreach (k, v; saved)
            setEnv(k, v);
    // The CLI retry window (#29) where the overrides set none; the
    // environment is masked here, so only the overrides count.
    import d8ctl.dispatch : applyRetryDefaults;

    auto withDefaults = overrides.dup;
    applyRetryDefaults(withDefaults);
    CamundaOptions o;
    o.config = withDefaults;
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

/// True for a profile-relative reference: a root-relative path (`/…`, not
/// the protocol-relative `//host`), resolved against a profile's origin (#25).
bool isRelativeRef(string u) pure nothrow
{
    return u.startsWith("/") && !u.startsWith("//");
}

/// Where a profile-relative extension goes for one call: the profile chosen
/// and the origin (`scheme://host:port`) of its REST address.
struct Route
{
    string profile;
    string origin;
}

/// Pick the profile the way `cluster` commands do: `--profile`, else
/// `D8CTL_PROFILE`, else the active profile. Its credentials only ever go to
/// its own origin, so following the active profile cannot leak them.
Route relativeRoute(const ref Sources s, string flagProfile, string envProfile)
{
    import d8ctl.profiles : activeName;

    auto name = flagProfile.length ? flagProfile : envProfile.length ? envProfile : activeName(s);
    if (!name.length)
        throw new ExtensionException("this extension resolves against a profile, and none is "
            ~ "selected: pass --profile=<name> or run `d8ctl profile use <name>`");
    auto p = findProfile(s, name);
    if (p is null)
        throw new ExtensionException("profile '" ~ name ~ "' not found. See `d8ctl profile list`.");
    auto addr = p.config.get("CAMUNDA_REST_ADDRESS", null).strip;
    if (addr.indexOf("://") < 0)
        throw new ExtensionException("profile '" ~ name ~ "' has no REST address "
            ~ "(CAMUNDA_REST_ADDRESS), so a relative extension cannot resolve against it");
    return Route(name, originOf(addr));
}

/// The absolute spec URL and base URL of `m` for one call (`origin` is only
/// used by relative extensions).
string specUrlFor(const ref Manifest m, string origin) pure
{
    return m.relative ? origin ~ m.specUrl : m.specUrl;
}

/// ditto
string baseUrlFor(const ref Manifest m, string origin) pure
{
    return m.relative ? origin ~ m.baseUrl : m.baseUrl;
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
    if (m.relative)
        o["relative"] = true;
    if (m.profile.length)
        o["profile"] = m.profile;
    o["sha256"] = m.sha256;
    if (m.etag.length)
        o["etag"] = m.etag;
    o["fetchedAt"] = m.fetchedAt;
    o["d8ctlVersion"] = m.d8ctlVersion;
    return o.toPrettyString(JSONOptions.doNotEscapeSlashes) ~ "\n";
}

/// True for a lowercase-hex SHA-256 fingerprint.
bool isSha256Hex(string s) pure nothrow
{
    if (s.length != 64)
        return false;
    foreach (char c; s)
        if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')))
            return false;
    return true;
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
    // Corrupt-but-valid JSON (e.g. `{}`, a non-string field, a truncated
    // fingerprint) is a path-qualified usage error, never a JSONException or
    // a bounds error further down.
    string field(string key, bool required)
    {
        auto v = key in j.objectNoRef;
        if (v is null)
        {
            if (required)
                throw new ExtensionException(path ~ ": missing \"" ~ key
                    ~ "\" (run `d8ctl extension remove " ~ name ~ "` and `extension add`)");
            return null;
        }
        if (v.type != JSONType.string)
            throw new ExtensionException(path ~ ": \"" ~ key ~ "\" must be a string");
        return v.str;
    }
    Manifest m;
    m.name = name;
    m.specUrl = field("specUrl", true);
    m.baseUrl = field("baseUrl", true);
    // Absent (older manifests): treat as explicit, never silently retarget.
    m.baseUrlFromSpec = field("baseUrlSource", false) == "spec";
    m.sha256 = field("sha256", true);
    if (!isSha256Hex(m.sha256))
        throw new ExtensionException(path ~ ": \"sha256\" must be 64 lowercase hex digits");
    m.profile = field("profile", false);
    if (auto rel = "relative" in j.objectNoRef)
    {
        if (rel.type != JSONType.true_ && rel.type != JSONType.false_)
            throw new ExtensionException(path ~ ": \"relative\" must be a boolean");
        m.relative = rel.type == JSONType.true_;
    }
    if (m.relative && (!isRelativeRef(m.specUrl) || (m.baseUrl.length && !isRelativeRef(m.baseUrl))))
        throw new ExtensionException(path ~ ": a relative extension needs root-relative "
            ~ "\"specUrl\" and \"baseUrl\" paths");
    m.etag = field("etag", false);
    m.fetchedAt = field("fetchedAt", false);
    m.d8ctlVersion = field("d8ctlVersion", false);
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

/// Create `dir`; false when it already exists (or can't be made). The
/// mkdir is the atomic test-and-set behind `withExtensionLock`. Phobos
/// reports failure as FileException on POSIX but WindowsException (not a
/// FileException) on Windows.
private bool tryMkdir(string dir)
{
    import std.file : FileException, mkdir;

    version (Windows)
    {
        import std.windows.syserror : WindowsException;

        try
            mkdir(dir);
        catch (FileException)
            return false;
        catch (WindowsException)
            return false;
    }
    else
    {
        try
            mkdir(dir);
        catch (FileException)
            return false;
    }
    return true;
}

/// Hold `<extensions>/.<name>.lock` (an exclusive mkdir) while `fn` runs,
/// so concurrent add/update/remove of one extension serialize instead of
/// interleaving their cache commits.
private T withExtensionLock(T)(string cfgDir, string name, scope T delegate() @safe fn)
{
    requireExtensionName(name); // a lock path is only ever built from a canonical name
    import std.file : rmdirRecurse;
    import std.path : buildPath;

    makePrivateDir(extensionsRoot(cfgDir));
    auto lock = buildPath(extensionsRoot(cfgDir), "." ~ name ~ ".lock");
    if (!tryMkdir(lock))
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
    const string[string] switches = null, const Header[] headers = null,
    string envProfile = null)
{
    import d8ctl.version_ : cliVersion;

    auto sub = args.length ? args[0] : "list";
    auto rest = args.length ? args[1 .. $] : (string[]).init;

    string takeFlag(string key)
    {
        auto v = named.get(key, null);
        return v;
    }

    // Fail closed on flags a subcommand does not understand: a typo or a
    // valueless `--base-url` must not silently install with defaults.
    void allowFlags(const string[] valued, const string[] switches_)
    {
        foreach (k, _; named)
            if (!valued.canFind(k))
                throw new ExtensionException("extension " ~ sub ~ ": unknown flag --" ~ k);
        foreach (k, _; bare)
        {
            if (valued.canFind(k))
                throw new ExtensionException("flag --" ~ k ~ " needs a value (--" ~ k ~ "=…)");
            if (!switches_.canFind(k))
                throw new ExtensionException("extension " ~ sub ~ ": unknown flag --" ~ k);
        }
    }

    switch (sub)
    {
    case "add", "list", "ls", "update", "remove", "rm", "delete":
        break;
    default:
        throw new ExtensionException("unknown extension command '" ~ sub
            ~ "'. See `d8ctl extension --help`.");
    }
    switch (sub)
    {
    case "add":
        allowFlags(["spec", "base-url", "profile"], null);
        if (rest.length != 1)
            throw new ExtensionException(
                "usage: d8ctl extension add <name> --spec=<url|/path> [--base-url=<url|/path>] [--profile=<name>]");
        auto name = rest[0];
        requireExtensionName(name);
        if (listExtensionNames(cfgDir).canFind(name))
            throw new ExtensionException("extension '" ~ name
                ~ "' is already installed. Use `d8ctl extension update " ~ name
                ~ "` to refresh it or `extension remove " ~ name ~ "` first (there is no --force).");
        auto specUrl = takeFlag("spec");
        if (!specUrl.length)
            throw new ExtensionException("extension add needs --spec=<url>");
        auto baseOverride = takeFlag("base-url");
        const relative = isRelativeRef(specUrl);
        if (!relative && baseOverride.length && isRelativeRef(baseOverride))
            throw new ExtensionException("--base-url=" ~ baseOverride ~ " is a path: use a path "
                ~ "for --spec too (a profile-relative extension), or give a full --base-url");
        if (relative && baseOverride.length && !isRelativeRef(baseOverride))
            throw new ExtensionException("--spec=" ~ specUrl ~ " is a path (profile-relative), "
                ~ "so --base-url must be a path too (e.g. --base-url=/api)");
        string profile, fetchUrl, origin;
        if (relative)
        {
            // The route is chosen per call; the profile used here only fetches.
            auto route = relativeRoute(sources, profileFlag, envProfile);
            profile = route.profile;
            origin = route.origin;
            fetchUrl = origin ~ specUrl;
        }
        else
        {
            profile = takeFlag("profile").length ? takeFlag("profile") : profileFlag;
            requireExtensionProfile(sources, profile);
            fetchUrl = specUrl;
        }
        auto got = fetch(fetchUrl, null, extensionConnection(sources, profile, switches, headers));
        if (got.notModified || !got.body_.length)
            throw new ExtensionException("the server returned no spec for " ~ fetchUrl);
        // Untrusted input: the hardened reader's limits apply; a bad spec
        // stops the add and leaves any existing cache untouched.
        Catalog cat;
        try
            cat = buildCatalog(got.body_, null, name);
        catch (OpenApiException e)
            throw new ExtensionException("the spec at " ~ fetchUrl ~ " is not usable: " ~ e.msg);
        Manifest m;
        m.name = name;
        m.specUrl = specUrl;
        m.relative = relative;
        if (baseOverride.length)
            m.baseUrl = stripRightSlash(baseOverride);
        else if (relative)
            m.baseUrl = relativeBase(got.body_, fetchUrl, origin);
        else
            m.baseUrl = resolveBaseUrl(got.body_, specUrl);
        m.baseUrlFromSpec = !baseOverride.length;
        m.profile = relative ? null : profile;
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
            ~ " commands) from " ~ fetchUrl ~ "\n  base URL: " ~ m.baseUrl
            ~ (relative ? " (relative: follows --profile / D8CTL_PROFILE / the active profile; now "
                ~ baseUrlFor(m, origin) ~ " via '" ~ profile ~ "')" : "")
            ~ "\n  sha256:   " ~ m.sha256[0 .. 12] ~ "…\nTry: d8ctl " ~ name ~ " --help\n";

    case "list", "ls":
        allowFlags(null, ["check"]);
        if (rest.length)
            throw new ExtensionException("usage: d8ctl extension list [--check]");
        auto names = listExtensionNames(cfgDir);
        if (!names.length)
            return "No extensions. Add one: d8ctl extension add <name> --spec=<url> [--profile=<name>]\n";
        auto buf = appender!string();
        foreach (n; names)
        {
            auto m = readManifest(cfgDir, n);
            buf.put(n ~ "  " ~ m.baseUrl ~ "  sha256:" ~ m.sha256[0 .. 12]
                ~ "…  fetched " ~ m.fetchedAt);
            if (m.relative)
                buf.put("  relative to the selected profile");
            else if (m.profile.length)
                buf.put("  profile " ~ m.profile);
            if ("check" in bare)
            {
                string conn, origin;
                if (m.relative)
                {
                    auto route = relativeRoute(sources, profileFlag, envProfile);
                    conn = route.profile;
                    origin = route.origin;
                }
                else
                    conn = profileFlag.length ? profileFlag : m.profile;
                auto got = fetch(specUrlFor(m, origin), m.etag, extensionConnection(sources,
                    conn, switches, headers));
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
        allowFlags(null, ["all"]);
        string[] names;
        if ("all" in bare && rest.length)
            throw new ExtensionException("extension update: give either <name> or --all, not both");
        if ("all" in bare)
            names = listExtensionNames(cfgDir);
        else if (rest.length == 1)
        {
            requireExtensionName(rest[0]); // before any lock path is built
            names = [rest[0]];
        }
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
                // A relative extension stores no profile: the route is chosen
                // per call, so it fetches through the selected one.
                string conn = m.profile, origin;
                if (m.relative)
                {
                    auto route = relativeRoute(sources, profileFlag, envProfile);
                    conn = route.profile;
                    origin = route.origin;
                }
                else if (profileFlag.length)
                    m.profile = conn = profileFlag;
                const fetchUrl = specUrlFor(m, origin);
                // A corrupt cached spec must be repaired, not reported as up
                // to date: verify the cached bytes first, and only revalidate
                // (ETag / sha256 skip) when they still match the manifest.
                bool cachedOk;
                {
                    import std.file : readText;
                    import std.path : buildPath;

                    auto sp = buildPath(generationDir(cfgDir, n), "spec.json");
                    try
                        cachedOk = exists(sp) && sha256Hex(readText(sp)) == m.sha256;
                    catch (Exception)
                        cachedOk = false;
                }
                auto got = fetch(fetchUrl, cachedOk ? m.etag : null,
                    extensionConnection(sources, conn, switches, headers));
                // A concurrent `remove` could not have run (we hold the lock),
                // but a stale reader of this code path could: re-verify the
                // install still names the generation we read before committing.
                if (!exists(extensionDir(cfgDir, n)))
                    throw new ExtensionException("extension '" ~ n
                        ~ "' was removed while updating; nothing was installed.");
                if (got.notModified && cachedOk)
                    return n ~ ": up to date (ETag matched)\n";
                if (got.notModified || !got.body_.length)
                    throw new ExtensionException("the server returned no spec for " ~ fetchUrl);
                const hash = sha256Hex(got.body_);
                if (hash == m.sha256 && cachedOk)
                {
                    // Persist a new/changed validator so later updates can revalidate.
                    if (got.etag != m.etag)
                    {
                        m.etag = got.etag;
                        m.fetchedAt = nowIso();
                        install(cfgDir, m, got.body_);
                    }
                    return n ~ ": up to date (sha256 " ~ hash[0 .. 12] ~ "…)\n";
                }
                Catalog cat;
                try
                    cat = buildCatalog(got.body_, null, n);
                catch (OpenApiException e)
                    throw new ExtensionException("the new spec at " ~ fetchUrl
                        ~ " is not usable: " ~ e.msg ~ " (the installed copy was kept)");
                m.sha256 = hash;
                m.etag = got.etag;
                m.fetchedAt = nowIso();
                m.d8ctlVersion = cliVersion;
                // A spec-derived base follows the new spec's servers; an explicit
                // --base-url is kept.
                if (m.relative && m.baseUrlFromSpec)
                    m.baseUrl = relativeBase(got.body_, fetchUrl, origin);
                else if (!m.relative && (m.baseUrlFromSpec || !m.baseUrl.length))
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
        allowFlags(null, null);
        if (rest.length != 1)
            throw new ExtensionException("usage: d8ctl extension remove <name>");
        auto name = rest[0];
        requireExtensionName(name);
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
    buf.put("  d8ctl extension add <name> --spec=<url|/path> [--base-url=<url|/path>] [--profile=<name>]\n");
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
    buf.put("--header apply on top; spec downloads use the same connection.\n\n");
    buf.put("Profile-relative: give --spec (and --base-url) as paths, e.g.\n");
    buf.put("  d8ctl extension add nwf --spec=/console/app-view/Workforce/app/api-docs/openapi.json\n");
    buf.put("Each call then resolves them against the origin of the selected profile's\n");
    buf.put("REST address (--profile, else D8CTL_PROFILE, else the active profile), and\n");
    buf.put("uses that profile's auth — so one extension follows the route a profile\n");
    buf.put("names. Credentials go only to the profile's own host.\n");
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

    private FetchResult etagFetchImpl(string url, string etag, string[string] conn) @safe
    {
        return FetchResult(fakeBody, "\"v2\"", false);
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
    import d8ctl.safeio : envNames, getEnv, setEnv;

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

// Review round 5: fail-closed subcommand flags, corrupt manifests, corrupt
// cached spec repaired by update, environment masking by prefix.
unittest
{
    import std.exception : assertThrown, collectExceptionMsg;
    import std.file : write;
    import std.path : buildPath;
    import std.string : indexOf, replace;

    auto dir = testDir("round5");
    scope (exit)
        cleanupDir(dir);
    auto sources = Sources.init;

    // Unknown / valueless flags and conflicting update targets are refused.
    auto msg = collectExceptionMsg!ExtensionException(extensionCommand(dir, sources, ["add", "t"],
        ["spec": "http://h/o.json"], ["base-url": true], fakeFetch(xcliSpec)));
    assert(msg.indexOf("needs a value") >= 0, msg);
    assertThrown!ExtensionException(extensionCommand(dir, sources, ["add", "t"],
        ["spec": "http://h/o.json", "bse-url": "x"], null, fakeFetch(xcliSpec)));
    extensionCommand(dir, sources, ["add", "t"], ["spec": "http://h/o.json"], null, fakeFetch(xcliSpec));
    assertThrown!ExtensionException(extensionCommand(dir, sources, ["update", "t"], null,
        ["all": true], fakeFetch(xcliSpec)));
    assertThrown!ExtensionException(extensionCommand(dir, sources, ["list"], null,
        ["chek": true], fakeFetch(xcliSpec)));
    assertThrown!ExtensionException(extensionCommand(dir, sources, ["remove", "t"],
        ["force": "1"], null, fakeFetch(xcliSpec)));

    // A corrupt cached spec with an unchanged server is repaired, not "up to date".
    write(specPath(dir, "t"), "garbage");
    auto fixed = extensionCommand(dir, sources, ["update", "t"], null, null, fakeFetch(xcliSpec));
    assert(fixed.indexOf("updated to sha256") >= 0, fixed);
    assert(loadExtension(dir, "t").catalog.commands.length);

    // Corrupt-but-valid manifests are usage errors, never JSON/bounds errors.
    foreach (bad; [`{}`, `{"specUrl": 1, "baseUrl": "b", "sha256": "x"}`,
            `{"specUrl": "s", "baseUrl": "b", "sha256": "abc"}`,
            `{"specUrl": "s", "baseUrl": "b", "sha256": "` ~ sha256Hex("") ~ `", "profile": 3}`])
    {
        write(manifestPath(dir, "t"), bad);
        assertThrown!ExtensionException(readManifest(dir, "t"), bad);
        assertThrown!ExtensionException(extensionCommand(dir, sources, ["list"], null, null,
            fakeFetch(xcliSpec)), bad);
    }
}

unittest
{
    import d8ctl.safeio : getEnv, setEnv;

    // Any CAMUNDA_* key (not just a fixed list) is hidden from the SDK while
    // an extension transport is built, and restored afterwards.
    setEnv("CAMUNDA_OAUTH_CACHE_DIR", "/cluster/cache");
    setEnv("CAMUNDA_SOME_FUTURE_KEY", "x");
    scope (exit)
    {
        setEnv("CAMUNDA_OAUTH_CACHE_DIR", null);
        setEnv("CAMUNDA_SOME_FUTURE_KEY", null);
    }
    auto t = extensionTransport(["CAMUNDA_AUTH_STRATEGY": "NONE"]);
    assert(t.config.oauthCacheDir != "/cluster/cache");
    assert(getEnv("CAMUNDA_OAUTH_CACHE_DIR") == "/cluster/cache");
    assert(getEnv("CAMUNDA_SOME_FUTURE_KEY") == "x");
}

unittest
{
    import d8ctl.help : resourceHelp;
    import std.string : indexOf;

    // HEAD/OPTIONS/TRACE are never advertised (the transport cannot send
    // them); default positionals follow URL placeholder order; an explicit
    // x-cli group sharing a derived resource word stays visible in help.
    enum spec = `{"openapi": "3.0.0", "info": {"title": "t", "version": "1"}, "paths": {
      "/p/{parentId}/c/{childId}": {
        "get": {"operationId": "getPr", "parameters": [
          {"name": "childId", "in": "path", "required": true, "schema": {"type": "string"}},
          {"name": "parentId", "in": "path", "required": true, "schema": {"type": "string"}}],
          "responses": {"200": {"description": "ok"}}},
        "head": {"operationId": "headPr", "responses": {"200": {"description": "ok"}}},
        "options": {"operationId": "optionsPr", "responses": {"200": {"description": "ok"}}}},
      "/cancel": {"post": {"operationId": "cancelRun", "x-cli": {"command": ["pr", "run", "cancel"]},
        "responses": {"200": {"description": "ok"}}}}}}`;
    auto cat = new Catalog;
    *cat = buildCatalog(spec, null, "t");
    assert(cat.commands.length == 2, cat.commands.length.to!string);
    foreach (c; cat.commands)
    {
        assert(c.method == "GET" || c.method == "POST", c.method);
        if (c.operationId == "getPr")
            assert(c.pathParams == ["parentId", "childId"], c.pathParams.to!string);
    }
    import d8ctl.catalog : overlayRows;

    auto rows = overlayRows(cat);
    auto h = resourceHelp("t", "pr", cat, rows);
    assert(h.indexOf("get") >= 0 && h.indexOf("pr run cancel") >= 0, h);
}

unittest
{
    // update/remove validate the name before building a lock path, and an
    // unchanged spec with a new ETag persists the validator.
    import std.exception : assertThrown;

    auto dir = testDir("round6");
    scope (exit)
        cleanupDir(dir);
    auto sources = Sources.init;
    extensionCommand(dir, sources, ["add", "t"], ["spec": "http://h/openapi.json"],
        null, fakeFetch(xcliSpec));
    foreach (bad; ["./t", "../t", "T", "t/"])
    {
        assertThrown!ExtensionException(extensionCommand(dir, sources, ["update", bad], null,
            null, fakeFetch(xcliSpec)));
        assertThrown!ExtensionException(extensionCommand(dir, sources, ["remove", bad], null,
            null, fakeFetch(xcliSpec)));
    }
    assert(readManifest(dir, "t").etag == "");
    auto out_ = extensionCommand(dir, sources, ["update", "t"], null, null, &etagFetchImpl);
    assert(out_.indexOf("up to date") >= 0, out_);
    assert(readManifest(dir, "t").etag == "\"v2\"");
}

version (unittest)
{
    private string routeUrl, routeUser, routeStrategy;

    private FetchResult routeFetch(string url, string etag, string[string] conn) @safe
    {
        routeUrl = url;
        routeUser = conn.get("CAMUNDA_BASIC_AUTH_USERNAME", null);
        routeStrategy = conn.get("CAMUNDA_AUTH_STRATEGY", null);
        return FetchResult(fakeBody, null, false);
    }
}

unittest
{
    // #25: a profile-relative extension follows --profile > D8CTL_PROFILE >
    // the active profile, resolves its paths against that profile's origin,
    // and sends that profile's credentials only to that origin.
    import std.exception : assertThrown;

    Sources sources;
    sources.store.profiles["home"] = ["CAMUNDA_REST_ADDRESS": "http://lan:8080"];
    sources.store.profiles["away"] = ["CAMUNDA_REST_ADDRESS": "https://ts.example/v2",
        "CAMUNDA_BASIC_AUTH_USERNAME": "u", "CAMUNDA_BASIC_AUTH_PASSWORD": "p"];
    sources.store.profiles["noaddr"] = ["CAMUNDA_AUTH_STRATEGY": "NONE"];
    sources.store.active = "home";

    assert(relativeRoute(sources, null, null) == Route("home", "http://lan:8080"));
    assert(relativeRoute(sources, null, "away") == Route("away", "https://ts.example"));
    assert(relativeRoute(sources, "home", "away") == Route("home", "http://lan:8080"));
    assertThrown!ExtensionException(relativeRoute(sources, "nope", null));
    assertThrown!ExtensionException(relativeRoute(sources, "noaddr", null));
    Sources none;
    assertThrown!ExtensionException(relativeRoute(none, null, null));

    assert(isRelativeRef("/a") && !isRelativeRef("//h/a") && !isRelativeRef("http://h/a")
        && !isRelativeRef("a"));

    auto dir = testDir("rel");
    scope (exit)
        cleanupDir(dir);
    fakeBody = xcliSpec; // servers: [{"url": "api"}]

    // add through the active profile; nothing about the route is stored.
    auto added = extensionCommand(dir, sources, ["add", "w"],
        ["spec": "/app/api-docs/openapi.json"], null, &routeFetch);
    assert(routeUrl == "http://lan:8080/app/api-docs/openapi.json" && routeStrategy == "NONE", routeUrl);
    assert(added.indexOf("http://lan:8080/app/api via 'home'") >= 0, added);
    auto m = readManifest(dir, "w");
    assert(m.relative && m.specUrl == "/app/api-docs/openapi.json" && m.baseUrl == "/app/api");
    assert(!m.profile.length && m.baseUrlFromSpec);
    assert(baseUrlFor(m, "https://ts.example") == "https://ts.example/app/api");
    assert(specUrlFor(m, "http://lan:8080") == "http://lan:8080/app/api-docs/openapi.json");

    // update via --profile: the other route, with its own credentials; the
    // profile is not stored, so the next call follows the active one again.
    fakeBody = xcliSpec.replace(`"T"`, `"T2"`);
    auto upd = extensionCommand(dir, sources, ["update", "w"], null, null, &routeFetch, "away");
    assert(upd.indexOf("updated") >= 0, upd);
    assert(routeUrl == "https://ts.example/app/api-docs/openapi.json", routeUrl);
    assert(routeStrategy == "BASIC" && routeUser == "u");
    m = readManifest(dir, "w");
    assert(!m.profile.length && m.baseUrl == "/app/api" && m.sha256 == sha256Hex(fakeBody));

    // list --check through D8CTL_PROFILE.
    auto listed = extensionCommand(dir, sources, ["list"], null, ["check": true], &routeFetch,
        null, null, null, "away");
    assert(listed.indexOf("relative to the selected profile") >= 0
        && listed.indexOf("[up to date]") >= 0, listed);
    assert(routeUrl.startsWith("https://ts.example/"), routeUrl);

    // An explicit path base is kept; the root base is the origin itself.
    extensionCommand(dir, sources, ["add", "x"], ["spec": "/o.json", "base-url": "/"], null,
        &routeFetch);
    m = readManifest(dir, "x");
    assert(m.baseUrl == "" && baseUrlFor(m, "http://lan:8080") == "http://lan:8080");

    // Mixing a path with a full URL, or a spec server on another host, fails.
    assertThrown!ExtensionException(extensionCommand(dir, sources, ["add", "y"],
        ["spec": "/o.json", "base-url": "http://elsewhere/api"], null, &routeFetch));
    assertThrown!ExtensionException(extensionCommand(dir, sources, ["add", "y"],
        ["spec": "http://h/o.json", "base-url": "/api"], null, &routeFetch));
    fakeBody = xcliSpec.replace(`"url": "api"`, `"url": "https://other.example/api"`);
    assertThrown!ExtensionException(extensionCommand(dir, sources, ["add", "y"],
        ["spec": "/o.json"], null, &routeFetch));
    // No profile selected at all: a usage error, never a request to "".
    routeUrl = null;
    assertThrown!ExtensionException(extensionCommand(dir, none, ["add", "y"],
        ["spec": "/o.json"], null, &routeFetch));
    assert(routeUrl is null);

    // An absolute extension still never takes a profile's address.
    fakeBody = xcliSpec;
    extensionCommand(dir, sources, ["add", "abs"], ["spec": "http://h/o.json"], null, &routeFetch,
        "away");
    m = readManifest(dir, "abs");
    assert(!m.relative && m.baseUrl == "http://h/api" && m.profile == "away");
    assert(baseUrlFor(m, "https://ts.example") == "http://h/api");
}

version (unittest)
{
    /// One connection per request (`Connection: close`): the first `fail`
    /// connections are dropped after the request head (`status == 0`, a
    /// network error) or answered with `status`; later ones get 200 `body_`.
    /// Sends the port on `out_`, then the number of connections accepted.
    private void flakyServer(int fail, int serve, int status, string body_, Chan!int out_)
    {
        import std.conv : to;
        import std.socket : InternetAddress, SocketOption, SocketOptionLevel, TcpSocket;
        import std.string : indexOf;

        auto listener = new TcpSocket();
        scope (exit)
            listener.close();
        listener.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);
        listener.bind(new InternetAddress("127.0.0.1", InternetAddress.PORT_ANY));
        listener.listen(8);
        out_.put((cast(InternetAddress) listener.localAddress).port);
        int accepted;
        foreach (i; 0 .. fail + serve)
        {
            auto c = listener.accept();
            accepted++;
            string head;
            ubyte[4096] chunk;
            while (head.indexOf("\r\n\r\n") < 0)
            {
                const n = c.receive(chunk[]);
                if (n <= 0)
                    break;
                head ~= cast(const(char)[]) chunk[0 .. n];
            }
            if (i < fail && status == 0)
            {
                c.close(); // dropped mid-request: an empty reply
                continue;
            }
            const code = i < fail ? status : 200;
            const text = i < fail ? "" : body_;
            c.send("HTTP/1.1 " ~ code.to!string ~ " X\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: "
                ~ text.length.to!string ~ "\r\n\r\n" ~ text);
            c.close();
        }
        out_.put(accepted);
    }

    /// Accepts `n` connections and closes each at once, before any
    /// ServerHello: an https client sees a TLS connect error (the Funnel
    /// drop of #29). Sends the port, then the number accepted.
    private void tlsRefuser(int n, Chan!int out_)
    {
        import std.socket : InternetAddress, SocketOption, SocketOptionLevel, TcpSocket;

        auto listener = new TcpSocket();
        scope (exit)
            listener.close();
        listener.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);
        listener.bind(new InternetAddress("127.0.0.1", InternetAddress.PORT_ANY));
        listener.listen(8);
        out_.put((cast(InternetAddress) listener.localAddress).port);
        int accepted;
        foreach (i; 0 .. n)
        {
            auto c = listener.accept();
            accepted++;
            c.close();
        }
        out_.put(accepted);
    }

    import camunda.safeio : Chan;

    private int startFlaky(int fail, int serve, int status, string body_, Chan!int ch)
    {
        import camunda.safeio : spawn;

        spawn(&flakyServer, fail, serve, status, body_, ch);
        int port;
        ch.take(port);
        return port;
    }
}

/// Retries are real, not assumed (agent feedback on Funnel drops): API calls
/// and spec downloads both survive dropped connections and 503s, honour
/// CAMUNDA_SDK_HTTP_RETRY_MAX_ATTEMPTS, and give up after it.
unittest
{
    import camunda.errors : NetworkException;
    import camunda.transport : ServerBase;
    import std.conv : to;
    import std.exception : assertThrown;
    import std.json : JSONValue;

    string[string] conn(int port, int attempts)
    {
        return [
            "CAMUNDA_REST_ADDRESS": "http://127.0.0.1:" ~ port.to!string,
            "CAMUNDA_AUTH_STRATEGY": "NONE",
            "CAMUNDA_SDK_HTTP_RETRY_BASE_DELAY_MS": "1",
            "CAMUNDA_SDK_HTTP_RETRY_MAX_DELAY_MS": "5",
            "CAMUNDA_SDK_HTTP_RETRY_MAX_ATTEMPTS": attempts.to!string,
        ];
    }

    int accepted;

    // An API call: two dropped connections, then an answer on the third try.
    auto ch = Chan!int.make;
    auto port = startFlaky(2, 1, 0, `{"ok":true}`, ch);
    auto got = extensionTransport(conn(port, 3)).requestJson("GET", "/ping", JSONValue(null), null, ServerBase.root);
    assert(got["ok"].boolean);
    ch.take(accepted);
    assert(accepted == 3, accepted.to!string);

    // Out of attempts: the network error surfaces after exactly that many.
    ch = Chan!int.make;
    port = startFlaky(2, 0, 0, "", ch);
    assertThrown!NetworkException(extensionTransport(conn(port, 2))
        .requestJson("GET", "/ping", JSONValue(null), null, ServerBase.root));
    ch.take(accepted);
    assert(accepted == 2, accepted.to!string);

    // A spec download: a dropped connection, then a 503, then the spec.
    ch = Chan!int.make;
    port = startFlaky(1, 0, 0, "", ch);
    auto url = "http://127.0.0.1:" ~ port.to!string ~ "/openapi.json";
    // With one attempt allowed, a single drop is fatal: no hidden retries.
    assertThrown!ExtensionException(fetchSpecHttp(url, "", conn(port, 1)));
    ch.take(accepted);
    assert(accepted == 1);

    ch = Chan!int.make;
    port = startFlaky(2, 1, 503, `{"openapi":"3.0.3"}`, ch);
    url = "http://127.0.0.1:" ~ port.to!string ~ "/openapi.json";
    auto r = fetchSpecHttp(url, "", conn(port, 3));
    assert(r.body_ == `{"openapi":"3.0.3"}`, r.body_);
    ch.take(accepted);
    assert(accepted == 3, accepted.to!string);

    ch = Chan!int.make;
    port = startFlaky(2, 1, 0, `{"openapi":"3.0.3"}`, ch);
    url = "http://127.0.0.1:" ~ port.to!string ~ "/openapi.json";
    r = fetchSpecHttp(url, "", conn(port, 3));
    assert(r.body_ == `{"openapi":"3.0.3"}`);
    ch.take(accepted);
    assert(accepted == 3, accepted.to!string);

    // A persistent 503 is reported as such once the attempts run out.
    ch = Chan!int.make;
    port = startFlaky(2, 0, 503, "", ch);
    url = "http://127.0.0.1:" ~ port.to!string ~ "/openapi.json";
    try
    {
        fetchSpecHttp(url, "", conn(port, 2));
        assert(false);
    }
    catch (SpecDownloadException e)
    {
        assert(e.msg[$ - 8 .. $] == "HTTP 503", e.msg);
        // The retry statistics reach the error envelope.
        assert(e.stats !is null && e.stats.attempts == 2, e.stats.attempts.to!string);
        assert(e.stats.retried && e.stats.note.length);
    }
    ch.take(accepted);
    assert(accepted == 2, accepted.to!string);
}

/// #29: the CLI retry window. A drop-prone link survives with the d8ctl
/// defaults (6 attempts, ~10 s worst case), and on exhaustion the attempts
/// and their span are recorded for the error envelope — here for a TLS
/// handshake refused before ServerHello, like a Tailscale Funnel drop.
unittest
{
    import camunda.errors : NetworkException;
    import camunda.safeio : spawn;
    import camunda.transport : ServerBase;
    import d8ctl.dispatch : RetryStats, countedTransport, retrying;
    import std.conv : to;
    import std.json : JSONValue;
    import std.string : indexOf;

    int accepted;

    // Five drops then an answer: the SDK default (3 attempts) would fail,
    // the CLI default (6) succeeds well inside its window.
    auto ch = Chan!int.make;
    auto port = startFlaky(5, 1, 0, `{"ok":true}`, ch);
    string[string] conn = [
        "CAMUNDA_REST_ADDRESS": "http://127.0.0.1:" ~ port.to!string,
        "CAMUNDA_AUTH_STRATEGY": "NONE",
    ];
    auto stats = new RetryStats;
    auto client = countedTransport(conn, stats, (string[string] o) => extensionTransport(o));
    assert(stats.config.maxAttempts == 6 && stats.config.baseDelayMs == 250
        && stats.config.maxDelayMs == 4000);
    auto got = retrying!JSONValue(client, stats, "GET",
        () => client.requestJson("GET", "/ping", JSONValue(null), null, ServerBase.root));
    assert(got["ok"].boolean);
    ch.take(accepted);
    assert(accepted == 6, accepted.to!string);
    assert(stats.attempts == 6);
    // Worst case: 250 + 500 + 1000 + 2000 + 4000 ms of backoff.
    // elapsedMs covers the final backoff and the successful attempt too.
    assert(stats.elapsedMs > 0 && stats.elapsedMs < 7750 + 2000, stats.elapsedMs.to!string);

    // TLS refused on every attempt: the error comes after exactly the
    // configured attempts, and they are counted.
    ch = Chan!int.make;
    spawn(&tlsRefuser, 3, ch);
    ch.take(port);
    conn = [
        "CAMUNDA_REST_ADDRESS": "https://127.0.0.1:" ~ port.to!string,
        "CAMUNDA_AUTH_STRATEGY": "NONE",
        "CAMUNDA_SDK_HTTP_RETRY_BASE_DELAY_MS": "1",
        "CAMUNDA_SDK_HTTP_RETRY_MAX_DELAY_MS": "5",
        "CAMUNDA_SDK_HTTP_RETRY_MAX_ATTEMPTS": "3",
    ];
    stats = new RetryStats;
    client = countedTransport(conn, stats, (string[string] o) => extensionTransport(o));
    bool threw;
    try
        cast(void) retrying!JSONValue(client, stats, "POST",
            () => client.requestJson("POST", "/x", JSONValue(null), null, ServerBase.root));
    catch (NetworkException)
        threw = true;
    assert(threw);
    ch.take(accepted);
    assert(accepted == 3, accepted.to!string);
    assert(stats.attempts == 3 && stats.elapsedMs >= 0);
    assert(stats.note.indexOf("after 3 attempts over") >= 0, stats.note);
    assert(stats.note.indexOf("may have been applied") >= 0, stats.note);
}
