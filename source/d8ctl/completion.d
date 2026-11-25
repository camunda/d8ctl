/// Shell completion (#34): `d8ctl completion bash|zsh|fish|powershell` prints
/// a small script; on each Tab it calls `d8ctl __complete <words…>`, which
/// answers from what d8ctl knows right now — the generated catalog, installed
/// extensions, profiles — so new specs and extensions complete with no
/// regeneration. Completion never touches the network.
///
/// Protocol: `__complete` takes the command line split into words, the last
/// being the word under the cursor (possibly empty; PowerShell 5 passes `""`).
/// It prints one candidate per line, `value` or `value<TAB>description`, then
/// a directive line `:N` (bit 1: no trailing space).
module d8ctl.completion;

@safe:

import d8ctl.catalog : BodyField, Command, commandsFor, commandsIn, namespaces;
import d8ctl.dispatch : UsageException;
import d8ctl.extensions : listExtensionNames;
import d8ctl.help : brief;
import d8ctl.parse : Kind, parse, Result;
import d8ctl.profiles : allProfiles, configKeys, Dirs, keyToSwitch, loadSources;
import std.algorithm : canFind, sort, startsWith, uniq;
import std.array : appender, array;
import std.string : indexOf, lastIndexOf;

/// Directive bit: do not add a space after the completion (`--flag=`).
enum noSpace = 1;

/// Shells `completion` can print a script for.
immutable string[] shells = ["bash", "zsh", "fish", "powershell"];

private struct Cand
{
    string value;
    string doc;
}

/// Global flags, valid on any command.
private immutable Cand[] globalFlags = [
    Cand("--help", "Help for this level"),
    Cand("--json", "Machine-readable --help"),
    Cand("--dry-run", "Print the request instead of sending it"),
    Cand("--pretty", "Pretty-print the response JSON"),
    Cand("--compact", "Compact response JSON"),
    Cand("--output=", "Error format on stderr: json|text"),
    Cand("--order=", "Help lists by resource or verb"),
    Cand("--operator", "Reveal operator-only extension operations"),
    Cand("--profile=", "Profile for this command"),
    Cand("--header=", "Extra HTTP header 'Name: value' (repeatable)"),
    Cand("--version", "Print the version"),
];

/// Answer one `__complete` call. `words` excludes the program name.
string complete(string[] words, Dirs dirs)
{
    int directive;
    auto buf = appender!string();
    foreach (c; answer(words, dirs, directive))
    {
        buf.put(c.value);
        if (c.doc.length)
        {
            buf.put('\t');
            buf.put(c.doc);
        }
        buf.put('\n');
    }
    buf.put(':');
    import std.conv : to;

    buf.put(directive.to!string);
    buf.put('\n');
    return buf.data;
}

/// The program protocol (d8ctl#46): `d8ctl complete --json` answers the same
/// question as `__complete` (the shell protocol) as
/// `{"items":[{"value","description"}],"noSpace":bool}`. `words` excludes the
/// program name; the last is the word under the cursor (may be empty).
string completeJson(string[] words, Dirs dirs)
{
    import std.json : JSONOptions, JSONValue;

    int directive;
    JSONValue[] items;
    foreach (c; answer(words, dirs, directive))
        items ~= JSONValue(["value": c.value, "description": c.doc]);
    JSONValue j = ["items": JSONValue(items), "noSpace": JSONValue((directive & noSpace) != 0)];
    return j.toString(JSONOptions.doNotEscapeSlashes);
}

