SWIFT_SOURCES := Package.swift Sources Tests

.PHONY: setup build app test test-slow check-slow-gates bench test-app test-hooks check-docs run lint format check clean

setup:
	git config --local core.hooksPath .githooks

build:
	swift build

app:
	scripts/bundle.sh

# The CLI tests run in their own process. They wait synchronously for a child process, so
# they block the threads of the concurrency pool, and the async tests of the other targets
# starve.
test:
	swift test --skip AppBundleTests --skip DirigibleCLITests
	swift test --filter DirigibleCLITests

# The gate of a slow test. The checks match the whole expression, so a comment that names the
# variable does not change the count.
SLOW_GATE = environment["DIRIGIBLE_SLOW_TESTS"]
# The name of each slow test: the function after its gate.
SLOW_TESTS = $(shell grep -rhF -A1 '$(SLOW_GATE)' Tests | grep -oE 'func [A-Za-z0-9_]+' | cut -c6- | paste -sd'|' -)

# The slow tests run in their own process after the other tests. Their disk and CPU load
# makes the timed tests fail when both run in one process. They run one at a time, so the
# benchmarks do not measure the load of the other slow tests.
test-slow: check-slow-gates test
	DIRIGIBLE_SLOW_TESTS=1 swift test --no-parallel --skip AppBundleTests --filter '$(SLOW_TESTS)'

# The slow tests that match FILTER in an optimized build, for a budget that holds only with -O.
bench:
	scripts/bench.sh '$(FILTER)'

# Each slow-test gate has its func on the next line, so SLOW_TESTS finds every slow test.
# make check runs this grep, because make check does not run the slow tests.
check-slow-gates:
	@test "$$(echo '$(SLOW_TESTS)' | tr '|' '\n' | grep -c .)" -eq "$$(grep -rF '$(SLOW_GATE)' Tests | wc -l | tr -d ' ')" \
		|| { echo "check-slow-gates: put the func of each slow test on the line after its gate"; exit 1; }

test-app: app
	DIRIGIBLE_APP="$(CURDIR)/build/Dirigible.app" swift test --filter AppBundleTests

test-hooks:
	.claude/hooks/git-guardrails.test.sh
	scripts/probe.test.sh

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

check: lint check-docs check-slow-gates test test-hooks test-app

clean:
	rm -rf .build build
