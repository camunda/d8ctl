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