/// Words for `complete --json`: `--tokens='a b --c='` (the words after
/// `d8ctl`) or `--line='d8ctl a b --c='` (a whole line; a leading `d8ctl` is
/// dropped). Split on whitespace, no quoting; trailing whitespace means the
/// cursor is on a new, empty word. Throws `UsageException` without either.
string[] completeWords(string[] args)
{
    import std.array : split;
    import std.ascii : isWhite;
    import std.path : baseName, stripExtension;

    string text;
    bool line, given;
    foreach (a; args)
    {
        if (a.startsWith("--tokens="))
        {
            text = a[9 .. $];
            given = true;
        }
        else if (a.startsWith("--line="))
        {
            text = a[7 .. $];
            line = given = true;
        }
        else if (a != "--json")
            throw new UsageException("complete: unknown argument " ~ a
                ~ " (expected --json and --tokens=… or --line=…)");
    }
    if (!given)
        throw new UsageException("complete needs --tokens='…' or --line='…'");
    auto ws = text.split;
    if (line && ws.length && ws[0].baseName.stripExtension == "d8ctl")
        ws = ws[1 .. $];
    if (!ws.length || (text.length && isWhite(text[$ - 1])))
        ws ~= "";
    return ws;
}

/// The candidates for `words` (last = the word under the cursor), filtered
/// by that prefix, de-duplicated, descriptions on one line.
private Cand[] answer(string[] words, Dirs dirs, ref int directive)
{
    string cur = words.length ? words[$ - 1] : "";
    if (cur == `""`)
        cur = "";
    string[] prev = words.length ? words[0 .. $ - 1] : null;
    Cand[] out_;
    bool[string] seen;
    foreach (c; candidates(prev, cur, dirs, directive))
    {
        if (!c.value.startsWith(cur) || c.value in seen)
            continue;
        seen[c.value] = true;
        out_ ~= Cand(c.value, c.doc.length ? oneLine(c.doc) : "");
    }
    return out_;
}

private string oneLine(string s)
{
    import std.array : replace;

    return brief(s.replace("\t", " ").replace("\n", " "));
}

private Cand[] candidates(string[] prev, string cur, Dirs dirs, ref int directive)
{
    // `--profile <name>` / `--output <fmt>` / `--shell <sh>` (space form).
    if (prev.length && !cur.startsWith("-"))
    {
        auto last = prev[$ - 1];
        auto values = last.startsWith("--") ? flagValues(last[2 .. $], prev, dirs, true) : null;
        if (values !is null)
            return values;
    }

    auto pos = positionals(prev);

    if (cur.startsWith("-"))
    {
        auto eq = cur.indexOf('=');
        if (eq > 2)
        {
            auto name = cur[2 .. eq];
            Cand[] out_;
            foreach (v; flagValues(name, prev, dirs, false))
                out_ ~= Cand("--" ~ name ~ "=" ~ v.value, v.doc);
            return out_;
        }
        auto fl = flagsFor(prev, pos, dirs);
        foreach (f; fl)
            if (f.value.startsWith(cur) && f.value[$ - 1] == '=')
                directive |= noSpace;
        return fl;
    }
    return words(pos, prev, dirs);
}

/// Positional words of `prev`, skipping the values of space-form flags.
private string[] positionals(string[] prev)
{
    string[] pos;
    for (size_t i = 0; i < prev.length; i++)
    {
        auto a = prev[i];
        if (spaceFlag(a))
        {
            i++;
            continue;
        }
        if (a.startsWith("-"))
            continue;
        pos ~= a;
    }
    return pos;
}

private bool spaceFlag(string a)
{
    return ["--profile", "--spec", "--base-url", "--output", "--header", "-H", "--shell"].canFind(a);
}

private bool operatorOn(string[] prev)
{
    return prev.canFind("--operator");
}

/// The parse of the command so far, or an error result.
private Result parsed(string[] prev, Dirs dirs)
{
    Result r;
    try
        r = parse(prev, dirs.d8ctl);
    catch (Exception) // half-typed words: complete nothing rather than fail the shell
        r.kind = Kind.error;
    return r;
}

