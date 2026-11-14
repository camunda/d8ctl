/// Read-only access to c8ctl profiles and Camunda Modeler connections, so
/// d8ctl can be dropped in where c8ctl is configured.
///
/// Mirrors c8ctl `src/core/config.ts` / `src/core/client.ts`:
///
/// - c8ctl data dir: `$C8CTL_DATA_DIR`, else `~/Library/Application Support/c8ctl`
///   (macOS), `%APPDATA%\c8ctl` (Windows), `$XDG_CONFIG_HOME/c8ctl` or
///   `~/.config/c8ctl`. `profiles.json` is `{"profiles": [{name, baseUrl, …}]}`;
///   `session.json` holds `activeProfile` / `activeTenant`.
/// - Modeler dir: `$C8CTL_MODELER_DIR`, else the same scheme with
///   `camunda-modeler`. `settings.json` key `connectionManagerPlugin.c8connections`.
///   Connections are addressed as `modeler:<name>`, `<name>`, or `<id>`.
/// - Auth: OAuth when client id + secret are present, else Basic when
///   username + password are, else none (c8ctl `createClient`).
///
/// Nothing here writes to c8ctl's or Modeler's files.
module d8ctl.compat;

@safe:

import std.json;
import std.string : startsWith, strip;

/// Where a profile came from.
enum Origin
{
    d8ctl,
    c8ctl,
    modeler,
}

string originLabel(Origin o)
{
    final switch (o)
    {
    case Origin.d8ctl: return "d8ctl";
    case Origin.c8ctl: return "c8ctl";
    case Origin.modeler: return "modeler";
    }
}

/// A profile from any source, as SDK config keys.
struct Profile
{
    string name;
    Origin origin;
    string[string] config;
    /// Settings that could not be carried over (shown by `profile show`).
    string[] notes;
    /// Modeler connection id (a Modeler connection can be selected by it).
    string id;
}

/// c8ctl's cluster settings (its `ClusterConfig`), before mapping to SDK keys.
struct ClusterSettings
{
    string baseUrl;
    string clientId;
    string clientSecret;
    string audience;
    string oAuthUrl;
    string oauthScope;
    string username;
    string password;
    string tenantId;
    bool exactBaseUrl;
}

/// The keys c8ctl's `createClient` would hand to its SDK.
string[string] toSdkConfig(const ref ClusterSettings c)
{
    string[string] m;
    if (c.baseUrl.length) m["CAMUNDA_REST_ADDRESS"] = c.baseUrl;
    if (c.clientId.length && c.clientSecret.length)
    {
        m["CAMUNDA_AUTH_STRATEGY"] = "OAUTH";
        m["CAMUNDA_CLIENT_ID"] = c.clientId;
        m["CAMUNDA_CLIENT_SECRET"] = c.clientSecret;
        if (c.audience.length) m["CAMUNDA_TOKEN_AUDIENCE"] = c.audience;
        if (c.oAuthUrl.length) m["CAMUNDA_OAUTH_URL"] = c.oAuthUrl;
        if (c.oauthScope.length) m["CAMUNDA_OAUTH_SCOPE"] = c.oauthScope;
    }
    else if (c.username.length && c.password.length)
    {
        m["CAMUNDA_AUTH_STRATEGY"] = "BASIC";
        m["CAMUNDA_BASIC_AUTH_USERNAME"] = c.username;
        m["CAMUNDA_BASIC_AUTH_PASSWORD"] = c.password;
    }
    else
        m["CAMUNDA_AUTH_STRATEGY"] = "NONE";
    if (c.tenantId.length) m["CAMUNDA_DEFAULT_TENANT_ID"] = c.tenantId;
    if (c.exactBaseUrl) m["CAMUNDA_REST_ADDRESS_EXACT"] = "true";
    return m;
}

private string str(const JSONValue o, string key)
{
    if (o.type != JSONType.object) return null;
    if (auto v = key in o.objectNoRef)
        if (v.type == JSONType.string) return v.str.strip;
    return null;
}

