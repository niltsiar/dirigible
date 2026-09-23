SWIFT_SOURCES := Package.swift Sources Tests

.PHONY: setup build app test test-app run lint format check clean

setup:
	git config --local core.hooksPath .githooks

build:
	swift build

app:
	scripts/bundle.sh

test:
	swift test

test-app: app
	DIRIGIBLE_APP="$(CURDIR)/build/Dirigible.app" swift test --filter AppBundleTests

run: app
	open build/Dirigible.app

lint:
	swift format lint --strict --recursive $(SWIFT_SOURCES)

format:
	swift format format --in-place --recursive $(SWIFT_SOURCES)

check: lint test test-app

clean:
	rm -rf .build build