/// Candidates for the next positional word.
private Cand[] words(string[] pos, string[] prev, Dirs dirs)
{
    Cand[] out_;
    if (!pos.length)
    {
        foreach (ns; namespaces())
            out_ ~= Cand(ns, "Camunda 8 Orchestration Cluster API");
        foreach (e; extensionNames(dirs))
            out_ ~= Cand(e, "Extension");
        out_ ~= Cand("profile", "Manage connection profiles");
        out_ ~= Cand("extension", "Add, list, update or remove extensions");
        out_ ~= Cand("completion", "Shell completion scripts");
        out_ ~= Cand("catalog", "The loaded command surface as JSON");
        out_ ~= Cand("complete", "Completion as JSON (for programs)");
        out_ ~= Cand("help", "Help");
        return out_;
    }
    auto head = pos[0];
    if (head == "help")
        return pos.length == 1 ? [Cand("extensions", "Runtime extensions")] : null;
    if (head == "completion")
    {
        if (pos.length != 1)
            return null;
        foreach (s; shells)
            out_ ~= Cand(s, "Print the " ~ s ~ " script");
        out_ ~= Cand("install", "Add completion to your shell's startup");
        return out_;
    }
    if (pos.length >= 2 && (pos[1] == "profile" || pos[1] == "profiles")
        && ["list", "show", "add", "use", "remove", "rm", "delete"].canFind(head))
        pos = ["profile", head] ~ pos[2 .. $];
    if (head == "profile" || pos[0] == "profile")
    {
        if (pos.length == 1)
            return [Cand("list", "All profiles"), Cand("show", "Keys of a profile"),
                Cand("add", "Add a profile"), Cand("use", "Set the active profile"),
                Cand("remove", "Remove a profile")];
        if (pos.length == 2 && ["show", "use", "remove", "rm", "delete"].canFind(pos[1]))
            return profileNames(dirs);
        return null;
    }
    if (head == "extension" || head == "extensions")
    {
        if (pos.length == 1)
            return [Cand("add", "Install an extension from a spec"),
                Cand("list", "Installed extensions"), Cand("update", "Re-download"),
                Cand("remove", "Uninstall an extension")];
        if (pos.length == 2 && ["update", "remove"].canFind(pos[1]))
            return extensionNames(dirs).map(n => Cand(n, "Extension"));
        return null;
    }

    // A namespace: `cluster` or an extension.
    auto r = parsed([head], dirs);
    if (r.kind != Kind.helpNs)
        return null;
    const op = operatorOn(prev);
    auto rows = r.extCatalog !is null ? r.extRows : commandsIn(head);
    auto rest = pos[1 .. $];

    // Explicit x-cli paths: the next word of each path extending `rest`.
    foreach (ref c; rows)
    {
        if (c.operatorOnly && !op)
            continue;
        foreach (p; c.paths)
            if (p.length > rest.length && p[0 .. rest.length] == rest)
                out_ ~= Cand(p[rest.length], p.length == rest.length + 1 ? c.summary : "");
    }

    if (rest.length == 0)
    {
        foreach (ref c; rows)
        {
            if ((c.operatorOnly && !op) || c.paths.length)
                continue;
            out_ ~= Cand(c.resource, "");
            out_ ~= Cand(c.verb, "");
        }
    }
    else if (rest.length == 1)
    {
        foreach (ref c; rows)
        {
            if ((c.operatorOnly && !op) || c.paths.length)
                continue;
            if (c.resource == rest[0])
                out_ ~= Cand(c.verb, c.summary);
            else if (c.verb == rest[0])
                out_ ~= Cand(c.resource, c.summary);
        }
    }
    return sorted(out_);
}

/// Sorted by value; the first description of a value wins.
private Cand[] sorted(Cand[] cs)
{
    Cand[] out_;
    bool[string] seen;
    auto copy = cs.dup;
    copy.sort!((a, b) => a.value < b.value);
    foreach (c; copy)
    {
        if (c.value in seen)
        {
            if (!out_[$ - 1].doc.length)
                out_[$ - 1].doc = c.doc;
            continue;
        }
        seen[c.value] = true;
        out_ ~= c;
    }
    return out_;
}

private Cand[] map(string[] names, Cand delegate(string) @safe f)
{
    Cand[] out_;
    foreach (n; names)
        out_ ~= f(n);
    return out_;
}

