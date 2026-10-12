SWIFT_SOURCES := Package.swift Sources Tests

.PHONY: setup build app icon-preview test test-filter test-slow test-slow-push check-slow-gates check-warnings check-sizes bench test-app dmg test-dmg test-hooks check-docs run lint format static check check-fast check-changed clean

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
# Process 2 runs also when process 1 fails, so scripts/run-checks.sh sees each failed test.
# Each swift test call goes through scripts/swift-test.sh: a process that ends with exit 0 and no
# report line fails. scripts/bench.sh is the one exception: its release run reads its own result
# lines.
test:
	scripts/swift-test.sh --skip AppBundleTests --skip DiskImageTests --skip DirigibleCLITests; s=$$?; scripts/swift-test.sh --filter DirigibleCLITests && exit $$s

# Only the tests of FILTER (test or suite names with spaces between them), in the two processes
# of test. It fails when no test matched.
test-filter:
	scripts/test-filter.sh $(FILTER)

# The gate of a slow test. The checks match the whole expression, so a comment that names the
# variable does not change the count. scripts/check-changed.sh repeats the expression: change both.
SLOW_GATE = environment["DIRIGIBLE_SLOW_TESTS"]
# The name of each slow test: the function after its gate. The argument holds more grep options.
slow_tests = $(shell grep -rhF -A1 $(1) '$(SLOW_GATE)' Tests | grep -oE 'func [A-Za-z0-9_]+' | cut -c6- | paste -sd'|' -)
SLOW_TESTS = $(call slow_tests)
# The bench files that the push skips: a fast test, or a slow test outside the list, holds each of
# their asserts (decision 0028). make test-slow still runs them. scripts/check-changed.sh reads
# this line: a changed file of the list adds PUSH_RUN=<names>, joined with commas, so
# test-slow-push also runs the slow tests of those files.
PUSH_SKIP = LoudnessExportBenchmark AutoLevelBenchmark LiveLoudnessBenchmark ExportBenchmark PeakComputeBenchmark LoudnessBenchmark InspectionBenchmark EditBenchmark NavigationKeyBenchmark LaneRenderBenchmark MouseEventBenchmark+CommandF FinalizeBenchmark MouseEventBenchmark MouseEventGainBenchmark MouseEventGroupBenchmark MouseEventCrossfadeBenchmark MouseEventRippleBenchmark MouseEventRedrawBenchmark AutoscrollBenchmark FollowScrollBenchmark OverviewBenchmark HeaderDragBenchmark InspectorDragBenchmark LiveTakeBenchmark PlayTickBenchmark DropHighlightBenchmark SnapSearchBenchmark MouseEventSnapBenchmark
PUSH_RUN ?=
comma := ,
SLOW_PUSH_TESTS = $(call slow_tests,$(foreach n,$(filter-out $(subst $(comma), ,$(PUSH_RUN)),$(PUSH_SKIP)),--exclude='$(n).swift'))

# The slow tests only. They run in their own process: their disk and CPU load makes the timed
# tests fail when both run in one process. Before the push, `make check-changed BASE=<ref>`
# runs `check` first, so the other tests do not run twice. They run one at a time, so the
# benchmarks do not measure the load of the other slow tests. A pass writes the date of today,
# so scripts/check-changed.sh adds test-slow-push to a push only once a day (decision 0028).
test-slow: check-slow-gates
	DIRIGIBLE_SLOW_TESTS=1 scripts/swift-test.sh --no-parallel --skip AppBundleTests --filter '$(SLOW_TESTS)'
	date +%F > "$$(git rev-parse --git-common-dir)/dirigible-slow-date"

# The slow tests of the push: test-slow with no test of a PUSH_SKIP file outside PUSH_RUN.
test-slow-push: check-slow-gates
	DIRIGIBLE_SLOW_TESTS=1 scripts/swift-test.sh --no-parallel --skip AppBundleTests --filter '$(SLOW_PUSH_TESTS)'
	date +%F > "$$(git rev-parse --git-common-dir)/dirigible-slow-date"

# The slow tests that match FILTER in an optimized build, for a budget that holds only with -O.
# `swift test -c release` runs the @main of the app, not the tests: scripts/bench.sh removes it.
bench:
	scripts/bench.sh '$(FILTER)'

# Each slow-test gate has its func on the next line, so SLOW_TESTS finds every slow test.
# make check runs this grep, because make check does not run the slow tests. Each PUSH_SKIP name
# is a bench file under Tests/: its name has Benchmark. No test waits with a raw .wait(timeout:
# outside the files of scripts/check-waits.allow: a hold of product work goes through Gate.
check-slow-gates:
	scripts/check-waits.sh
	@for n in $(PUSH_SKIP); do test -n "$$(find Tests -name "$$n.swift" 2>/dev/null)" \
		|| { echo "check-slow-gates: PUSH_SKIP names $$n, which has no file under Tests/"; exit 1; }; \
		case $$n in *Benchmark*) ;; *) echo "check-slow-gates: PUSH_SKIP names $$n, which is not a Benchmark file"; exit 1;; esac; done
	@test "$$(echo '$(SLOW_TESTS)' | tr '|' '\n' | grep -c .)" -eq "$$(grep -rF '$(SLOW_GATE)' Tests | wc -l | tr -d ' ')" \
		|| { echo "check-slow-gates: put the func of each slow test on the line after its gate"; exit 1; }

test-app: app
	DIRIGIBLE_APP="$(CURDIR)/build/Dirigible.app" scripts/swift-test.sh --filter AppBundleTests

