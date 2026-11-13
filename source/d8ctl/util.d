/// Shared string helpers. No extra packages — Phobos only.
module d8ctl.util;

@safe:

import std.string : toLower;

string kebab(string s)
{
    char[] out_;
    foreach (i, c; s)
    {
        if (c >= 'A' && c <= 'Z')
        {
            if (i > 0) out_ ~= '-';
            out_ ~= cast(char)(c + 32);
        }
        else if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9'))
            out_ ~= c;
        else if (out_.length && out_[$ - 1] != '-')
            out_ ~= '-';
    }
    while (out_.length && out_[$ - 1] == '-') out_ = out_[0 .. $ - 1];
    return out_.idup;
}

bool eqIgnoreCase(string a, string b)
{
    return a.toLower == b.toLower;
}

unittest
{
    assert(kebab("ProcessInstance") == "process-instance");
    assert(kebab("getTopology") == "get-topology");
    assert(kebab("cluster") == "cluster");
    assert(eqIgnoreCase("GET", "get"));
}