/// The command `prev` names, or null.
private const(Command)* commandOf(string[] prev, Dirs dirs)
{
    auto r = parsed(prev, dirs);
    if (r.kind == Kind.invoke || r.kind == Kind.helpCommand)
        return r.command;
    return null;
}

/// Flags valid after `prev`.
private Cand[] flagsFor(string[] prev, string[] pos, Dirs dirs)
{
    Cand[] out_;
    if (pos.length && pos[0] == "completion")
        return [Cand("--shell=", "bash|zsh|fish (completion install)")];
    if (pos.length && pos[0] == "catalog")
        return [Cand("--json", "Required: JSON output"), Cand("--namespace=", "Only this namespace"),
            Cand("--resource=", "Only this resource"), Cand("--operator", "Include operator-only operations")];
    if (pos.length && pos[0] == "complete")
        return [Cand("--json", "Required: JSON output"),
            Cand("--tokens=", "The words after d8ctl, last = the one being typed"),
            Cand("--line=", "The whole command line")];
    if (pos.length && (pos[0] == "profile" || (pos.length >= 2 && pos[1] == "profile")))
    {
        out_ ~= [Cand("--from-env", "profile add: copy CAMUNDA_* from the environment"),
            Cand("--use", "profile add: make it active"),
            Cand("--force", "profile add: overwrite"),
            Cand("--none", "profile use: clear the active profile")];
        out_ ~= configSwitches();
        out_ ~= Cand("--header=", "Extra HTTP header 'Name: value' (repeatable)");
        return out_;
    }
    if (pos.length && (pos[0] == "extension" || pos[0] == "extensions"))
    {
        out_ ~= [Cand("--spec=", "extension add: spec URL or path"),
            Cand("--base-url=", "extension add: API base URL or path"),
            Cand("--profile=", "Profile for auth"),
            Cand("--check", "extension list: compare with the server"),
            Cand("--all", "extension update: every extension"),
            Cand("--header=", "Extra HTTP header 'Name: value' (repeatable)")];
        out_ ~= configSwitches();
        return out_;
    }
    if (auto c = commandOf(prev, dirs))
    {
        foreach (q; c.requiredQuery)
            out_ ~= Cand("--" ~ q ~ "=", "(required) " ~ paramDesc(c, q));
        foreach (q; c.optionalQuery)
            out_ ~= Cand("--" ~ q ~ "=", paramDesc(c, q));
        foreach (ref f; c.bodyFields)
            out_ ~= Cand("--" ~ f.name ~ "=", (f.required ? "(required) " : "") ~ f.kind
                ~ (f.doc.length ? ": " ~ f.doc : ""));
        if (c.hasBody)
            out_ ~= Cand("--body=", "The JSON body (merged with field flags)");
        if (c.responseTarget.length)
            out_ ~= Cand("--fields=", "Select response fields: a,b.c");
    }
    out_ ~= globalFlags.dup;
    out_ ~= configSwitches();
    return out_;
}

/// Completion description of a query flag: its kind and documentation.
private string paramDesc(const Command* c, string name)
{
    foreach (ref p; c.params)
        if (p.name == name && p.location == "query")
            return "query " ~ p.kind ~ (p.doc.length ? ": " ~ p.doc : "")
                ~ (p.example.length ? " (e.g. " ~ p.example ~ ")" : "");
    return "query";
}

private Cand[] configSwitches()
{
    Cand[] out_;
    foreach (k; configKeys)
        out_ ~= Cand(keyToSwitch(k) ~ "=", k);
    return out_;
}

