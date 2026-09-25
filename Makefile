SWIFT_SOURCES := Package.swift Sources Tests

.PHONY: setup build app test test-slow test-app test-hooks check-docs run lint format check clean

setup:
	git config --local core.hooksPath .githooks

build:
	swift build

app:
	scripts/bundle.sh

test:
	swift test --skip AppBundleTests

# The name of each slow test: the function after its DIRIGIBLE_SLOW_TESTS gate.
SLOW_TESTS = $(shell grep -rh -A1 DIRIGIBLE_SLOW_TESTS Tests | grep -oE 'func [A-Za-z0-9_]+' | cut -c6- | paste -sd'|' -)

# The slow tests run in their own process after the other tests. Their disk and CPU load
# makes the timed tests fail when both run in one process. They run one at a time, so the
# benchmarks do not measure the load of the other slow tests.
test-slow: test
	@test "$$(echo '$(SLOW_TESTS)' | tr '|' '\n' | grep -c .)" -eq "$$(grep -r DIRIGIBLE_SLOW_TESTS Tests | wc -l | tr -d ' ')" \
		|| { echo "test-slow: put the func of each slow test on the line after its gate"; exit 1; }
	DIRIGIBLE_SLOW_TESTS=1 swift test --no-parallel --skip AppBundleTests --filter '$(SLOW_TESTS)'

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