# The DMG app is a second bundle with the ad-hoc signature, so build/Dirigible.app keeps
# the signature of SIGN_IDENTITY.
dmg:
	SIGN_IDENTITY=- scripts/bundle.sh build/dmg-app/Dirigible.app
	scripts/dmg.sh

test-dmg: dmg
	scripts/test-dmg.sh

# Each hook and script test. scripts/test-hooks.sh runs them and reuses a pass with the same input
# key: read its header. It writes a pass stamp only for this whole list.
HOOK_TESTS = \
	.claude/hooks/git-guardrails.test.sh \
	scripts/probe.test.sh \
	scripts/hid.test.sh \
	scripts/ax.test.sh \
	scripts/screenshot.test.sh \
	scripts/screenshots.test.sh \
	scripts/verify-copy.test.sh \
	.claude/skills/deliver/scripts/mutate.test.sh \
	.claude/skills/deliver/scripts/run-files.test.sh \
	.claude/skills/reflect/scripts/seen.test.sh \
	scripts/bench-pairs.test.sh \
	scripts/icon.test.sh \
	scripts/bundle.test.sh \
	scripts/guide-html.test.sh \
	scripts/check-changed.test.sh \
	scripts/check-stamp.test.sh \
	scripts/evals-for.test.sh \
	scripts/test-filter.test.sh \
	scripts/run-checks.test.sh \
	scripts/check-plan.test.sh \
	scripts/check-waits.test.sh \
	.claude/skills/deliver/scripts/replay-list.test.sh \
	.claude/skills/deliver/scripts/replay-batch.test.sh \
	.claude/skills/reflect/scripts/cost.test.sh \
	scripts/check-governance.test.sh \
	scripts/pr-terms.test.sh \
	scripts/land.test.sh \
	.claude/workflows/review-panel.test.sh \
	scripts/flake-monitor/sample-threads.test.sh \
	scripts/flake-monitor/loop.test.sh \
	scripts/test-hooks.test.sh

test-hooks:
	scripts/test-hooks.sh $(HOOK_TESTS)

check-docs:
	scripts/check-docs.test.sh
	scripts/check-docs.sh

# Each target of the package treats warnings as errors, with no exception (Package.swift).
check-warnings:
	scripts/check-warnings.test.sh
	scripts/check-warnings.sh

# No Swift file under Sources/ or Tests/ is over 400 lines without an entry in
# scripts/check-sizes.allow (AGENTS.md, File size).
check-sizes:
	scripts/check-sizes.test.sh
	scripts/check-sizes.sh

# Stop only the app of this tree, by its executable path: the verify copy and the test fakes
# are also named Dirigible.
run: app
	pkill -f "^$(CURDIR)/build/Dirigible.app/Contents/MacOS/Dirigible" || true
	open build/Dirigible.app

lint:
	swift format lint --strict --recursive $(SWIFT_SOURCES)

format:
	swift format format --in-place --recursive $(SWIFT_SOURCES)

# The gates with no Swift test. scripts/run-checks.sh runs them first with make static, so a red
# gate stops check or check-fast before the Swift targets (decision 0028).
STATIC_GATES := lint check-docs check-slow-gates check-warnings check-sizes
static: $(STATIC_GATES)

check: $(STATIC_GATES) test test-hooks test-app

# The checks with no Swift test: for a change to scripts, hooks, or workflows.
check-fast: $(STATIC_GATES) test-hooks

# Runs the targets that scripts/check-changed.sh picks for the changed paths (decision 0028).
# With BASE, the targets before the push. With FILTER and no BASE, test-filter in place of test.
# It fails closed: a script error or a missing targets line exits nonzero. An empty make goal
# would run the default goal setup, so the recipe never calls $(MAKE) with no target.
# The first line names the commit, the tree state, the base commit, and the targets (cost.sh of
# reflect reads it). After a pass with BASE, scripts/check-stamp.sh appends the pass stamp that
# land.sh reuses, when the tree stayed clean. This recipe is the only writer of the stamp.
# Before Swift tests, it waits for a normal load (check-changed.sh --wait-load).
# scripts/run-checks.sh runs the targets with -k and reruns only the failed Swift tests of a red
# test or test-slow-push target, 1 time at most with risk: yes. A pass on a rerun writes the stamp.
# A PUSH_RUN=<names> word of the targets line goes to make as a variable of test-slow-push.
BASE ?=
FILTER ?=
check-changed:
	@head="$$(git rev-parse HEAD)" || exit 1; \
	tree=clean; if [ -n "$$(git status --porcelain)" ]; then tree=dirty; fi; \
	out="$$(FILTER='$(FILTER)' scripts/check-changed.sh $(BASE))" || exit 1; \
	targets="$$(printf '%s\n' "$$out" | sed -n 's/^targets: //p')"; \
	if [ -z "$$targets" ]; then echo "check-changed: no targets line" >&2; exit 1; fi; \
	base=none; if [ -n '$(BASE)' ]; then base="$$(git rev-parse --verify '$(BASE)^{commit}')" || exit 1; fi; \
	echo "check-changed: commit $$head tree $$tree base $$base targets $$targets"; \
	printf '%s\n' "$$out"; \
	if [ "$$targets" = none ]; then exit 0; fi; \
	scripts/check-changed.sh --wait-load $$targets || exit 1; \
	risk="$$(printf '%s\n' "$$out" | sed -n 's/^risk: //p')"; \
	MAKE='$(MAKE)' CHECK_RISK="$$risk" scripts/run-checks.sh $$targets FILTER='$(FILTER)' || exit 1; \
	if [ -n '$(BASE)' ]; then scripts/check-stamp.sh write "$$head" "$$tree" "$$base" $$targets; fi

clean:
	rm -rf .build build
