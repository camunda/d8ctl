# [0.6.0](https://github.com/camunda/d8ctl/compare/v0.5.0...v0.6.0) (2026-11-15)


### Features

* runtime extensions — namespaces generated from a server's OpenAPI spec ([#13](https://github.com/camunda/d8ctl/issues/13)) ([ee39b0c](https://github.com/camunda/d8ctl/commit/ee39b0cc870d9012c4b197af4a4586d687204605)), closes [nano-ide#617](https://github.com/nano-ide/issues/617) [#9](https://github.com/camunda/d8ctl/issues/9)

# [0.5.0](https://github.com/camunda/d8ctl/compare/v0.4.0...v0.5.0) (2026-11-15)


### Features

* port the catalog generator to D as a reusable spec model ([#12](https://github.com/camunda/d8ctl/issues/12)) ([bd7b195](https://github.com/camunda/d8ctl/commit/bd7b1950ebb0687c84be243efde0ba7fae041d6c)), closes [#8](https://github.com/camunda/d8ctl/issues/8)

# [0.4.0](https://github.com/camunda/d8ctl/compare/v0.3.0...v0.4.0) (2026-11-14)


### Features

* custom HTTP headers (--header, CAMUNDA_DEFAULT_HEADERS) ([#10](https://github.com/camunda/d8ctl/issues/10)) ([edb9fcb](https://github.com/camunda/d8ctl/commit/edb9fcbbcc10ff84ed15a99f11629840a3568b58)), closes [#7](https://github.com/camunda/d8ctl/issues/7)

# [0.3.0](https://github.com/camunda/d8ctl/compare/v0.2.0...v0.3.0) (2026-11-14)


### Features

* read c8ctl profiles and Camunda Modeler connections ([7ddfba2](https://github.com/camunda/d8ctl/commit/7ddfba26f29e9346fb842ee6b00cd3ef8c8d95b3))

# [0.2.0](https://github.com/camunda/d8ctl/compare/v0.1.1...v0.2.0) (2026-11-14)


### Features

* connection profiles and --camunda-* config switches ([012c7f8](https://github.com/camunda/d8ctl/commit/012c7f8b36ee2e84d51e5214754291b66ec5798d))

## [0.1.1](https://github.com/camunda/d8ctl/compare/v0.1.0...v0.1.1) (2026-11-13)


### Bug Fixes

* send cluster-admin commands to the bare root server, not /v2 ([ad2a84f](https://github.com/camunda/d8ctl/commit/ad2a84f836bb508b1d54df29336369d777cfce74)), closes [camunda/orchestration-cluster-api-dlang#6](https://github.com/camunda/orchestration-cluster-api-dlang/issues/6)

# 0.1.0 (2026-11-13)

First pre-release. (Briefly published as v1.0.0 / v1.1.0; those were withdrawn.)


### Bug Fixes

* check the D SDK out inside the workspace in CI ([2064da1](https://github.com/camunda/d8ctl/commit/2064da12c618af239867c5aede2ef7ea96ce9698))
* put the whole OC surface under cluster ([ddd6a76](https://github.com/camunda/d8ctl/commit/ddd6a76e2346e6bf67aca5f8bf3731594a6871fd))


### Features

* source the spec from camunda/camunda via camunda-schema-bundler ([4c91e1c](https://github.com/camunda/d8ctl/commit/4c91e1c3de5b2a20144ac91fccb6448bd268e01c)), closes [#6](https://github.com/camunda/d8ctl/issues/6)
* expose top-level JSON body fields as --flags ([c99e07c](https://github.com/camunda/d8ctl/commit/c99e07c583b1997d87c8fb5eef52ec847ac8b7e9)), closes [orchestration-cluster-api-dlang#2](https://github.com/orchestration-cluster-api-dlang/issues/2)
* generate the OC command surface from the D SDK ([d4ce9b0](https://github.com/camunda/d8ctl/commit/d4ce9b053e14ad58af79464e5c50c1b598e56d52))
* GitHub Releases via semantic-release ([2e18200](https://github.com/camunda/d8ctl/commit/2e18200565f6d5b3c76c46a84a155e72a94841e5))