private bool flag(const JSONValue o, string key)
{
    if (o.type != JSONType.object) return false;
    if (auto v = key in o.objectNoRef) return v.type == JSONType.true_;
    return false;
}

/// One c8ctl `profiles.json` entry.
Profile fromC8ctlProfile(const JSONValue p)
{
    ClusterSettings c;
    c.baseUrl = str(p, "baseUrl");
    c.clientId = str(p, "clientId");
    c.clientSecret = str(p, "clientSecret");
    c.audience = str(p, "audience");
    c.oAuthUrl = str(p, "oAuthUrl");
    c.oauthScope = str(p, "scope");
    c.username = str(p, "username");
    c.password = str(p, "password");
    c.tenantId = str(p, "defaultTenantId");
    c.exactBaseUrl = flag(p, "exactBaseUrl");
    Profile r = Profile(str(p, "name"), Origin.c8ctl, toSdkConfig(c));
    // c8ctl Profile.headers → CAMUNDA_DEFAULT_HEADERS (string values only).
    if (auto h = "headers" in p.objectNoRef)
        if (h.type == JSONType.object && h.objectNoRef.length)
        {
            JSONValue o = JSONValue(string[string].init);
            foreach (k, v; h.objectNoRef)
            {
                if (v.type == JSONType.string) o[k] = v.str;
                else r.notes ~= "header '" ~ k ~ "' has a non-string value and is ignored";
            }
            if (o.objectNoRef.length) r.config["CAMUNDA_DEFAULT_HEADERS"] = o.toString;
        }
    return r;
}

/// One Modeler connection (c8ctl `connectionToProfile`), named `modeler:<name|id>`.
Profile fromModelerConnection(const JSONValue conn)
{
    ClusterSettings c;
    if (str(conn, "targetType") == "camundaCloud")
    {
        c.baseUrl = str(conn, "camundaCloudClusterUrl");
        c.clientId = str(conn, "camundaCloudClientId");
        c.clientSecret = str(conn, "camundaCloudClientSecret");
        c.audience = str(conn, "audience");
        c.oAuthUrl = str(conn, "oauthURL");
        if (!c.oAuthUrl.length) c.oAuthUrl = "https://login.cloud.camunda.io/oauth/token";
        c.oauthScope = str(conn, "scope");
    }
    else
    {
        c.baseUrl = str(conn, "contactPoint");
        if (!c.baseUrl.length) c.baseUrl = "http://localhost:8080/v2";
        auto auth = str(conn, "authType");
        if (auth == "basic")
        {
            c.username = str(conn, "basicAuthUsername");
            c.password = str(conn, "basicAuthPassword");
        }
        else if (auth == "oauth")
        {
            c.clientId = str(conn, "clientId");
            c.clientSecret = str(conn, "clientSecret");
            c.oAuthUrl = str(conn, "oauthURL");
            c.audience = str(conn, "audience");
            c.oauthScope = str(conn, "scope");
        }
    }
    c.tenantId = str(conn, "tenantId");
    auto label = str(conn, "name");
    if (!label.length) label = str(conn, "id");
    auto r = Profile(modelerPrefix ~ label, Origin.modeler, toSdkConfig(c));
    r.id = str(conn, "id");
    return r;
}

enum modelerPrefix = "modeler:";

private string platformDir(string envOverride, string app)
{
    import std.path : buildPath;
    import std.process : environment;

    auto o = environment.get(envOverride);
    if (o.length) return o;
    auto home = environment.get("HOME", ".");
    version (OSX)
        return buildPath(home, "Library", "Application Support", app);
    else version (Windows)
    {
        auto appData = environment.get("APPDATA");
        return buildPath(appData.length ? appData : buildPath(home, "AppData", "Roaming"), app);
    }
    else
    {
        auto xdg = environment.get("XDG_CONFIG_HOME");
        return buildPath(xdg.length ? xdg : buildPath(home, ".config"), app);
    }
}