/// Values for `--name`; null when the flag takes no known values.
/// `spaceForm`: completing `--name <value>` (only the space-form flags).
private Cand[] flagValues(string name, string[] prev, Dirs dirs, bool spaceForm)
{
    if (spaceForm && !spaceFlag("--" ~ name))
        return null;
    switch (name)
    {
    case "profile":
        return profileNames(dirs);
    case "output":
        return [Cand("json", ""), Cand("text", "")];
    case "order":
        return [Cand("resource", ""), Cand("verb", "")];
    case "shell":
        return [Cand("bash", ""), Cand("zsh", ""), Cand("fish", "")];
    default:
        break;
    }
    if (spaceForm)
        return [];
    auto c = commandOf(prev, dirs);
    if (c is null)
        return null;
    if (name == "fields")
        return null; // comma lists: left to the user (see `--help`)
    foreach (ref p; c.params)
        if (p.name == name && p.location == "query")
        {
            if (p.values.length)
            {
                Cand[] out_;
                foreach (v; p.values)
                    out_ ~= Cand(v, "");
                return out_;
            }
            if (p.kind == "boolean")
                return [Cand("true", ""), Cand("false", "")];
            // A spec example (d8ctl#46): a hint only; any value is accepted.
            if (p.example.length)
                return [Cand(p.example, "example")];
        }
    foreach (ref f; c.bodyFields)
        if (f.name == name)
        {
            if (f.values.length)
            {
                Cand[] out_;
                foreach (v; f.values)
                    out_ ~= Cand(v, "");
                return out_;
            }
            if (f.kind == "boolean")
                return [Cand("true", ""), Cand("false", "")];
        }
    return null;
}

private Cand[] profileNames(Dirs dirs)
{
    Cand[] out_;
    try
    {
        auto s = loadSources(dirs);
        foreach (p; allProfiles(s))
            out_ ~= Cand(p.name, "");
    }
    catch (Exception)
    {
        // unreadable profile files: offer no profile names; a completion must never error
    }
    return out_;
}

private string[] extensionNames(Dirs dirs)
{
    try
        return listExtensionNames(dirs.d8ctl);
    catch (Exception) // unreadable extensions dir: offer no names; a completion must never error
        return null;
}

// ---- Scripts ----

/// The completion script for `shell`; throws on an unknown shell.
string script(string shell)
{
    switch (shell)
    {
    case "bash":
        return bashScript;
    case "zsh":
        return zshScript;
    case "fish":
        return fishScript;
    case "powershell", "pwsh":
        return powershellScript;
    default:
        throw new UsageException("unknown shell '" ~ shell
            ~ "' (expected bash, zsh, fish or powershell)");
    }
}

private enum bashScript = `# d8ctl bash completion. Load with: source <(d8ctl completion bash)
_d8ctl() {
    local line="${COMP_LINE:0:COMP_POINT}" cur pre c d out directive=0
    local -a words=() cands=()
    read -ra words <<< "$line"
    [[ "$line" =~ [[:space:]]$ ]] && words+=("")
    cur="${words[${#words[@]}-1]}"
    out=$("${words[0]/#\~/$HOME}" __complete "${words[@]:1}" 2>/dev/null) || return 0
    # bash splits words at = and :, so strip what it already has.
    pre="${cur%"${cur##*[=:]}"}"
    COMPREPLY=()
    while IFS= read -r c; do
        case "$c" in
            :*) directive="${c#:}" ;;
            *) c="${c%%$'\t'*}"
               if [[ "$c" == "$cur"* ]]; then printf -v c '%q' "${c#"$pre"}"; COMPREPLY+=("$c"); fi ;;
        esac
    done <<< "$out"
    if (( directive & 1 )) && type compopt >/dev/null 2>&1; then compopt -o nospace; fi
    return 0
}
complete -F _d8ctl d8ctl
`;

