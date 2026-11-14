/// Connection profiles and explicit `--camunda-*` config switches.
///
/// A d8ctl profile is a named map of SDK config keys (`CAMUNDA_REST_ADDRESS`,
/// `CAMUNDA_CLIENT_ID`, …), stored in `profiles.json` in the d8ctl config
/// directory. c8ctl profiles and Camunda Modeler connections are read too
/// (read-only, see `d8ctl.compat`). A `--camunda-<key>=<value>` switch sets one
/// key for one command. Precedence, highest first:
///
///   1. `--camunda-*` switches
///   2. the selected profile: `--profile`, else `D8CTL_PROFILE`, else d8ctl's
///      active profile, else c8ctl's (`c8 use profile`)
///   3. `CAMUNDA_*` environment variables
///   4. with no profile and no `CAMUNDA_REST_ADDRESS`: c8ctl's `CAMUNDA_BASE_URL`
///      env vars, else c8ctl's `local` profile (as c8ctl itself falls back)
///   5. SDK defaults
///
/// Profile names resolve d8ctl first, then c8ctl, then Modeler. Layers 1, 2
/// and 4 become the overrides passed to `Transport.fromEnv`, which resolves
/// layers 3 and 5.
module d8ctl.profiles;

@safe:

import std.algorithm : canFind, sort;
import std.array : appender, array;
import std.format : format;
import d8ctl.compat;
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
    "CAMUNDA_DEFAULT_HEADERS",
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

/// The config key holding custom headers (a JSON object of name -> value).
enum headersKey = "CAMUNDA_DEFAULT_HEADERS";

/// One `--header 'Name: value'`.
struct Header
{
    string name;
    string value;
}

/// Parse `Name: value` (curl syntax). Throws on a missing colon or empty name.
Header parseHeaderSwitch(string raw)
{
    import std.string : strip;

    auto colon = raw.indexOf(':');
    // Do not echo `raw`: a mistyped `--header 'X-Api-Key=secret'` would leak
    // the credential into stderr / CI logs.
    if (colon <= 0 || !raw[0 .. colon].strip.length)
        throw new ProfileException("--header expects 'Name: value' (a colon after the header name)");
    auto name = raw[0 .. colon].strip;
    foreach (ch; name)
        if (ch <= ' ' || ch >= 0x7f || "()<>@,;:\\\"/[]?={}".indexOf(ch) >= 0)
            // Do not echo `name` either: `--header 'X-Api-Key=s3cret:tail'`
            // parses `X-Api-Key=s3cret` as the name, and printing it would
            // leak the credential just like echoing the raw argument would.
            throw new ProfileException("--header: invalid header name");
    return Header(name, raw[colon + 1 .. $].strip);
}

/// Parse a `CAMUNDA_DEFAULT_HEADERS` value into ordered pairs. Empty → none.
/// Like the SDK, a whitespace-only value is treated as unset (its config
/// reader strips values before use), and case variants of one name collapse
/// to a single header — the last spelling wins, as the SDK's own
/// case-insensitive merge normalizes them before sending.
Header[] headersFromJson(string raw)
{
    import std.string : strip;

    Header[] r;
    if (!raw.strip.length) return r;
    JSONValue j;
    try j = parseJSON(raw);
    catch (JSONException e)
        throw new ProfileException(headersKey ~ " must be a JSON object of header name to value");
    if (j.type != JSONType.object)
        throw new ProfileException(headersKey ~ " must be a JSON object of header name to value");
    foreach (k; j.objectNoRef.keys.sort.array)
    {
        auto v = j.objectNoRef[k];
        if (v.type != JSONType.string)
            throw new ProfileException(headersKey ~ " header '" ~ k ~ "' must have a string value");
        r ~= Header(k, v.str);
    }
    // One entry per case-insensitive name: an object can carry both
    // "X-Api-Key" and "x-api-key", but the SDK sends only one — the
    // lexicographically last spelling (keys are sorted above, so the last
    // one here wins, matching the SDK's dedupeHeadersCaseInsensitive).
    Header[] deduped;
    foreach (h; r)
    {
        bool replaced;
        foreach (ref x; deduped)
            if (x.name.toLower == h.name.toLower)
            {
                x = h;
                replaced = true;
            }
        if (!replaced) deduped ~= h;
    }
    return deduped;
}

/// Reject headers the SDK would reject at request time (RFC 9110 field
/// syntax via the SDK's own `validateHeader`), translated into the CLI's
/// normal usage error. The SDK error names the header but never the value.
void validateHeaders(const Header[] hs)
{
    import camunda.errors : ConfigException;
    import camunda.transport : validateHeader;

    foreach (h; hs)
    {
        try validateHeader(h.name, h.value, headersKey ~ " header");
        catch (ConfigException e)
            throw new ProfileException(e.msg);
    }
}

/// Serialize headers as a `CAMUNDA_DEFAULT_HEADERS` JSON object.
string headersToJson(const Header[] hs)
{
    JSONValue o = JSONValue(string[string].init);
    foreach (h; hs) o[h.name] = h.value;
    return o.toString;
}

