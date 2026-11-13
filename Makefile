.PHONY: help generate test lint build check

help:
	@echo "d8ctl — generated Camunda 8 CLI spike"
	@echo "  make generate   Rebuild source/d8ctl/generated/catalog.d from the D SDK spec"
	@echo "  make test       dub test"
	@echo "  make lint       check-safe.sh + D-Scanner"
	@echo "  make build      dub build -b release"
	@echo "  make check      test + lint"

generate:
	python3 scripts/generate.py

test:
	dub test

lint:
	./scripts/check-safe.sh
	dub run -q dscanner@0.16.0-beta.5 -- --styleCheck --config dscanner.ini source

build:
	dub build -b release

check: test lint
