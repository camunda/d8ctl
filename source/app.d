/// Program entry. Kept out of `d8ctl.app` so `dub test` can compile that
/// module (dub excludes any file that contains `main`).
module app;

@safe:

import d8ctl.app : run;

int main(string[] args)
{
    return run(args);
}