/// c8ctl's data directory (c8ctl `getUserDataDir`).
string c8ctlDir()
{
    return platformDir("C8CTL_DATA_DIR", "c8ctl");
}

/// Camunda Modeler's data directory (c8ctl `getModelerDataDir`).
string modelerDir()
{
    return platformDir("C8CTL_MODELER_DIR", "camunda-modeler");
}

/// Parse a JSON file; missing → `JSONValue.init`. A file that exists but does
/// not parse is reported in `warnings` and treated as empty.
private JSONValue readJson(string path, ref string[] warnings)
{
    import std.file : exists, isFile, readText;

    if (!exists(path) || !isFile(path)) return JSONValue.init;
    try
        return parseJSON(readText(path));
    catch (Exception e)
    {
        warnings ~= path ~ " could not be read (" ~ e.msg ~ "); skipped";
        return JSONValue.init;
    }
}

/// Profiles from c8ctl's `profiles.json`.
Profile[] loadC8ctlProfiles(string dir, ref string[] warnings)
{
    import std.path : buildPath;

    Profile[] r;
    auto j = readJson(buildPath(dir, "profiles.json"), warnings);
    if (j.type != JSONType.object) return r;
    auto ps = "profiles" in j.objectNoRef;
    if (ps is null || ps.type != JSONType.array) return r;
    foreach (p; ps.arrayNoRef)
    {
        if (p.type != JSONType.object || !str(p, "name").length || !str(p, "baseUrl").length)
            continue;
        r ~= fromC8ctlProfile(p);
    }
    return r;
}

/// Connections from Modeler's `settings.json` (only those with an `id`, as c8ctl).
Profile[] loadModelerProfiles(string dir, ref string[] warnings)
{
    import std.path : buildPath;

    Profile[] r;
    auto j = readJson(buildPath(dir, "settings.json"), warnings);
    if (j.type != JSONType.object) return r;
    auto cs = "connectionManagerPlugin.c8connections" in j.objectNoRef;
    if (cs is null || cs.type != JSONType.array) return r;
    foreach (c; cs.arrayNoRef)
        if (str(c, "id").length) r ~= fromModelerConnection(c);
    return r;
}

/// c8ctl `session.json`: the profile and tenant selected with `c8 use …`.
struct C8ctlSession
{
    string activeProfile;
    string activeTenant;
}

C8ctlSession loadC8ctlSession(string dir, ref string[] warnings)
{
    import std.path : buildPath;

    C8ctlSession s;
    auto j = readJson(buildPath(dir, "session.json"), warnings);
    s.activeProfile = str(j, "activeProfile");
    s.activeTenant = str(j, "activeTenant");
    return s;
}

/// c8ctl's own environment variables (`CAMUNDA_BASE_URL`, `CAMUNDA_USERNAME`,
/// `CAMUNDA_PASSWORD`, plus the OAuth ones it shares with the SDK), mapped as
/// c8ctl maps them. Empty unless `CAMUNDA_BASE_URL` is set.
string[string] c8ctlEnvConfig(string delegate(string) @safe get)
{
    ClusterSettings c;
    c.baseUrl = get("CAMUNDA_BASE_URL");
    if (!c.baseUrl.length) return null;
    c.clientId = get("CAMUNDA_CLIENT_ID");
    c.clientSecret = get("CAMUNDA_CLIENT_SECRET");
    c.audience = get("CAMUNDA_TOKEN_AUDIENCE");
    c.oAuthUrl = get("CAMUNDA_OAUTH_URL");
    c.oauthScope = get("CAMUNDA_OAUTH_SCOPE");
    c.username = get("CAMUNDA_USERNAME");
    c.password = get("CAMUNDA_PASSWORD");
    return toSdkConfig(c);
}