private enum zshScript = `#compdef d8ctl
# d8ctl zsh completion. Load with: source <(d8ctl completion zsh)
# (after compinit), or install as _d8ctl on your $fpath.
_d8ctl() {
    local out line directive=0 v d
    local -a lines cands
    out=$("${words[1]/#\~/$HOME}" __complete "${(@)words[2,CURRENT]}" 2>/dev/null) || return 1
    lines=("${(@f)out}")
    for line in $lines; do
        if [[ "$line" == :* ]]; then directive="${line#:}"; continue; fi
        v="${line%%$'\t'*}"
        v="${v//:/\\:}"
        if [[ "$line" == *$'\t'* ]]; then d="${line#*$'\t'}"; cands+=("$v:$d"); else cands+=("$v"); fi
    done
    (( ${#cands} )) || return 1
    if (( directive & 1 )); then
        _describe -t d8ctl d8ctl cands -S ''
    else
        _describe -t d8ctl d8ctl cands
    fi
}
if [ "$funcstack[1]" = "_d8ctl" ]; then
    _d8ctl "$@"
else
    compdef _d8ctl d8ctl
fi
`;

private enum fishScript = `# d8ctl fish completion. Load with: d8ctl completion fish | source
function __d8ctl_complete
    set -l tokens (commandline -opc) (commandline -ct)
    set -l out ($tokens[1] __complete $tokens[2..-1] 2>/dev/null)
    set -e out[-1]
    printf '%s\n' $out
end
complete -c d8ctl -f -a '(__d8ctl_complete)'
`;

private enum powershellScript = `# d8ctl PowerShell completion. Load with:
#   d8ctl completion powershell | Out-String | Invoke-Expression
Register-ArgumentCompleter -Native -CommandName 'd8ctl', 'd8ctl.exe' -ScriptBlock {
    param($wordToComplete, $commandAst, $cursorPosition)
    $words = @($commandAst.CommandElements |
        Where-Object { $_.Extent.StartOffset -lt $cursorPosition } |
        ForEach-Object { $_.ToString() })
    $exe = $words[0]
    $rest = @($words | Select-Object -Skip 1)
    if ($wordToComplete -eq '') { $rest += '""' }
    $out = @(& $exe __complete @rest 2>$null)
    if ($out.Count -eq 0) { return }
    $out[0..($out.Count - 2)] | Where-Object { $_ -like "$wordToComplete*" } | ForEach-Object {
        $v, $d = $_ -split "` ~ "`" ~ `t", 2
        if (-not $d) { $d = $v }
        [System.Management.Automation.CompletionResult]::new($v, $v, 'ParameterValue', $d)
    }
}
`;

// ---- install ----

/// Where `completion install` writes for `shell`, under `home`.
string installTarget(string shell, string home)
{
    import std.path : buildPath;

    switch (shell)
    {
    case "bash":
        return buildPath(home, ".bashrc");
    case "zsh":
        return buildPath(home, ".zshrc");
    case "fish":
        return buildPath(home, ".config", "fish", "completions", "d8ctl.fish");
    default:
        throw new UsageException("completion install supports bash, zsh and fish; for "
            ~ "PowerShell add `d8ctl completion powershell | Out-String | Invoke-Expression` to $PROFILE");
    }
}

private enum marker = "# d8ctl completion";

/// The line `install` adds to a bash/zsh startup file.
string sourceLine(string shell)
{
    return marker ~ "\ncommand -v d8ctl >/dev/null 2>&1 && source <(d8ctl completion " ~ shell ~ ")\n";
}

/// Install completion for `shell` (empty: from `$SHELL`) under `home`.
/// Idempotent; returns what it did.
string install(string shell, string home, string envShell)
{
    import std.file : append, exists, mkdirRecurse, readText, write;
    import std.path : baseName, dirName;

    if (!shell.length)
        shell = envShell.length ? baseName(envShell) : "";
    if (!shell.length)
        throw new UsageException(
            "cannot tell your shell; pass --shell=bash|zsh|fish");
    auto target = installTarget(shell, home);
    if (shell == "fish")
    {
        mkdirRecurse(dirName(target));
        write(target, "d8ctl completion fish | source\n");
        return "wrote " ~ target ~ "\n";
    }
    if (exists(target) && readText(target).indexOf(marker) >= 0)
        return "already installed in " ~ target ~ "\n";
    append(target, "\n" ~ sourceLine(shell));
    auto extra = shell == "zsh" ? " (after compinit; oh-my-zsh and most setups run it)" : "";
    return "added to " ~ target ~ extra ~ "; open a new shell to use it\n";
}

