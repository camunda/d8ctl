#!/usr/bin/env dub
/+ dub.sdl:
    name "d8ctl-generate"
    dependency "camunda-orchestration-sdk:openapi" version="~>11.0.0-alpha.4"
    dflags "-I$PACKAGE_DIR/../source" "-i=d8ctl.specmodel" "-preview=dip1000" "-preview=nosharedaccess"
    toolchainRequirements dmd="no" gdc="no" ldc=">=1.43.0"
+/
/// Generate source/d8ctl/generated/catalog.d from external-spec/bundled/
/// (`npm run bundle:spec`). Run: dub run --single scripts/generate.d
/// All naming and flag rules live in d8ctl.specmodel.
module generate;

@safe:

import std.file : exists, mkdirRecurse, readText, write;
import std.path : buildPath, dirName, absolutePath;
import std.stdio : writefln;

import camunda.openapi : OpenApiException;
import d8ctl.specmodel : buildCatalog, renderCatalogModule;

// std.stdio.stderr is a __gshared global, so Phobos cannot infer @safe for it;
// writing one line from this single-threaded script is safe.
void fail(string msg) @trusted
{
    import std.stdio : stderr;

    stderr.writeln("generate: ", msg);
}

int main()
{
    const root = __FILE_FULL_PATH__.dirName.dirName;
    const meta = buildPath(root, "external-spec", "bundled", "spec-metadata.json");
    const spec = buildPath(root, "external-spec", "bundled", "rest-api.bundle.json");
    const outDir = buildPath(root, "source", "d8ctl", "generated");
    foreach (f; [meta, spec])
        if (!f.exists)
        {
            fail("missing " ~ f ~ " (run: npm install && npm run bundle:spec)");
            return 1;
        }
    try
    {
        auto cat = buildCatalog(readText(spec), readText(meta), "cluster");
        mkdirRecurse(outDir);
        write(buildPath(outDir, "catalog.d"), renderCatalogModule(cat, "scripts/generate.d"));
        size_t withFields, fields;
        foreach (c; cat.commands)
            if (c.bodyFields.length)
            {
                withFields++;
                fields += c.bodyFields.length;
            }
        writefln("generate: %s commands, %s with body flags (%s fields) -> source/d8ctl/generated/catalog.d",
            cat.commands.length, withFields, fields);
        return 0;
    }
    catch (OpenApiException e)
    {
        fail(e.msg);
        return 1;
    }
}