unittest
{
    // c8ctl's seeded default profile.
    auto local = fromC8ctlProfile(parseJSON(
        `{"name":"local","baseUrl":"http://localhost:8080/v2","username":"demo","password":"demo"}`));
    assert(local.name == "local" && local.origin == Origin.c8ctl);
    assert(local.config["CAMUNDA_REST_ADDRESS"] == "http://localhost:8080/v2");
    assert(local.config["CAMUNDA_AUTH_STRATEGY"] == "BASIC");
    assert(local.config["CAMUNDA_BASIC_AUTH_USERNAME"] == "demo");

    // OAuth wins over Basic when both are present (c8ctl createClient).
    auto both = fromC8ctlProfile(parseJSON(`{"name":"b","baseUrl":"https://x","clientId":"i",
        "clientSecret":"s","username":"u","password":"p","audience":"a","oAuthUrl":"https://o",
        "defaultTenantId":"t1","exactBaseUrl":true,"headers":{"X-Api-Key":"k"}}`));
    assert(both.config["CAMUNDA_AUTH_STRATEGY"] == "OAUTH");
    assert("CAMUNDA_BASIC_AUTH_USERNAME" !in both.config);
    assert(both.config["CAMUNDA_TOKEN_AUDIENCE"] == "a");
    assert(both.config["CAMUNDA_DEFAULT_TENANT_ID"] == "t1");
    assert(both.config["CAMUNDA_REST_ADDRESS_EXACT"] == "true");
    assert(both.notes.length == 0);
    assert(parseJSON(both.config["CAMUNDA_DEFAULT_HEADERS"]) == parseJSON(`{"X-Api-Key":"k"}`));
    auto odd = fromC8ctlProfile(parseJSON(`{"name":"o","headers":{"A":"1","B":2}}`));
    assert(parseJSON(odd.config["CAMUNDA_DEFAULT_HEADERS"]) == parseJSON(`{"A":"1"}`));
    assert(odd.notes.length == 1);
    assert("CAMUNDA_DEFAULT_HEADERS" !in local.config);

    // Modeler: SaaS gets the default OAuth URL; self-hosted with no auth.
    auto saas = fromModelerConnection(parseJSON(`{"id":"u1","name":"prod","targetType":"camundaCloud",
        "camundaCloudClusterUrl":"https://bru-2.zeebe.camunda.io/c1","camundaCloudClientId":"i",
        "camundaCloudClientSecret":"s"}`));
    assert(saas.name == "modeler:prod" && saas.origin == Origin.modeler);
    assert(saas.config["CAMUNDA_OAUTH_URL"] == "https://login.cloud.camunda.io/oauth/token");
    assert(saas.config["CAMUNDA_AUTH_STRATEGY"] == "OAUTH");
    auto c8run = fromModelerConnection(parseJSON(`{"id":"u2","name":"c8run (local)",
        "targetType":"selfHosted","authType":"none","contactPoint":"http://localhost:8080/v2",
        "tenantId":"t"}`));
    assert(c8run.config["CAMUNDA_AUTH_STRATEGY"] == "NONE");
    assert(c8run.config["CAMUNDA_DEFAULT_TENANT_ID"] == "t");
    auto unnamed = fromModelerConnection(parseJSON(`{"id":"u3","targetType":"selfHosted","authType":"basic",
        "basicAuthUsername":"u","basicAuthPassword":"p"}`));
    assert(unnamed.name == "modeler:u3");
    assert(unnamed.config["CAMUNDA_REST_ADDRESS"] == "http://localhost:8080/v2");
    assert(unnamed.config["CAMUNDA_AUTH_STRATEGY"] == "BASIC");

    // c8ctl env vars.
    string[string] env = ["CAMUNDA_BASE_URL": "http://e/v2", "CAMUNDA_USERNAME": "u", "CAMUNDA_PASSWORD": "p"];
    auto ec = c8ctlEnvConfig((string k) => k in env ? env[k] : null);
    assert(ec["CAMUNDA_REST_ADDRESS"] == "http://e/v2" && ec["CAMUNDA_AUTH_STRATEGY"] == "BASIC");
    string[string] none;
    assert(c8ctlEnvConfig((string k) => k in none ? none[k] : null) is null);
}