/// Merge `top` over `base`; names compare case-insensitively and the later
/// spelling wins (no duplicate header lines).
Header[] mergeHeaders(const Header[] base, const Header[] top)
{
    Header[] r;
    foreach (h; base) r ~= Header(h.name, h.value);
    foreach (h; top)
    {
        bool replaced;
        foreach (ref x; r)
            if (x.name.toLower == h.name.toLower)
            {
                x = Header(h.name, h.value);
                replaced = true;
            }
        if (!replaced) r ~= Header(h.name, h.value);
    }
    return r;
}

/// `CAMUNDA_DEFAULT_HEADERS` with every value masked (names stay visible).
string maskHeadersJson(string raw)
{
    Header[] hs;
    try hs = headersFromJson(raw);
    catch (ProfileException) return "********";
    foreach (ref h; hs) h.value = "********";
    return headersToJson(hs);
}

/// A config value as `profile show` prints it.
string displayValue(string key, string value)
{
    if (key == headersKey) return maskHeadersJson(value);
    return isSecret(key) ? "********" : value;
}

/// d8ctl's own `profiles.json`.
struct Store
{
    /// Selected with `d8ctl profile use`. May name a c8ctl or Modeler profile.
    string active;
    /// `d8ctl profile use --none`: ignore c8ctl's active profile and its
    /// `local` fallback; use env vars only. Stored as `"active": false`.
    bool activeNone;
    string[string][string] profiles;
}

/// The three profile sources.
struct Dirs
{
    string d8ctl;
    string c8ctl;
    string modeler;
}

