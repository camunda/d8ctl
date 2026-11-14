/// Connection profiles and explicit `--camunda-*` config switches.
///
/// A profile is a named map of SDK config keys (`CAMUNDA_REST_ADDRESS`,
/// `CAMUNDA_CLIENT_ID`, …), stored in `profiles.json` in the d8ctl config
/// directory. A `--camunda-<key>=<value>` switch sets the same key for one
/// command. Precedence, highest first:
///
///   1. `--camunda-*` switches
///   2. the selected profile (`--profile`, else `D8CTL_PROFILE`, else the active one)
///   3. `CAMUNDA_*` environment variables
///   4. SDK defaults
///
/// Layers 1–2 become the overrides passed to `Transport.fromEnv`, which
/// resolves layers 3–4.
module d8ctl.profiles;

@safe:

import std.algorithm : canFind, sort;
import std.array : appender, array;
import std.format : format;
import std.json;
import std.string : indexOf, replace, startsWith, toLower, toUpper;

/// Bad profile command, unknown profile, or unknown config switch (exit 2).
class ProfileException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow @nogc @safe
    {
        super(msg, file, line);
    }
}

/// SDK config keys a CLI invocation can set. Mirrors the `CAMUNDA_*` keys read
/// by `camunda.config` in the D SDK, minus the job-worker settings.
immutable string[] configKeys = [
    "CAMUNDA_REST_ADDRESS",
    "CAMUNDA_REST_ADDRESS_EXACT",
    "CAMUNDA_AUTH_STRATEGY",
    "CAMUNDA_CLIENT_ID",
    "CAMUNDA_CLIENT_SECRET",
    "CAMUNDA_CLIENT_AUTH_CLIENTID",
    "CAMUNDA_CLIENT_AUTH_CLIENTSECRET",
    "CAMUNDA_OAUTH_URL",
    "CAMUNDA_OAUTH_SCOPE",
    "CAMUNDA_OAUTH_CACHE_DIR",
    "CAMUNDA_TOKEN_AUDIENCE",
    "CAMUNDA_BASIC_AUTH_USERNAME",
    "CAMUNDA_BASIC_AUTH_PASSWORD",
    "CAMUNDA_DEFAULT_TENANT_ID",
    "CAMUNDA_TENANT_ID",
    "CAMUNDA_TENANT_IDS",
    "CAMUNDA_MTLS_CA",
    "CAMUNDA_MTLS_CA_PATH",
    "CAMUNDA_MTLS_CERT",
    "CAMUNDA_MTLS_CERT_PATH",
    "CAMUNDA_MTLS_KEY",
    "CAMUNDA_MTLS_KEY_PATH",
    "CAMUNDA_MTLS_KEY_PASSPHRASE",
    "CAMUNDA_SDK_LOG_LEVEL",
    "CAMUNDA_SDK_BACKPRESSURE_PROFILE",
    "CAMUNDA_SDK_EVENTUAL_POLL_DEFAULT_MS",
    "CAMUNDA_SDK_HTTP_RETRY_BASE_DELAY_MS",
    "CAMUNDA_SDK_HTTP_RETRY_MAX_ATTEMPTS",
    "CAMUNDA_SDK_HTTP_RETRY_MAX_DELAY_MS",
];

/// `rest-address` → `CAMUNDA_REST_ADDRESS` (the part after `--camunda-`).
string switchToKey(string suffix)
{
    return "CAMUNDA_" ~ suffix.replace("-", "_").toUpper;
}

/// `CAMUNDA_REST_ADDRESS` → `--camunda-rest-address`.
string keyToSwitch(string key)
{
    return "--" ~ key.replace("_", "-").toLower;
}

/// Throw unless `key` is a supported config key.
void requireKnownKey(string key)
{
    if (configKeys.canFind(key)) return;
    throw new ProfileException("unknown config switch " ~ keyToSwitch(key)
        ~ ". See `d8ctl profile --help` for the supported --camunda-* switches.");
}

/// True for keys whose values `profile show` masks.
bool isSecret(string key)
{
    return key.indexOf("SECRET") >= 0 || key.indexOf("PASSWORD") >= 0
        || key.indexOf("PASSPHRASE") >= 0 || key == "CAMUNDA_MTLS_KEY";
}

/// What is on disk.
struct Store
{
    string active;
    string[string][string] profiles;
}

