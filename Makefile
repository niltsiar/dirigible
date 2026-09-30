SWIFT_SOURCES := Package.swift Sources Tests

.PHONY: setup build app icon-preview test test-slow check-slow-gates check-warnings bench test-app dmg test-dmg test-hooks check-docs run lint format check check-fast check-changed clean

setup:
	git config --local core.hooksPath .githooks

build:
	swift build

app:
	scripts/bundle.sh

# The icon only, with no Swift build: the flat renditions and the macOS 26 looks (decision 0026).
icon-preview:
	scripts/icon.sh --preview

# The CLI tests run in their own process. The CLI helper is async and holds no pool thread.
# But the CLI fixture I/O at the suite start adds to the main-actor stall of the other tests.
# In one process, the stall tripped the 60 s DeviceEventTests watchdog in 3 of 40 runs.
test:
	swift test --skip AppBundleTests --skip DiskImageTests --skip DirigibleCLITests
	swift test --filter DirigibleCLITests

# The gate of a slow test. The checks match the whole expression, so a comment that names the
# variable does not change the count.
SLOW_GATE = environment["DIRIGIBLE_SLOW_TESTS"]
# The name of each slow test: the function after its gate.
SLOW_TESTS = $(shell grep -rhF -A1 '$(SLOW_GATE)' Tests | grep -oE 'func [A-Za-z0-9_]+' | cut -c6- | paste -sd'|' -)

# The slow tests only. They run in their own process: their disk and CPU load makes the timed
# tests fail when both run in one process. Before the push, `make check-changed BASE=<ref>`
# runs `check` first, so the other tests do not run twice. They run one at a time, so the
# benchmarks do not measure the load of the other slow tests.
test-slow: check-slow-gates
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

# The DMG app is a second bundle with the ad-hoc signature, so build/Dirigible.app keeps
# the signature of SIGN_IDENTITY.
dmg:
	SIGN_IDENTITY=- scripts/bundle.sh build/dmg-app/Dirigible.app
	scripts/dmg.sh

test-dmg: dmg
	scripts/test-dmg.sh

test-hooks:
	.claude/hooks/git-guardrails.test.sh
	scripts/probe.test.sh
	scripts/hid.test.sh
	scripts/ax.test.sh
	scripts/screenshot.test.sh
	scripts/screenshots.test.sh
	.claude/skills/deliver/scripts/mutate.test.sh
	.claude/skills/deliver/scripts/run-files.test.sh
	scripts/bench-pairs.test.sh
	scripts/icon.test.sh
	scripts/bundle.test.sh
	scripts/check-changed.test.sh
	.claude/workflows/review-panel.test.sh
	scripts/flake-monitor/sample-threads.test.sh
	scripts/flake-monitor/loop.test.sh

check-docs:
	scripts/check-docs.test.sh
	scripts/check-docs.sh

# Each target of the package treats warnings as errors, with no exception (Package.swift).
check-warnings:
	scripts/check-warnings.test.sh
	scripts/check-warnings.sh

run: app
	pkill -x Dirigible || true
	open build/Dirigible.app

lint:
	swift format lint --strict --recursive $(SWIFT_SOURCES)

format:
	swift format format --in-place --recursive $(SWIFT_SOURCES)

check: lint check-docs check-slow-gates check-warnings test test-hooks test-app

# The checks with no Swift test: for a change to scripts, hooks, or workflows.
check-fast: lint check-docs check-slow-gates check-warnings test-hooks

# Runs the targets that scripts/check-changed.sh picks for the changed paths (decision 0028).
# With BASE, the targets before the push. It fails closed: a script error or a missing targets
# line exits nonzero. An empty make goal would run the default goal setup, so the recipe
# never calls $(MAKE) with no target.
BASE ?=
check-changed:
	@out="$$(scripts/check-changed.sh $(BASE))" || exit 1; \
	printf '%s\n' "$$out"; \
	targets="$$(printf '%s\n' "$$out" | sed -n 's/^targets: //p')"; \
	if [ -z "$$targets" ]; then echo "check-changed: no targets line" >&2; exit 1; fi; \
	if [ "$$targets" = none ]; then exit 0; fi; \
	$(MAKE) $$targets

clean:
	rm -rf .build build
