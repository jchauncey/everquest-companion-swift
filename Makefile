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

# Release coordinates. VERSION is the file the app and the bundle both read, so the tag, the zip
# and what the About box says can never disagree. REMOTE is this repo's git remote (named
# `upstream` here, not `origin`).
VERSION := $(shell cat VERSION 2>/dev/null)
TAG := v$(VERSION)
ZIP := dist/EQCompanion-$(VERSION).zip

# The release-notes tool (scripts/relnotes): reads the app's own committed notes, renders one
# release as Markdown, and drafts a first pass from the commit log. Built into .build/ rather than
# `go run` so a refusal reads as its own message and not as "exit status 1" after it.
RELNOTES := .build/relnotes
REMOTE ?= upstream

.DEFAULT_GOAL := help

# ---- build ----------------------------------------------------------------

.PHONY: build
build: ## Debug build of every target
	$(SWIFT) build

.PHONY: build-release
build-release: ## Release build of every target (see `release` for publishing one)
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

.PHONY: install
install: app ## Build, then copy the app into /Applications
	rm -rf "/Applications/EQCompanion.app"
	cp -R dist/EQCompanion.app "/Applications/EQCompanion.app"
	@echo "installed: /Applications/EQCompanion.app"

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

.PHONY: exaltations
exaltations: ## Re-scrape Sources/EQData/data/exaltations.json from the wiki
	python3 scripts/gen-exaltations.py

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

# ---- release --------------------------------------------------------------
#
# The whole flow, once the release's notes are written into
# `Sources/EQCompanion/Prefs/ReleaseNotes.swift` (a human job — the voice rules are in that file):
#
#     make tag V=0.3.0                        bump VERSION, commit it, annotated tag v0.3.0
#     git push $(REMOTE) main --follow-tags   the tag has to be on GitHub before the release
#     make release                            build, zip, publish, attach
#
# The release body comes from those same committed notes, so what the app shows under
# Preferences → What's new and what GitHub shows cannot drift apart.
#
# GATEKEEPER, honestly: the bundle is ad-hoc signed, not notarized, so a DOWNLOADED copy is
# quarantined and macOS calls it damaged. `scripts/release-install-note.md` — appended to every
# release body — says how to clear it. Developer ID signing plus notarization is the real fix and
# is not done here; see docs/plan.md.

$(RELNOTES): $(wildcard scripts/relnotes/*.go) scripts/relnotes/go.mod
	@mkdir -p .build
	@go build -C scripts/relnotes -o "$(CURDIR)/$(RELNOTES)" .

.PHONY: version
version: ## Print the version that would be released
	@echo "$(VERSION)  (tag $(TAG))"

.PHONY: notes
notes: $(RELNOTES) ## Print the release notes for the current VERSION
	@$(RELNOTES) render "$(VERSION)"

# A DRAFT, and only a draft. `tag` below never calls this: the notes ship inside the build, so they
# cannot depend on a CLI or a network — and the commit log knows what changed while only a person
# knows which of it a player would care about. Draft, then read and edit, then tag.
.PHONY: draft-notes
draft-notes: $(RELNOTES) ## Draft notes for V=0.3.0 from the commits since the last release, with claude -p
	@test -n "$(V)" || { echo "usage: make draft-notes V=0.3.0  [REDRAFT=1] [NOTE='shorter']"; exit 1; }
	@$(RELNOTES) draft "$(V)" $(if $(REDRAFT),--redraft) $(if $(NOTE),--note "$(NOTE)")

.PHONY: tag
tag: $(RELNOTES) ## Set the version, commit it, and tag it: make tag V=0.3.0
	@test -n "$(V)" || { echo "usage: make tag V=0.3.0"; exit 1; }
	@echo "$(V)" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$$' || { echo "version must look like 1.2.3"; exit 1; }
	@test -z "$$(git status --porcelain)" || { echo "working tree is dirty — commit or stash first"; exit 1; }
	@if git rev-parse -q --verify "refs/tags/v$(V)" >/dev/null; then echo "tag v$(V) already exists"; exit 1; fi
	@$(RELNOTES) render "$(V)" >/dev/null
	@echo "$(V)" > VERSION
	@git add VERSION
	@git commit -q -m "Release $(V)"
	@$(RELNOTES) render "$(V)" | git tag -a "v$(V)" -F -
	@echo "tagged v$(V)."
	@echo "next:  git push $(REMOTE) main --follow-tags  &&  make release"

.PHONY: dist-zip
dist-zip: app ## Build the app and zip it for upload (ditto keeps the signature intact)
	@rm -f "$(ZIP)"
	@ditto -c -k --sequesterRsrc --keepParent dist/EQCompanion.app "$(ZIP)"
	@echo "$(ZIP) ($$(du -h "$(ZIP)" | cut -f1 | tr -d ' '))"

.PHONY: release
release: $(RELNOTES) ## Publish VERSION as a GitHub release with the app attached
	@command -v gh >/dev/null || { echo "gh CLI not installed: brew install gh"; exit 1; }
	@test -n "$(VERSION)" || { echo "VERSION file is empty"; exit 1; }
	@git rev-parse -q --verify "refs/tags/$(TAG)" >/dev/null || { echo "no tag $(TAG) — run: make tag V=$(VERSION)"; exit 1; }
	@git ls-remote --tags $(REMOTE) "refs/tags/$(TAG)" | grep -q . \
		|| { echo "tag $(TAG) is not on $(REMOTE) — run: git push $(REMOTE) main --follow-tags"; exit 1; }
	@if gh release view "$(TAG)" >/dev/null 2>&1; then echo "release $(TAG) already exists"; exit 1; fi
	$(MAKE) dist-zip
	@{ $(RELNOTES) render "$(VERSION)"; cat scripts/release-install-note.md; } > dist/release-body.md
	@gh release create "$(TAG)" "$(ZIP)" --title "EQ Companion $(VERSION)" --notes-file dist/release-body.md \
		|| { echo; echo "if that was 403: an env GITHUB_TOKEN outranks your gh login, and a fine-grained"; \
		     echo "PAT scoped to another org cannot write here (a read still works, so nothing warns you)."; \
		     echo "retry with:  env -u GITHUB_TOKEN make release"; exit 1; }
	@echo "published: $$(gh release view "$(TAG)" --json url -q .url)"

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
