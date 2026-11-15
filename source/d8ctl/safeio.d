/// `@trusted` wrappers around Phobos stdio. `stdout`/`stderr` are `@system`
/// only because the `File` is a `__gshared` global; every `File` operation
/// locks the stream itself.
module d8ctl.safeio;

@safe:

import std.stdio : File;

/// `std.stdio.stdout`.
@property ref File stdOut() @trusted
{
    import std.stdio : stdout;
    return stdout;
}

/// `std.stdio.stderr`.
@property ref File stdErr() @trusted
{
    import std.stdio : stderr;
    return stderr;
}

/// Lowercase hex SHA-256 of `data` (extension cache fingerprints, #9).
/// `@trusted`: std.digest.sha is `@system` by inference default only — it
/// hashes the bytes it is handed and returns a value; no pointers escape.
string sha256Hex(scope const(char)[] data) @trusted
{
    import std.digest.sha : sha256Of;
    import std.digest : toHexString, LetterCase;

    return sha256Of(data).toHexString!(LetterCase.lower).idup;
}

unittest
{
    assert(sha256Hex("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
    assert(sha256Hex("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
}

/// Set (`value` non-null) or remove (null) a process environment variable.
/// `@trusted`: `std.process.environment` mutation is `@system` because the
/// environ block is process-global; d8ctl mutates it only while building an
/// extension transport (single-threaded, before any request), so no data
/// race is possible.
void setEnv(string name, string value) @trusted
{
    import core.sys.posix.stdlib : setenv, unsetenv;
    import std.string : toStringz;

    if (value is null)
        unsetenv(name.toStringz);
    else
        setenv(name.toStringz, value.toStringz, 1);
}

/// The process value of `name`, or null when unset.
string getEnv(string name) @trusted
{
    import std.process : environment;

    return environment.get(name, null);
}
