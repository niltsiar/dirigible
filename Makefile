SWIFT_SOURCES := Package.swift Sources Tests

.PHONY: setup build app test test-app test-hooks check-docs run lint format check clean

setup:
	git config --local core.hooksPath .githooks

build:
	swift build

app:
	scripts/bundle.sh

test:
	swift test --skip AppBundleTests

test-app: app
	DIRIGIBLE_APP="$(CURDIR)/build/Dirigible.app" swift test --filter AppBundleTests

test-hooks:
	.claude/hooks/git-guardrails.test.sh

check-docs:
	scripts/check-docs.test.sh
	scripts/check-docs.sh

run: app
	pkill -x Dirigible || true
	open build/Dirigible.app

lint:
	swift format lint --strict --recursive $(SWIFT_SOURCES)

format:
	swift format format --in-place --recursive $(SWIFT_SOURCES)

check: lint check-docs test test-hooks test-app

clean:
	rm -rf .build build