/// Config directory: `$D8CTL_CONFIG_DIR`, else `$XDG_CONFIG_HOME/d8ctl`,
/// else `~/.config/d8ctl`.
string configDir()
{
    import std.path : buildPath;
    import std.process : environment;

    auto explicit = environment.get("D8CTL_CONFIG_DIR");
    if (explicit.length) return explicit;
    auto xdg = environment.get("XDG_CONFIG_HOME");
    if (xdg.length) return buildPath(xdg, "d8ctl");
    return buildPath(environment.get("HOME", "."), ".config", "d8ctl");
}

string profilesPath(string dir)
{
    import std.path : buildPath;
    return buildPath(dir, "profiles.json");
}

Store loadStore(string dir)
{
    import std.file : exists, readText;

    Store s;
    auto path = profilesPath(dir);
    if (!exists(path)) return s;
    JSONValue j;
    try
        j = parseJSON(readText(path));
    catch (JSONException e)
        throw new ProfileException(path ~ " is not valid JSON: " ~ e.msg);
    if (j.type != JSONType.object)
        throw new ProfileException(path ~ ": expected a JSON object");
    if (auto a = "active" in j.objectNoRef)
        if (a.type == JSONType.string) s.active = a.str;
    if (auto ps = "profiles" in j.objectNoRef)
    {
        if (ps.type != JSONType.object)
            throw new ProfileException(path ~ ": \"profiles\" must be an object");
        foreach (name, p; ps.objectNoRef)
        {
            if (p.type != JSONType.object)
                throw new ProfileException(path ~ ": profile '" ~ name ~ "' must be an object");
            string[string] m;
            foreach (k, v; p.objectNoRef)
                if (v.type == JSONType.string) m[k] = v.str;
            s.profiles[name] = m;
        }
    }
    return s;
}

/// Write `profiles.json` with mode 0600 (it can hold client secrets and
/// passwords) via a temp file + rename, so a crash never leaves it half-written.
void saveStore(string dir, Store s)
{
    import std.file : append, exists, mkdirRecurse, rename, setAttributes, write;

    if (!exists(dir))
    {
        mkdirRecurse(dir);
        version (Posix) setAttributes(dir, octal700);
    }
    JSONValue ps = JSONValue(string[string].init);
    foreach (name; s.profiles.keys.sort.array)
    {
        JSONValue p = JSONValue(string[string].init);
        foreach (k; s.profiles[name].keys.sort.array)
            p[k] = s.profiles[name][k];
        ps[name] = p;
    }
    JSONValue root = JSONValue(string[string].init);
    if (s.active.length) root["active"] = s.active;
    root["profiles"] = ps;

    auto path = profilesPath(dir);
    auto tmp = path ~ ".tmp";
    write(tmp, "");
    version (Posix) setAttributes(tmp, octal600);
    append(tmp, root.toPrettyString ~ "\n");
    rename(tmp, path);
}

private enum uint octal600 = 6 * 64;
private enum uint octal700 = 7 * 64;

/// The profile a command runs with: `--profile`, else `D8CTL_PROFILE`, else
/// the active profile, else none (env vars only).
string selectedProfile(string flag, string envName, const ref Store s)
{
    if (flag.length) return flag;
    if (envName.length) return envName;
    return s.active;
}

/// Overrides for `Transport.fromEnv`: the selected profile's keys, then the
/// `--camunda-*` switches on top.
string[string] resolveOverrides(string profileName, const ref Store s, const string[string] switches)
{
    string[string] o;
    if (profileName.length)
    {
        auto p = profileName in s.profiles;
        if (p is null)
            throw new ProfileException("profile '" ~ profileName
                ~ "' not found. See `d8ctl profile list`.");
        foreach (k, v; *p) o[k] = v;
    }
    foreach (k, v; switches)
    {
        requireKnownKey(k);
        o[k] = v;
    }
    return o;
}

/// The `CAMUNDA_*` keys set in the environment (for `profile add --from-env`).
string[string] configFromEnv()
{
    import std.process : environment;

    string[string] m;
    foreach (k; configKeys)
    {
        auto v = environment.get(k);
        if (v.length) m[k] = v;
    }
    return m;
}

