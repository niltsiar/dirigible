SWIFT_SOURCES := Package.swift Sources Tests

.PHONY: build app test run lint format check clean

build:
	swift build

app:
	scripts/bundle.sh

test: app
	swift test

run: app
	open build/Dirigible.app

lint:
	swift format lint --strict --recursive $(SWIFT_SOURCES)

format:
	swift format format --in-place --recursive $(SWIFT_SOURCES)

check: lint test

clean:
	rm -rf .build build