// ---- tests ----

version (unittest)
{
    private Dirs tmpDirs()
    {
        import std.file : mkdirRecurse, tempDir;
        import std.path : buildPath;
        import std.conv : to;
        import std.process : thisProcessID;

        auto root = buildPath(tempDir, "d8ctl-compl-" ~ thisProcessID.to!string);
        mkdirRecurse(buildPath(root, "d8"));
        return Dirs(buildPath(root, "d8"), buildPath(root, "c8"), buildPath(root, "modeler"));
    }

    private string[] values(string out_)
    {
        import std.string : splitLines;

        string[] vs;
        foreach (l; out_.splitLines)
        {
            if (l.startsWith(":"))
                continue;
            auto t = l.indexOf('\t');
            vs ~= t >= 0 ? l[0 .. t] : l;
        }
        return vs;
    }

    private string directiveOf(string out_)
    {
        import std.string : splitLines;

        return out_.splitLines[$ - 1];
    }
}

unittest
{
    auto d = tmpDirs();
    // Top level.
    auto top = values(complete([""], d));
    assert(top.canFind("cluster") && top.canFind("profile") && top.canFind("completion"));
    assert(values(complete(["cl"], d)) == ["cluster"]);
    // Resource then verb, verb then resource.
    auto res = values(complete(["cluster", "top"], d));
    assert(res.canFind("topology"));
    assert(values(complete(["cluster", "topology", ""], d)) == ["get"]);
    assert(values(complete(["cluster", "get", "topo"], d)) == ["topology"]);
    auto verbs = values(complete(["cluster", "jobs", ""], d));
    assert(verbs.canFind("activate"));
    // Nothing more after a full command.
    assert(values(complete(["cluster", "topology", "get", ""], d)).length == 0);
}

unittest
{
    auto d = tmpDirs();
    // Flags: body fields, globals, config switches; `=` flags ask for no space.
    auto out_ = complete(["cluster", "jobs", "activate", "--"], d);
    auto fl = values(out_);
    assert(fl.canFind("--type=") && fl.canFind("--maxJobsToActivate="));
    assert(fl.canFind("--dry-run") && fl.canFind("--camunda-rest-address="));
    assert(directiveOf(out_) == ":1");
    assert(directiveOf(complete(["cluster", "jobs", "activate", "--dry"], d)) == ":0");
    // Verb-first order finds the same command.
    assert(values(complete(["cluster", "activate", "jobs", "--ty"], d)) == ["--type="]);
    // Global values.
    assert(values(complete(["--output="], d)) == ["--output=json", "--output=text"]);
    assert(values(complete(["--output", "t"], d)) == ["text"]);
    assert(values(complete(["completion", ""], d)).canFind("zsh"));
    assert(values(complete(["completion", "install", "--shell="], d)).canFind("--shell=fish"));
}

unittest
{
    // Enum values from the spec, and booleans.
    auto d = tmpDirs();
    import d8ctl.catalog : catalog;

    foreach (ref c; catalog)
        foreach (ref f; c.bodyFields)
            if (f.values.length)
            {
                auto got = values(complete([c.namespace, c.resource, c.verb, "--" ~ f.name ~ "="], d));
                assert(got.length == f.values.length, c.operationId);
                assert(got[0] == "--" ~ f.name ~ "=" ~ f.values[0]);
                return;
            }
    assert(false, "no enum body field in the catalog");
}

unittest
{
    // Profiles and extensions from the config dir.
    import std.file : mkdirRecurse, write;
    import std.path : buildPath;
    import d8ctl.profiles : profilesPath;

    auto d = tmpDirs();
    write(profilesPath(d.d8ctl), `{"profiles":{"alpha":{},"beta":{}}}`);
    auto ps = values(complete(["profile", "use", ""], d));
    assert(ps.canFind("alpha") && ps.canFind("beta"));
    assert(values(complete(["--profile=a"], d)) == ["--profile=alpha"]);
    assert(values(complete(["--profile", "b"], d)) == ["beta"]);
    assert(values(complete(["use", "profile", ""], d)).canFind("alpha"));
    assert(values(complete(["extension", ""], d)).canFind("update"));
}