/// `d8ctl profile <sub> …`. Returns text for stdout.
string profileCommand(string dir, string[] args, const string[string] switches,
    const bool[string] bare, string[string] envConfig)
{
    auto sub = args.length ? args[0] : "list";
    auto rest = args.length ? args[1 .. $] : (string[]).init;

    void noBare(string[] allowed...)
    {
        foreach (k, _; bare)
            if (!allowed.canFind(k))
                throw new ProfileException("unknown flag --" ~ k ~ " for `d8ctl profile " ~ sub ~ "`");
    }

    string needName()
    {
        if (rest.length != 1)
            throw new ProfileException("usage: d8ctl profile " ~ sub ~ " <name>");
        return rest[0];
    }

    switch (sub)
    {
    case "list":
        noBare();
        auto s = loadStore(dir);
        if (s.profiles.length == 0)
            return "No profiles. Add one: d8ctl profile add <name> --camunda-rest-address=<url> …\n";
        auto buf = appender!string();
        foreach (name; s.profiles.keys.sort.array)
        {
            auto addr = "CAMUNDA_REST_ADDRESS" in s.profiles[name];
            buf.put(format("%s %-20s %s\n", name == s.active ? "*" : " ", name,
                addr ? *addr : "(default address)"));
        }
        return buf.data;

    case "show":
        noBare();
        auto s = loadStore(dir);
        string name = rest.length ? needName() : s.active;
        if (!name.length)
            throw new ProfileException("no active profile. Usage: d8ctl profile show <name>");
        auto p = name in s.profiles;
        if (p is null)
            throw new ProfileException("profile '" ~ name ~ "' not found. See `d8ctl profile list`.");
        auto buf = appender!string();
        buf.put(name ~ (name == s.active ? " (active)" : "") ~ "\n");
        foreach (k; (*p).keys.sort.array)
            buf.put(format("  %-36s %s\n", k, isSecret(k) ? "********" : (*p)[k]));
        return buf.data;

    case "add":
        noBare("from-env", "force", "use");
        auto name = needName();
        if (name.startsWith("-") || name.indexOf('/') >= 0)
            throw new ProfileException("invalid profile name '" ~ name ~ "'");
        string[string] m;
        if ("from-env" in bare)
            foreach (k, v; envConfig) m[k] = v;
        foreach (k, v; switches)
        {
            requireKnownKey(k);
            m[k] = v;
        }
        if (m.length == 0)
            throw new ProfileException("nothing to store. Pass --camunda-* switches "
                ~ "(e.g. --camunda-rest-address=https://…) or --from-env.");
        auto s = loadStore(dir);
        if (name in s.profiles && "force" !in bare)
            throw new ProfileException("profile '" ~ name ~ "' exists. Pass --force to replace it.");
        s.profiles[name] = m;
        if ("use" in bare || s.profiles.length == 1) s.active = name;
        saveStore(dir, s);
        return format("Saved profile '%s' (%s key(s))%s to %s\n", name, m.length,
            s.active == name ? ", now active," : "", profilesPath(dir));

    case "use":
        noBare("none");
        auto s = loadStore(dir);
        if ("none" in bare)
        {
            if (rest.length)
                throw new ProfileException("usage: d8ctl profile use <name> | --none");
            s.active = null;
            saveStore(dir, s);
            return "No active profile: commands use CAMUNDA_* environment variables.\n";
        }
        auto name = needName();
        if (name !in s.profiles)
            throw new ProfileException("profile '" ~ name ~ "' not found. See `d8ctl profile list`.");
        s.active = name;
        saveStore(dir, s);
        return "Active profile: " ~ name ~ "\n";

    case "remove", "rm", "delete":
        noBare();
        auto name = needName();
        auto s = loadStore(dir);
        if (name !in s.profiles)
            throw new ProfileException("profile '" ~ name ~ "' not found. See `d8ctl profile list`.");
        s.profiles.remove(name);
        if (s.active == name) s.active = null;
        saveStore(dir, s);
        return "Removed profile '" ~ name ~ "'\n";

    default:
        throw new ProfileException("unknown profile command '" ~ sub
            ~ "'. See `d8ctl profile --help`.");
    }
}

/// `d8ctl profile --help`.
string profileHelp()
{
    auto buf = appender!string();
    buf.put("d8ctl profile — named connection settings for multiple clusters\n\n");
    buf.put("Usage:\n");
    buf.put("  d8ctl profile list                          Profiles (* = active)\n");
    buf.put("  d8ctl profile show [<name>]                 Keys of a profile (secrets masked)\n");
    buf.put("  d8ctl profile add <name> [--camunda-*=…] [--from-env] [--use] [--force]\n");
    buf.put("  d8ctl profile use <name> | --none           Set or clear the active profile\n");
    buf.put("  d8ctl profile remove <name>\n\n");
    buf.put("Pick a profile for one command with --profile=<name> or D8CTL_PROFILE.\n\n");
    buf.put("Config switches (any command; also what `profile add` stores):\n");
    foreach (k; configKeys)
        buf.put(format("  %-40s %s\n", keyToSwitch(k) ~ "=…", k));
    buf.put("\nPrecedence: --camunda-* switches > selected profile > CAMUNDA_* env > defaults.\n");
    buf.put("Stored in " ~ profilesPath(configDir()) ~ " (mode 0600).\n");
    return buf.data;
}

