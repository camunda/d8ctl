/// Package version, stamped by `scripts/prepare-release.sh` during semantic-release.
module d8ctl.version_;

@safe:

/// SemVer of this CLI (`dub.json` `version`, git tag `v` + this string).
enum cliVersion = "0.5.0";
