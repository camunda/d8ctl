.PHONY: help generate generate-local bundle-spec test lint build check

help:
	@echo "d8ctl — generated Camunda 8 CLI spike"
	@echo "  make generate        Bundle the spec from camunda/camunda (SPEC_REF, default main) + rebuild the catalog"
	@echo "  make generate-local  Rebuild the catalog from the committed external-spec/bundled/"
	@echo "  make test       dub test"
	@echo "  make lint       check-safe.sh + D-Scanner"
	@echo "  make build      dub build -b release"
	@echo "  make check      test + lint"

bundle-spec:
	npm run bundle:spec

generate: bundle-spec generate-local

generate-local:
	python3 scripts/generate.py

test:
	dub test

lint:
	./scripts/check-safe.sh
	dub run -q dscanner@0.16.0-beta.5 -- --styleCheck --config dscanner.ini source

build:
	dub build -b release

check: test lint