unittest
{
    assert(switchToKey("rest-address") == "CAMUNDA_REST_ADDRESS");
    assert(keyToSwitch("CAMUNDA_CLIENT_SECRET") == "--camunda-client-secret");
    assert(isSecret("CAMUNDA_CLIENT_SECRET") && isSecret("CAMUNDA_MTLS_KEY"));
    assert(!isSecret("CAMUNDA_MTLS_KEY_PATH") && !isSecret("CAMUNDA_CLIENT_ID"));
}

unittest
{
    import std.exception : assertThrown;
    import std.file : exists, getAttributes, rmdirRecurse, tempDir;
    import std.path : buildPath;
    import std.process : thisProcessID;
    import std.conv : to;

    auto dir = buildPath(tempDir, "d8ctl-profiles-test-" ~ thisProcessID.to!string);
    scope (exit) if (exists(dir)) rmdirRecurse(dir);
    bool[string] none;
    string[string] noEnv;

    // Empty store.
    assert(profileCommand(dir, ["list"], null, none, noEnv).startsWith("No profiles"));

    // First profile becomes active.
    profileCommand(dir, ["add", "local"], ["CAMUNDA_REST_ADDRESS": "http://localhost:8080",
        "CAMUNDA_AUTH_STRATEGY": "NONE"], none, noEnv);
    auto s = loadStore(dir);
    assert(s.active == "local");
    assert(s.profiles["local"]["CAMUNDA_AUTH_STRATEGY"] == "NONE");
    version (Posix) assert((getAttributes(profilesPath(dir)) & 0x1FF) == octal600);

    // Second one does not, unless --use; secrets masked in show.
    profileCommand(dir, ["add", "saas"], ["CAMUNDA_REST_ADDRESS": "https://x.camunda.io/c1",
        "CAMUNDA_CLIENT_SECRET": "s3cret"], none, noEnv);
    assert(loadStore(dir).active == "local");
    auto shown = profileCommand(dir, ["show", "saas"], null, none, noEnv);
    assert(shown.indexOf("s3cret") < 0 && shown.indexOf("********") >= 0);

    // Duplicate needs --force; unknown keys and empty profiles are rejected.
    assertThrown!ProfileException(profileCommand(dir, ["add", "saas"],
        ["CAMUNDA_REST_ADDRESS": "x"], none, noEnv));
    assertThrown!ProfileException(profileCommand(dir, ["add", "bad"],
        ["CAMUNDA_NOPE": "x"], none, noEnv));
    assertThrown!ProfileException(profileCommand(dir, ["add", "empty"], null, none, noEnv));

    // --from-env copies the given env map; switches win over it.
    profileCommand(dir, ["add", "envd"], ["CAMUNDA_AUTH_STRATEGY": "BASIC"], ["from-env": true],
        ["CAMUNDA_REST_ADDRESS": "http://env:8080", "CAMUNDA_AUTH_STRATEGY": "NONE"]);
    assert(loadStore(dir).profiles["envd"]["CAMUNDA_AUTH_STRATEGY"] == "BASIC");
    assert(loadStore(dir).profiles["envd"]["CAMUNDA_REST_ADDRESS"] == "http://env:8080");

    // Resolution: profile, then switches on top.
    s = loadStore(dir);
    auto o = resolveOverrides(selectedProfile("", "", s), s,
        ["CAMUNDA_REST_ADDRESS": "http://override:1"]);
    assert(o["CAMUNDA_REST_ADDRESS"] == "http://override:1");
    assert(o["CAMUNDA_AUTH_STRATEGY"] == "NONE");
    assert(selectedProfile("", "saas", s) == "saas");
    assert(selectedProfile("envd", "saas", s) == "envd");
    assertThrown!ProfileException(resolveOverrides("ghost", s, null));

    // use / --none / remove.
    profileCommand(dir, ["use", "saas"], null, none, noEnv);
    assert(loadStore(dir).active == "saas");
    assert(profileCommand(dir, ["list"], null, none, noEnv).indexOf("* saas") >= 0);
    profileCommand(dir, ["use"], null, ["none": true], noEnv);
    assert(loadStore(dir).active == "");
    profileCommand(dir, ["use", "local"], null, none, noEnv);
    profileCommand(dir, ["remove", "local"], null, none, noEnv);
    s = loadStore(dir);
    assert("local" !in s.profiles && s.active == "");
    assert(resolveOverrides(selectedProfile("", "", s), s, null).length == 0);
}