unittest
{
    // PowerShell 5 passes an empty word as "".
    auto d = tmpDirs();
    assert(values(complete(["cluster", "topology", `""`], d)) == ["get"]);
    // Descriptions never break the line format.
    import std.string : splitLines;

    foreach (l; complete(["cluster", ""], d).splitLines)
        assert(l.indexOf('\n') < 0);
}

unittest
{
    import std.exception : assertThrown;
    import d8ctl.dispatch : UsageException;

    foreach (s; shells)
        assert(script(s).indexOf("__complete") >= 0, s);
    assert(script("bash").indexOf("complete -F _d8ctl d8ctl") >= 0);
    assert(script("zsh").startsWith("#compdef d8ctl"));
    assertThrown!UsageException(script("tcsh"));
}

unittest
{
    // install: idempotent rc line for bash/zsh; a file for fish.
    import std.file : exists, mkdirRecurse, readText, tempDir;
    import std.path : buildPath;
    import std.conv : to;
    import std.process : thisProcessID;
    import std.exception : assertThrown;
    import d8ctl.dispatch : UsageException;

    auto home = buildPath(tempDir, "d8ctl-compl-home-" ~ thisProcessID.to!string);
    mkdirRecurse(home);
    assert(install("", home, "/bin/zsh").startsWith("added to"));
    assert(install("zsh", home, "").startsWith("already installed"));
    assert(readText(buildPath(home, ".zshrc")).indexOf("d8ctl completion zsh") >= 0);
    install("bash", home, "");
    install("fish", home, "");
    assert(exists(buildPath(home, ".config", "fish", "completions", "d8ctl.fish")));
    assertThrown!UsageException(install("", home, ""));
    assertThrown!UsageException(install("powershell", home, ""));
}

unittest
{
    // complete --json (d8ctl#46): the same answers as __complete, for programs.
    import std.json : parseJSON;
    import std.exception : assertThrown;

    auto d = tmpDirs();
    string[] vals(string json)
    {
        string[] vs;
        foreach (i; parseJSON(json)["items"].arrayNoRef)
            vs ~= i["value"].str;
        return vs;
    }
    // The cases of scripts/test-completion.sh.
    assert(vals(completeJson(completeWords(["--json", "--tokens=cluster get topo"]), d)).canFind("topology"));
    assert(vals(completeJson(completeWords(["--json", "--line=d8ctl --output="]), d)).canFind("--output=json"));
    assert(vals(completeJson(completeWords(["--json", "--tokens=cluster topology "]), d)) == ["get"]);
    auto j = parseJSON(completeJson(completeWords(["--json", "--line=d8ctl cluster jobs activate --ty"]), d));
    assert(j["items"][0]["value"].str == "--type=" && j["noSpace"].boolean);
    assert(completeWords(["--tokens="]) == [""]);
    assert(completeWords(["--line=d8ctl"]) == [""]);
    assertThrown!UsageException(completeWords(["--json"]));
    assertThrown!UsageException(completeWords(["--bogus", "--tokens=x"]));
}

unittest
{
    // A spec example is offered as a non-binding hint (d8ctl#46).
    import std.file : mkdirRecurse, write;
    import d8ctl.catalog : catalog;

    auto d = tmpDirs();
    foreach (ref c; catalog)
        foreach (ref p; c.params)
            if (p.location == "query" && p.example.length && !p.values.length && p.kind != "boolean")
            {
                auto got = values(complete([c.namespace, c.resource, c.verb, "--" ~ p.name ~ "="], d));
                assert(got == ["--" ~ p.name ~ "=" ~ p.example], c.operationId);
                return;
            }
    // The bundled spec may carry no query example; nothing to check then.
}
