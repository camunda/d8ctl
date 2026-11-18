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
    import std.process : environment;

    // std.process maps to setenv/unsetenv on POSIX and
    // SetEnvironmentVariableW on Windows (which has no setenv).
    if (value is null)
        environment.remove(name);
    else
        environment[name] = value;
}

/// The process value of `name`, or null when unset.
string getEnv(string name) @trusted
{
    import std.process : environment;

    return environment.get(name, null);
}

/// Names of every variable in the process environment.
/// `@trusted`: `environment.toAA` copies the environ block into GC strings;
/// nothing aliases the process-global storage afterwards.
string[] envNames() @trusted
{
    import std.process : environment;

    return environment.toAA().keys;
}

/// Status and body of a bounded GET.
struct BoundedResponse
{
    int status;
    string body_;
    string etag;
}

/// GET `url` like the SDK's `camunda.http.perform`, but abort the transfer
/// as soon as more than `maxBytes` arrive, so an untrusted server cannot
/// exhaust memory before any later size check runs. Captures the ETag.
/// `@trusted`: std.net.curl's `HTTP` is `@system` only through its C handle;
/// the callbacks copy received bytes into a GC buffer that never escapes
/// the request.
BoundedResponse boundedGet(string url, const string[string] headers, size_t maxBytes,
    string certPath, string keyPath, string caPath, string keyPassphrase,
    long timeoutMs = 30_000) @trusted
{
    import camunda.errors : NetworkException;
    import core.time : msecs;
    import etc.c.curl : CurlOption;
    import std.conv : to;
    import std.net.curl : CurlException, HTTP;
    import std.uni : toLower;

    auto http = HTTP(url);
    foreach (k, v; headers)
        http.addRequestHeader(k, v);
    http.connectTimeout = timeoutMs.msecs;
    http.operationTimeout = timeoutMs.msecs;
    if (caPath.length)
        http.caInfo = caPath;
    if (certPath.length)
    {
        http.handle.set(CurlOption.sslcert, certPath);
        if (keyPath.length)
            http.handle.set(CurlOption.sslkey, keyPath);
        if (keyPassphrase.length)
            http.handle.set(CurlOption.keypasswd, keyPassphrase);
    }
    http.method = HTTP.Method.get;
    ubyte[] buf;
    bool tooBig;
    string etag;
    http.onReceiveHeader = (in char[] key, in char[] value) {
        if (key.toLower == "etag")
            etag = value.idup;
    };
    http.onReceive = (ubyte[] data) {
        if (buf.length + data.length > maxBytes)
        {
            tooBig = true;
            return cast(size_t) 0; // short write: curl aborts the transfer
        }
        buf ~= data;
        return data.length;
    };
    try
        http.perform();
    catch (CurlException e)
    {
        if (tooBig)
            throw new NetworkException("response exceeds " ~ maxBytes.to!string ~ " bytes",
                __FILE__, __LINE__, e);
        throw new NetworkException(e.msg, __FILE__, __LINE__, e);
    }
    BoundedResponse r;
    r.status = http.statusLine.code;
    r.body_ = cast(string) buf.idup;
    r.etag = etag;
    return r;
}