Dirs defaultDirs()
{
    return Dirs(configDir(), c8ctlDir(), modelerDir());
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
    {
        if (a.type == JSONType.string) s.active = a.str;
        else if (a.type == JSONType.false_) s.activeNone = true;
    }
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
    else if (s.activeNone) root["active"] = false;
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

/// Everything d8ctl can select from.
struct Sources
{
    Dirs dirs;
    Store store;
    Profile[] c8ctl;
    Profile[] modeler;
    C8ctlSession session;
    /// Unreadable c8ctl / Modeler files (skipped, not fatal).
    string[] warnings;
}

Sources loadSources(Dirs dirs)
{
    Sources s;
    s.dirs = dirs;
    s.store = loadStore(dirs.d8ctl);
    s.c8ctl = loadC8ctlProfiles(dirs.c8ctl, s.warnings);
    s.modeler = loadModelerProfiles(dirs.modeler, s.warnings);
    s.session = loadC8ctlSession(dirs.c8ctl, s.warnings);
    return s;
}

/// A mutable copy of a profile.
Profile copyOf(const ref Profile p)
{
    string[string] c;
    foreach (k, v; p.config) c[k] = v;
    return Profile(p.name, p.origin, c, p.notes.dup, p.id);
}

/// d8ctl, then c8ctl, then Modeler (with or without `modeler:`, or by id).
Profile[] allProfiles(const ref Sources s)
{
    Profile[] r;
    foreach (name; s.store.profiles.keys.sort.array)
    {
        string[string] m;
        foreach (k, v; s.store.profiles[name]) m[k] = v;
        r ~= Profile(name, Origin.d8ctl, m);
    }
    foreach (p; s.c8ctl)
        if (p.name !in s.store.profiles) r ~= copyOf(p);
    foreach (p; s.modeler) r ~= copyOf(p);
    return r;
}

/// Look a profile up by name; null when there is none.
Profile* findProfile(const ref Sources s, string name)
{
    if (!name.length) return null;
    if (auto m = name in s.store.profiles)
    {
        string[string] c;
        foreach (k, v; *m) c[k] = v;
        return new Profile(name, Origin.d8ctl, c);
    }
    foreach (p; s.c8ctl)
        if (p.name == name) return new Profile(copyOf(p).tupleof);
    foreach (p; s.modeler)
        if (p.name == name || p.name == modelerPrefix ~ name || p.id == name)
            return new Profile(copyOf(p).tupleof);
    return null;
}

Profile requireProfile(const ref Sources s, string name)
{
    auto p = findProfile(s, name);
    if (p is null)
        throw new ProfileException("profile '" ~ name ~ "' not found. See `d8ctl profile list`.");
    return *p;
}

/// The active profile name: d8ctl's, else c8ctl's (unless `use --none`).
string activeName(const ref Sources s)
{
    if (s.store.active.length) return s.store.active;
    if (s.store.activeNone) return null;
    return s.session.activeProfile;
}

/// The connection a command runs with.
struct Resolved
{
    /// Overrides for `Transport.fromEnv`.
    string[string] overrides;
    /// Human description of where the settings came from.
    string source;
}

/// Apply the precedence in the module comment. `getenv` reads the process
/// environment (injected for tests).
Resolved resolveConnection(const ref Sources s, string flagName, string envName,
    const string[string] switches, string delegate(string) @safe getenv,
    const Header[] headers = null)
{
    Resolved r;
    string name = flagName.length ? flagName : envName.length ? envName : activeName(s);
    if (name.length)
    {
        auto p = requireProfile(s, name);
        r.overrides = p.config.dup;
        // c8ctl: the session tenant (`c8 use tenant`) beats the profile's.
        if (p.origin != Origin.d8ctl && s.session.activeTenant.length)
            r.overrides["CAMUNDA_DEFAULT_TENANT_ID"] = s.session.activeTenant;
        r.source = originLabel(p.origin) ~ " profile '" ~ p.name ~ "'";
    }
    else if (!getenv("CAMUNDA_REST_ADDRESS").length)
    {
        if (auto ec = c8ctlEnvConfig(getenv))
        {
            if (getenv("CAMUNDA_AUTH_STRATEGY").length) ec.remove("CAMUNDA_AUTH_STRATEGY");
            r.overrides = ec;
            r.source = "c8ctl environment (CAMUNDA_BASE_URL)";
        }
        else if (!s.store.activeNone)
        {
            foreach (p; s.c8ctl)
                if (p.name == "local")
                {
                    r.overrides = p.config.dup;
                    r.source = "c8ctl profile 'local' (default)";
                }
        }
    }
    if (!r.source.length) r.source = "environment";
    // --camunda-default-headers replaces the profile's whole value below, so
    // merge the switch's headers over the profile's per name first — a switch
    // that adds X-Trace must not drop the profile's X-Api-Key.
    if (auto sw = headersKey in switches)
    {
        requireKnownKey(headersKey);
        r.overrides[headersKey] = headersToJson(mergeHeaders(
            headersFromJson(r.overrides.get(headersKey, null)), headersFromJson(*sw)));
    }
    foreach (k, v; switches)
    {
        requireKnownKey(k);
        if (k == headersKey) continue; // already merged per name above
        r.overrides[k] = v;
    }
    if (switches.length) r.source ~= " + --camunda-* switches";
    // Headers merge per name (case-insensitively): --header > switch/profile
    // > CAMUNDA_DEFAULT_HEADERS env, instead of one layer replacing the other.
    auto envHeaders = getenv(headersKey);
    if ((envHeaders.length && (headersKey in r.overrides) !is null) || headers.length)
    {
        auto layered = mergeHeaders(headersFromJson(envHeaders),
            headersFromJson(r.overrides.get(headersKey, null)));
        r.overrides[headersKey] = headersToJson(mergeHeaders(layered, headers));
    }
    if (headers.length) r.source ~= " + --header";
    return r;
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
string profileCommand(Dirs dirs, string[] args, const string[string] switches,
    const bool[string] bare, string[string] envConfig, const Header[] headers = null)
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

    string warn(const ref Sources s)
    {
        string w;
        foreach (x; s.warnings) w ~= "warning: " ~ x ~ "\n";
        return w;
    }

    switch (sub)
    {
    case "list", "ls":
        noBare();
        auto s = loadSources(dirs);
        auto all = allProfiles(s);
        if (all.length == 0)
            return warn(s) ~ "No profiles. Add one: d8ctl profile add <name> --camunda-rest-address=<url> …\n";
        auto act = findProfile(s, activeName(s));
        auto buf = appender!string();
        buf.put(warn(s));
        foreach (p; all)
        {
            auto addr = "CAMUNDA_REST_ADDRESS" in p.config;
            bool isActive = act !is null && act.name == p.name && act.origin == p.origin;
            buf.put(format("%s %-24s %-8s %s\n", isActive ? "*" : " ", p.name,
                originLabel(p.origin), addr ? *addr : "(default address)"));
        }
        return buf.data;

    case "show":
        noBare();
        auto s = loadSources(dirs);
        string name = rest.length ? needName() : activeName(s);
        if (!name.length)
            throw new ProfileException("no active profile. Usage: d8ctl profile show <name>");
        auto p = requireProfile(s, name);
        auto act = findProfile(s, activeName(s));
        bool isActive = act !is null && act.name == p.name && act.origin == p.origin;
        auto buf = appender!string();
        buf.put(warn(s));
        buf.put(format("%s (%s%s)\n", p.name, originLabel(p.origin), isActive ? ", active" : ""));
        foreach (k; p.config.keys.sort.array)
            buf.put(format("  %-36s %s\n", k, displayValue(k, p.config[k])));
        foreach (n; p.notes) buf.put("  note: " ~ n ~ "\n");
        return buf.data;

    case "add":
        noBare("from-env", "force", "use");
        auto name = needName();
        if (name.startsWith("-") || name.indexOf('/') >= 0 || name.startsWith(modelerPrefix))
            throw new ProfileException("invalid profile name '" ~ name ~ "'");
        string[string] m;
        if ("from-env" in bare)
            foreach (k, v; envConfig) m[k] = v;
        // --camunda-default-headers replaces the copied env value below, so
        // merge the switch's headers over the env's per name first — a switch
        // that adds X-Trace must not drop an env-only X-Api-Key.
        if (auto sw = headersKey in switches)
        {
            requireKnownKey(headersKey);
            m[headersKey] = headersToJson(mergeHeaders(
                headersFromJson(m.get(headersKey, null)), headersFromJson(*sw)));
        }
        foreach (k, v; switches)
        {
            requireKnownKey(k);
            if (k == headersKey) continue; // already merged per name above
            m[k] = v;
        }
        if (headers.length)
            m[headersKey] = headersToJson(mergeHeaders(
                headersFromJson(m.get(headersKey, null)), headers));
        // Validate the merged headers the way the SDK will when the profile
        // is used — a bad name or a control character in a value must fail
        // here, not save a profile every later command rejects.
        if (auto hv = headersKey in m)
            validateHeaders(headersFromJson(*hv));
        if (m.length == 0)
            throw new ProfileException("nothing to store. Pass --camunda-* switches "
                ~ "(e.g. --camunda-rest-address=https://…) or --from-env.");
        auto s = loadStore(dirs.d8ctl);
        if (name in s.profiles && "force" !in bare)
            throw new ProfileException("profile '" ~ name ~ "' exists. Pass --force to replace it.");
        s.profiles[name] = m;
        if ("use" in bare || (s.profiles.length == 1 && !s.active.length && !s.activeNone))
        {
            s.active = name;
            s.activeNone = false;
        }
        saveStore(dirs.d8ctl, s);
        string shadow;
        auto all = loadSources(dirs);
        foreach (p; all.c8ctl)
            if (p.name == name) shadow = " It shadows the c8ctl profile of the same name.";
        return format("Saved profile '%s' (%s key(s))%s to %s.%s\n", name, m.length,
            s.active == name ? ", now active," : "", profilesPath(dirs.d8ctl), shadow);

    case "use":
        noBare("none");
        auto s = loadStore(dirs.d8ctl);
        if ("none" in bare)
        {
            if (rest.length)
                throw new ProfileException("usage: d8ctl profile use <name> | --none");
            s.active = null;
            s.activeNone = true;
            saveStore(dirs.d8ctl, s);
            return "No active profile: commands use CAMUNDA_* environment variables "
                ~ "(c8ctl's active profile is ignored).\n";
        }
        auto name = needName();
        auto all = loadSources(dirs);
        auto p = requireProfile(all, name);
        s.active = p.name;
        s.activeNone = false;
        saveStore(dirs.d8ctl, s);
        return format("Active profile: %s (%s)\n", p.name, originLabel(p.origin));

    case "remove", "rm", "delete":
        noBare();
        auto name = needName();
        auto s = loadStore(dirs.d8ctl);
        if (name !in s.profiles)
        {
            auto all = loadSources(dirs);
            auto p = findProfile(all, name);
            if (p !is null)
                throw new ProfileException("'" ~ p.name ~ "' is a " ~ originLabel(p.origin)
                    ~ " profile; d8ctl only reads it. Remove it in "
                    ~ (p.origin == Origin.c8ctl ? "c8ctl" : "Camunda Modeler") ~ ".");
            throw new ProfileException("profile '" ~ name ~ "' not found. See `d8ctl profile list`.");
        }
        s.profiles.remove(name);
        if (s.active == name) s.active = null;
        saveStore(dirs.d8ctl, s);
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
    buf.put("  d8ctl profile list                          All profiles (* = active)\n");
    buf.put("  d8ctl profile show [<name>]                 Keys of a profile (secrets masked)\n");
    buf.put("  d8ctl profile add <name> [--camunda-*=…] [--header 'Name: value']…\n");
    buf.put("                            [--from-env] [--use] [--force]\n");
    buf.put("  d8ctl profile use <name> | --none           Set or clear the active profile\n");
    buf.put("  d8ctl profile remove <name>\n");
    buf.put("c8ctl forms work too: d8ctl list profiles, d8ctl use profile <name>, …\n\n");
    buf.put("Pick a profile for one command with --profile <name> or D8CTL_PROFILE.\n\n");
    buf.put("Sources (a name resolves in this order):\n");
    buf.put("  d8ctl     " ~ profilesPath(configDir()) ~ " (mode 0600)\n");
    buf.put("  c8ctl     " ~ profilesPath(c8ctlDir()) ~ " (read-only)\n");
    buf.put("  modeler   Camunda Modeler connections as modeler:<name> (read-only)\n");
    buf.put("c8ctl's active profile (`c8 use profile`) applies unless d8ctl sets its own.\n\n");
    buf.put("Config switches (any command; also what `profile add` stores):\n");
    foreach (k; configKeys)
        buf.put(format("  %-40s %s\n", keyToSwitch(k) ~ "=…", k));
    buf.put("\nCustom HTTP headers (any command; `profile add` stores them):\n");
    buf.put("  --header 'Name: value'   repeatable; sent on every API request (not to\n");
    buf.put("                           the OAuth token endpoint); may replace Authorization\n");
    buf.put("  Stored as " ~ headersKey ~ ", a JSON object, e.g.\n");
    buf.put("  --camunda-default-headers='{\"X-Api-Key\":\"…\"}'. Header names merge\n");
    buf.put("  case-insensitively: --header > profile / switch > env. Values are masked\n");
    buf.put("  in `profile show` and --dry-run.\n");
    buf.put("\nPrecedence: --camunda-* switches > selected profile > CAMUNDA_* env\n");
    buf.put("> c8ctl CAMUNDA_BASE_URL env / c8ctl 'local' profile > SDK defaults.\n");
    return buf.data;
}

unittest
{
    assert(switchToKey("rest-address") == "CAMUNDA_REST_ADDRESS");
    assert(keyToSwitch("CAMUNDA_CLIENT_SECRET") == "--camunda-client-secret");
    assert(isSecret("CAMUNDA_CLIENT_SECRET") && isSecret("CAMUNDA_MTLS_KEY"));
    assert(!isSecret("CAMUNDA_MTLS_KEY_PATH") && !isSecret("CAMUNDA_CLIENT_ID"));
}

version (unittest)
{
    private Dirs testDirs(string tag)
    {
        import std.conv : to;
        import std.file : tempDir;
        import std.path : buildPath;
        import std.process : thisProcessID;

        auto root = buildPath(tempDir, "d8ctl-test-" ~ tag ~ "-" ~ thisProcessID.to!string);
        return Dirs(buildPath(root, "d8ctl"), buildPath(root, "c8ctl"), buildPath(root, "modeler"));
    }

    private void cleanup(Dirs d)
    {
        import std.file : exists, rmdirRecurse;
        import std.path : dirName;

        auto root = dirName(d.d8ctl);
        if (exists(root)) rmdirRecurse(root);
    }

    private string delegate(string) @safe envOf(string[string] env)
    {
        return (string k) => k in env ? env[k] : null;
    }
}

unittest
{
    import std.exception : assertThrown;
    import std.file : getAttributes;

    auto dirs = testDirs("d8");
    scope (exit) cleanup(dirs);
    bool[string] none;
    string[string] noEnv;
    auto noGet = envOf(null);

    // Empty store.
    assert(profileCommand(dirs, ["list"], null, none, noEnv).startsWith("No profiles"));

    // First profile becomes active.
    profileCommand(dirs, ["add", "local"], ["CAMUNDA_REST_ADDRESS": "http://localhost:8080",
        "CAMUNDA_AUTH_STRATEGY": "NONE"], none, noEnv);
    auto s = loadStore(dirs.d8ctl);
    assert(s.active == "local");
    assert(s.profiles["local"]["CAMUNDA_AUTH_STRATEGY"] == "NONE");
    version (Posix) assert((getAttributes(profilesPath(dirs.d8ctl)) & 0x1FF) == octal600);

    // Second one does not, unless --use; secrets masked in show.
    profileCommand(dirs, ["add", "saas"], ["CAMUNDA_REST_ADDRESS": "https://x.camunda.io/c1",
        "CAMUNDA_CLIENT_SECRET": "s3cret"], none, noEnv);
    assert(loadStore(dirs.d8ctl).active == "local");
    auto shown = profileCommand(dirs, ["show", "saas"], null, none, noEnv);
    assert(shown.indexOf("s3cret") < 0 && shown.indexOf("********") >= 0);

    // Duplicate needs --force; unknown keys and empty profiles are rejected.
    assertThrown!ProfileException(profileCommand(dirs, ["add", "saas"],
        ["CAMUNDA_REST_ADDRESS": "x"], none, noEnv));
    assertThrown!ProfileException(profileCommand(dirs, ["add", "bad"],
        ["CAMUNDA_NOPE": "x"], none, noEnv));
    assertThrown!ProfileException(profileCommand(dirs, ["add", "empty"], null, none, noEnv));

    // --from-env copies the given env map; switches win over it.
    profileCommand(dirs, ["add", "envd"], ["CAMUNDA_AUTH_STRATEGY": "BASIC"], ["from-env": true],
        ["CAMUNDA_REST_ADDRESS": "http://env:8080", "CAMUNDA_AUTH_STRATEGY": "NONE"]);
    assert(loadStore(dirs.d8ctl).profiles["envd"]["CAMUNDA_AUTH_STRATEGY"] == "BASIC");
    assert(loadStore(dirs.d8ctl).profiles["envd"]["CAMUNDA_REST_ADDRESS"] == "http://env:8080");

    // Resolution: active profile, then switches on top; flag > env name > active.
    auto src = loadSources(dirs);
    auto r = resolveConnection(src, "", "", ["CAMUNDA_REST_ADDRESS": "http://override:1"], noGet);
    assert(r.overrides["CAMUNDA_REST_ADDRESS"] == "http://override:1");
    assert(r.overrides["CAMUNDA_AUTH_STRATEGY"] == "NONE");
    assert(resolveConnection(src, "", "saas", null, noGet).source == "d8ctl profile 'saas'");
    assert(resolveConnection(src, "envd", "saas", null, noGet).source == "d8ctl profile 'envd'");
    assertThrown!ProfileException(resolveConnection(src, "ghost", "", null, noGet));

    // use / --none / remove.
    profileCommand(dirs, ["use", "saas"], null, none, noEnv);
    assert(loadStore(dirs.d8ctl).active == "saas");
    assert(profileCommand(dirs, ["list"], null, none, noEnv).indexOf("* saas") >= 0);
    profileCommand(dirs, ["use"], null, ["none": true], noEnv);
    assert(loadStore(dirs.d8ctl).activeNone && loadStore(dirs.d8ctl).active == "");
    profileCommand(dirs, ["use", "local"], null, none, noEnv);
    assert(!loadStore(dirs.d8ctl).activeNone);
    profileCommand(dirs, ["remove", "local"], null, none, noEnv);
    s = loadStore(dirs.d8ctl);
    assert("local" !in s.profiles && s.active == "");
    src = loadSources(dirs);
    assert(resolveConnection(src, "", "", null, noGet).overrides.length == 0);
}

unittest
{
    // c8ctl + Modeler sources.
    import std.exception : assertThrown;
    import std.file : mkdirRecurse, readText, write;
    import std.path : buildPath;

    auto dirs = testDirs("c8");
    scope (exit) cleanup(dirs);
    mkdirRecurse(dirs.c8ctl);
    mkdirRecurse(dirs.modeler);
    auto c8profiles = `{"profiles":[
        {"name":"local","baseUrl":"http://localhost:8080/v2","username":"demo","password":"demo"},
        {"name":"prod","baseUrl":"https://p/v2","clientId":"i","clientSecret":"s","defaultTenantId":"t1"}]}`;
    write(buildPath(dirs.c8ctl, "profiles.json"), c8profiles);
    write(buildPath(dirs.modeler, "settings.json"), `{"other":1,"connectionManagerPlugin.c8connections":[
        {"id":"abc-1","name":"c8run (local)","targetType":"selfHosted","authType":"none",
         "contactPoint":"http://localhost:8080/v2"},{"name":"no id"}]}`);
    bool[string] none;
    string[string] noEnv;
    auto noGet = envOf(null);

    auto src = loadSources(dirs);
    assert(src.c8ctl.length == 2 && src.modeler.length == 1);
    auto listing = profileCommand(dirs, ["list"], null, none, noEnv);
    assert(listing.indexOf("prod") >= 0 && listing.indexOf("modeler:c8run (local)") >= 0);
    assert(listing.indexOf("*") < 0); // nothing active yet

    // No profile, no env: c8ctl's 'local' fallback (Basic demo/demo).
    auto r = resolveConnection(src, "", "", null, noGet);
    assert(r.source == "c8ctl profile 'local' (default)");
    assert(r.overrides["CAMUNDA_AUTH_STRATEGY"] == "BASIC");
    // ...but not when CAMUNDA_REST_ADDRESS is set (SDK env wins).
    assert(resolveConnection(src, "", "", null,
        envOf(["CAMUNDA_REST_ADDRESS": "http://x"])).overrides.length == 0);
    // c8ctl's CAMUNDA_BASE_URL env beats the 'local' fallback.
    r = resolveConnection(src, "", "", null, envOf(["CAMUNDA_BASE_URL": "http://b/v2"]));
    assert(r.overrides["CAMUNDA_REST_ADDRESS"] == "http://b/v2");
    assert(r.overrides["CAMUNDA_AUTH_STRATEGY"] == "NONE");
    r = resolveConnection(src, "", "", null, envOf(["CAMUNDA_BASE_URL": "http://b/v2",
        "CAMUNDA_AUTH_STRATEGY": "OAUTH"]));
    assert("CAMUNDA_AUTH_STRATEGY" !in r.overrides);

    // c8ctl's session: active profile and tenant apply.
    write(buildPath(dirs.c8ctl, "session.json"), `{"activeProfile":"prod","activeTenant":"t9"}`);
    src = loadSources(dirs);
    r = resolveConnection(src, "", "", null, noGet);
    assert(r.source == "c8ctl profile 'prod'");
    assert(r.overrides["CAMUNDA_AUTH_STRATEGY"] == "OAUTH");
    assert(r.overrides["CAMUNDA_DEFAULT_TENANT_ID"] == "t9");
    assert(profileCommand(dirs, ["list"], null, none, noEnv).indexOf("* prod") >= 0);

    // Modeler by prefixed name, bare name, or id.
    foreach (n; ["modeler:c8run (local)", "c8run (local)", "abc-1"])
        assert(resolveConnection(src, n, "", null, noGet).overrides["CAMUNDA_AUTH_STRATEGY"] == "NONE");

    // d8ctl `use` can select a c8ctl/Modeler profile; `use --none` ignores c8ctl's.
    profileCommand(dirs, ["use", "abc-1"], null, none, noEnv);
    assert(loadStore(dirs.d8ctl).active == "modeler:c8run (local)");
    profileCommand(dirs, ["use"], null, ["none": true], noEnv);
    src = loadSources(dirs);
    assert(resolveConnection(src, "", "", null, noGet).overrides.length == 0);

    // d8ctl shadows c8ctl on a name clash; c8ctl / Modeler entries are read-only.
    profileCommand(dirs, ["add", "prod"], ["CAMUNDA_REST_ADDRESS": "http://mine"], none, noEnv);
    src = loadSources(dirs);
    assert(resolveConnection(src, "prod", "", null, noGet).overrides["CAMUNDA_REST_ADDRESS"] == "http://mine");
    profileCommand(dirs, ["remove", "prod"], null, none, noEnv);
    assertThrown!ProfileException(profileCommand(dirs, ["remove", "prod"], null, none, noEnv));
    assertThrown!ProfileException(profileCommand(dirs, ["remove", "modeler:c8run (local)"], null, none, noEnv));
    assert(readText(buildPath(dirs.c8ctl, "profiles.json")) == c8profiles);

    // A corrupt c8ctl file is a warning, not a failure.
    write(buildPath(dirs.c8ctl, "profiles.json"), "{nope");
    src = loadSources(dirs);
    assert(src.c8ctl.length == 0 && src.warnings.length == 1);
}

unittest
{
    // Custom headers: parsing, merge, precedence, masking.
    import std.exception : assertThrown;

    assert(parseHeaderSwitch("X-Api-Key:  abc ") == Header("X-Api-Key", "abc"));
    assert(parseHeaderSwitch("Authorization: Bearer a:b") == Header("Authorization", "Bearer a:b"));
    assertThrown!ProfileException(parseHeaderSwitch("nocolon"));
    assertThrown!ProfileException(parseHeaderSwitch(" : v"));
    assertThrown!ProfileException(headersFromJson("[1]"));
    assertThrown!ProfileException(headersFromJson(`{"A":1}`));
    assert(headersFromJson("").length == 0);
    // Whitespace-only is unset, matching the SDK's stripped config lookup.
    assert(headersFromJson("   ").length == 0);
    assert(headersFromJson(" \t\n").length == 0);
    // Case variants of one name collapse; the last spelling wins.
    assert(headersFromJson(`{"X-Api-Key":"a","x-api-key":"b"}`)
        == [Header("x-api-key", "b")]);

    // Malformed --header must not echo the raw argument (it can hold a
    // credential the user pasted with `=` instead of `:`).
    try
    {
        cast(void) parseHeaderSwitch("X-Api-Key=s3cret");
        assert(false);
    }
    catch (ProfileException e)
        assert(e.msg.indexOf("s3cret") < 0 && e.msg.indexOf("X-Api-Key=") < 0);
    // The invalid-name path must not echo the parsed name either: with a
    // colon later in the value, the "name" itself holds the credential.
    try
    {
        cast(void) parseHeaderSwitch("X-Api-Key=s3cret:tail");
        assert(false);
    }
    catch (ProfileException e)
        assert(e.msg.indexOf("s3cret") < 0 && e.msg.indexOf("X-Api-Key") < 0);

    auto m = mergeHeaders([Header("X-Api-Key", "old"), Header("X-Keep", "k")],
        [Header("x-api-key", "new")]);
    assert(m == [Header("x-api-key", "new"), Header("X-Keep", "k")]);

    auto masked = maskHeadersJson(`{"X-Api-Key":"s3cret"}`);
    assert(masked.indexOf("s3cret") < 0 && masked.indexOf("X-Api-Key") >= 0);
    assert(displayValue(headersKey, "not json") == "********");
    assert(displayValue("CAMUNDA_CLIENT_ID", "id") == "id");

    auto dirs = testDirs("hdr");
    scope (exit) cleanup(dirs);
    bool[string] none;
    string[string] noEnv;
    profileCommand(dirs, ["add", "h"], ["CAMUNDA_REST_ADDRESS": "http://h",
        headersKey: `{"X-Api-Key":"pv1","X-Profile":"p"}`], none, noEnv,
        [Header("x-profile", "fromswitch")]);
    auto stored = headersFromJson(loadStore(dirs.d8ctl).profiles["h"][headersKey]);
    assert(stored == [Header("X-Api-Key", "pv1"), Header("x-profile", "fromswitch")]);
    auto shown = profileCommand(dirs, ["show", "h"], null, none, noEnv);
    assert(shown.indexOf("pv1") < 0 && shown.indexOf("fromswitch") < 0);
    assert(shown.indexOf("X-Api-Key") >= 0);
    assertThrown!ProfileException(profileCommand(dirs, ["add", "bad"],
        [headersKey: "nope"], none, noEnv));
    // profile add rejects headers the SDK would reject at request time:
    // a bad name in the JSON switch, a control character in a value, and a
    // bad --header value — none of them may be saved into a profile.
    assertThrown!ProfileException(profileCommand(dirs, ["add", "badname"],
        ["CAMUNDA_REST_ADDRESS": "http://h", headersKey: `{"Bad Name":"v"}`], none, noEnv));
    assertThrown!ProfileException(profileCommand(dirs, ["add", "badval"],
        ["CAMUNDA_REST_ADDRESS": "http://h", headersKey: "{\"X-Api-Key\":\"a\\r\\nb\"}"], none, noEnv));
    assertThrown!ProfileException(profileCommand(dirs, ["add", "badhdr"],
        ["CAMUNDA_REST_ADDRESS": "http://h"], none, noEnv, [Header("X-Api-Key", "a\nb")]));
    // ...and nothing was stored for any of them.
    auto afterBad = loadStore(dirs.d8ctl);
    assert("badname" !in afterBad.profiles && "badval" !in afterBad.profiles
        && "badhdr" !in afterBad.profiles);

    // switch > profile > env, per header name, case-insensitively.
    auto src = loadSources(dirs);
    auto env = envOf([headersKey: `{"X-Env":"e","X-API-KEY":"env"}`]);
    auto r = resolveConnection(src, "h", "", null, env, [Header("X-Profile", "cli")]);
    auto got = headersFromJson(r.overrides[headersKey]);
    assert(got.length == 3);
    foreach (h; got)
    {
        if (h.name.toLower == "x-api-key") assert(h.value == "pv1");
        else if (h.name.toLower == "x-profile") assert(h.value == "cli" && h.name == "X-Profile");
        else assert(h == Header("X-Env", "e"));
    }
    // No profile headers, no --header: the env value is left to the SDK.
    profileCommand(dirs, ["use"], null, ["none": true], noEnv);
    src = loadSources(dirs);
    r = resolveConnection(src, "", "", null, env);
    assert(headersKey !in r.overrides);
    // Only --header: env headers still apply underneath.
    r = resolveConnection(src, "", "", null, env, [Header("x-env", "cli")]);
    assert(headersFromJson(r.overrides[headersKey]).length == 2);
    assert(r.overrides[headersKey].indexOf(`"x-env":"cli"`) >= 0);

    // --camunda-default-headers merges over the profile's headers per name
    // instead of replacing the whole value (profile X-Api-Key survives).
    // (`use --none` above cleared the active profile; select h explicitly.)
    r = resolveConnection(src, "h", "", [headersKey: `{"X-Trace":"t"}`], env);
    auto sw = headersFromJson(r.overrides[headersKey]);
    assert(sw.length == 4); // X-Api-Key (profile), X-Profile, X-Trace (switch), X-Env (env)
    foreach (h; sw)
    {
        if (h.name.toLower == "x-api-key") assert(h.value == "pv1");
        else if (h.name.toLower == "x-trace") assert(h.value == "t");
    }
    // ...and a same-named switch header still wins over the profile's.
    // (h stores x-profile=fromswitch: the --header won at add time.)
    r = resolveConnection(src, "h", "", [headersKey: `{"x-api-key":"sw"}`], envOf(null));
    assert(headersFromJson(r.overrides[headersKey]) == [
        Header("x-api-key", "sw"), Header("x-profile", "fromswitch")],
        r.overrides[headersKey]);
    // A whitespace-only env value is unset (the SDK strips config values), so
    // resolution and dry-run agree instead of failing on a JSON parse.
    r = resolveConnection(src, "", "", null, envOf([headersKey: "   "]),
        [Header("X-Cli", "c")]);
    assert(headersFromJson(r.overrides[headersKey]) == [Header("X-Cli", "c")]);

    // profile add --from-env + --camunda-default-headers: the switch merges
    // over the copied env headers per name instead of dropping them.
    profileCommand(dirs, ["add", "envhdr"], [headersKey: `{"X-Trace":"t"}`],
        ["from-env": true], ["CAMUNDA_REST_ADDRESS": "http://e",
        headersKey: `{"X-Api-Key":"envsecret"}`]);
    auto added = headersFromJson(loadStore(dirs.d8ctl).profiles["envhdr"][headersKey]);
    assert(added == [Header("X-Api-Key", "envsecret"), Header("X-Trace", "t")]);
    // A same-named switch header wins over the env one; --header wins over both.
    profileCommand(dirs, ["add", "envhdr2"], [headersKey: `{"x-api-key":"sw"}`],
        ["from-env": true], ["CAMUNDA_REST_ADDRESS": "http://e",
        headersKey: `{"X-Api-Key":"envsecret"}`], [Header("X-New", "cli")]);
    added = headersFromJson(loadStore(dirs.d8ctl).profiles["envhdr2"][headersKey]);
    assert(added.length == 2, loadStore(dirs.d8ctl).profiles["envhdr2"][headersKey]);
    foreach (h; added)
    {
        if (h.name.toLower == "x-api-key") assert(h.value == "sw");
        else assert(h == Header("X-New", "cli"));
    }
}
