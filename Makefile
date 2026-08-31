# EQ Companion — the commands in CLAUDE.md, in one place.
#
# `make help` lists everything. The targets are thin wrappers around swift/scripts rather than a
# second build system: what CI runs and what you run are the same lines.
#
# ONE BUILD AT A TIME. SwiftPM takes a lock on `.build`, so a second `swift build` in another
# terminal blocks rather than failing — if a target seems hung, that is usually why.

SWIFT ?= swift
# The upstream Rust checkout the goldens are cut from.
UPSTREAM ?= ../everquest-companion

.DEFAULT_GOAL := help

# ---- build ----------------------------------------------------------------

.PHONY: build
build: ## Debug build of every target
	$(SWIFT) build

.PHONY: release
release: ## Release build of every target
	$(SWIFT) build -c release

.PHONY: run
run: ## Run the app (the root package's only executable)
	$(SWIFT) run

.PHONY: app
app: ## Package dist/EQCompanion.app (release, ad-hoc signed)
	scripts/build-app.sh

.PHONY: app-debug
app-debug: ## Package dist/EQCompanion.app from a debug build
	scripts/build-app.sh --debug

.PHONY: tools
tools: ## Build the developer tools in Tools/ (eqtool, eqbench)
	$(SWIFT) build --package-path Tools

# ---- test -----------------------------------------------------------------
#
# The golden suites XCTSkip when Goldens/ is absent and the map/log suites skip without the owner's
# EverQuest install, so `make test` is green on a bare checkout — see `verify` for the real bar.

.PHONY: test
test: ## Run the whole suite (~5 min with goldens present)
	$(SWIFT) test

.PHONY: test-app
test-app: ## Run only the SwiftUI app tests (fast; no goldens needed)
	$(SWIFT) test --filter EQCompanionTests

.PHONY: test-engine
test-engine: ## Run only the engine suites (the golden oracles)
	$(SWIFT) test --filter 'EQLogTests|EQFoldTests|EQEngineTests|EQKnowledgeTests'

# make test-one FILTER=EQFoldTests.GoldenSnapshotsTests
.PHONY: test-one
test-one: ## Run one test/class/suite: make test-one FILTER=<pattern>
	@test -n "$(FILTER)" || (echo "usage: make test-one FILTER=EQFoldTests.GoldenSnapshotsTests" && exit 1)
	$(SWIFT) test --filter '$(FILTER)'

.PHONY: verify
verify: ## What CI runs: build, then the full suite
	$(MAKE) build
	$(MAKE) test

# ---- goldens --------------------------------------------------------------

.PHONY: goldens
goldens: ## Re-cut Goldens/ from the upstream RUST engine (needs cargo + $UPSTREAM)
	scripts/gen-goldens.sh $(UPSTREAM)

.PHONY: goldens-status
goldens-status: ## Whether Goldens/ is present — the golden suites skip silently without it
	@if [ -d Goldens ]; then \
		echo "Goldens/ present: $$(find Goldens -name '*.ndjson' -o -name '*.json' | wc -l | tr -d ' ') files, $$(du -sh Goldens | cut -f1)"; \
	else \
		echo "Goldens/ ABSENT — the golden suites will XCTSkip, so a green run proves little."; \
		echo "  make goldens   (needs the upstream Rust checkout at $(UPSTREAM))"; \
	fi

# ---- developer tools ------------------------------------------------------
#
# Pass arguments through ARGS, e.g. make events ARGS="--all --kinds loot"

.PHONY: events
events: ## eqtool events — bytes to canonical NDJSON: make events ARGS="<fixture>|--all"
	$(SWIFT) run --package-path Tools eqtool events $(ARGS)

.PHONY: snapshots
snapshots: ## eqtool snapshots — the fold's module states
	$(SWIFT) run --package-path Tools eqtool snapshots $(ARGS)

.PHONY: combat
combat: ## eqtool combat — the combat engine's own snapshot
	$(SWIFT) run --package-path Tools eqtool combat $(ARGS)

.PHONY: views
views: ## eqtool views — the view registry's cuts
	$(SWIFT) run --package-path Tools eqtool views $(ARGS)

.PHONY: bench
bench: ## eqbench — parser timing and byte diff: make bench ARGS="<log>"
	$(SWIFT) run --package-path Tools eqbench $(ARGS)

# ---- housekeeping ---------------------------------------------------------

.PHONY: clean
clean: ## Remove build products (leaves Goldens/ alone — it costs 20 minutes to re-cut)
	rm -rf .build Tools/.build dist

.PHONY: log
log: ## Tail the client log, where the app writes its diagnostics
	tail -f "$$HOME/Library/Application Support/EQCompanion/client.log"

.PHONY: help
help: ## List these targets
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'
