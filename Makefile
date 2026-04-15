# Sensible defaults
.ONESHELL:
SHELL := bash
.SHELLFLAGS := -e -u -c -o pipefail
.DELETE_ON_ERROR:
MAKEFLAGS += --warn-undefined-variables
MAKEFLAGS += --no-builtin-rules

# Derived values (DO NOT TOUCH).
CURRENT_MAKEFILE_PATH := $(abspath $(lastword $(MAKEFILE_LIST)))
CURRENT_MAKEFILE_DIR := $(patsubst %/,%,$(dir $(CURRENT_MAKEFILE_PATH)))
PROJECT_WORKSPACE := $(CURRENT_MAKEFILE_DIR)/supacode.xcworkspace
APP_SCHEME := supacode
PROJECT_CONFIG_PATH := Configurations/Project.xcconfig
TUIST_GENERATION_STAMP_DIR := $(CURRENT_MAKEFILE_DIR)/.build/.tuist-generated-stamps
TUIST_INSTALL_STAMP := $(TUIST_GENERATION_STAMP_DIR)/.installed
TUIST_DEVELOPMENT_GENERATION_STAMP := $(TUIST_GENERATION_STAMP_DIR)/development
TUIST_SOURCE_GENERATION_STAMP := $(TUIST_GENERATION_STAMP_DIR)/none
TUIST_SOURCE_RELEASE_GENERATION_STAMP := $(TUIST_GENERATION_STAMP_DIR)/none-release
TUIST_GENERATION_INPUTS := Project.swift Workspace.swift Tuist.swift Tuist/Package.swift $(wildcard Tuist/Package.resolved) $(PROJECT_CONFIG_PATH) mise.toml scripts/build-ghostty.sh
TUIST_GENERATE_CACHE_PROFILE ?= development
TUIST_CACHE_CONFIGURATION ?= Debug
VERSION ?=
BUILD ?=
XCODEBUILD_FLAGS ?=

.DEFAULT_GOAL := help
.PHONY: build-ghostty-xcframework generate-project generate-project-sources inspect-dependencies warm-cache build-app run-app install-dev-build archive export-archive format lint check test bump-version bump-and-release log-stream

ifdef CI
TUIST_INSTALL_FLAGS := --force-resolved-versions
else
TUIST_INSTALL_FLAGS :=
endif

help:  # Display this help.
	@-+echo "Run make with one of the following targets:"
	@-+echo
	@-+grep -Eh "^[a-z-]+:.*#" "$(CURRENT_MAKEFILE_PATH)" | sed -E 's/^(.*:)(.*#+)(.*)/  \1 @@@ \3 /' | column -t -s "@@@"

generate-project: $(TUIST_GENERATION_STAMP_DIR)/$(TUIST_GENERATE_CACHE_PROFILE) # Resolve packages and generate Xcode workspace

generate-project-sources: $(TUIST_SOURCE_GENERATION_STAMP) # Resolve packages and generate a source-only Xcode workspace

$(TUIST_INSTALL_STAMP): $(TUIST_GENERATION_INPUTS)
	mkdir -p "$(TUIST_GENERATION_STAMP_DIR)"
	mise exec -- tuist install $(TUIST_INSTALL_FLAGS)
	touch "$@"

$(TUIST_GENERATION_STAMP_DIR)/%: $(TUIST_GENERATION_INPUTS) $(TUIST_INSTALL_STAMP)
	mkdir -p "$(TUIST_GENERATION_STAMP_DIR)"
	find "$(TUIST_GENERATION_STAMP_DIR)" -mindepth 1 -maxdepth 1 ! -name '.installed' -delete
	rm -rf supacode.xcodeproj supacode.xcworkspace
	for path in "$${HOME}/Library/Developer/Xcode/DerivedData"/supacode-*; do \
		[ -e "$$path" ] || continue; \
		rm -rf "$$path"; \
	done
	mise exec -- tuist generate --no-open --cache-profile "$*"
	touch "$@"

$(TUIST_SOURCE_RELEASE_GENERATION_STAMP): $(TUIST_GENERATION_INPUTS) $(TUIST_INSTALL_STAMP)
	mkdir -p "$(TUIST_GENERATION_STAMP_DIR)"
	find "$(TUIST_GENERATION_STAMP_DIR)" -mindepth 1 -maxdepth 1 ! -name '.installed' -delete
	rm -rf supacode.xcodeproj supacode.xcworkspace
	for path in "$${HOME}/Library/Developer/Xcode/DerivedData"/supacode-*; do \
		[ -e "$$path" ] || continue; \
		rm -rf "$$path"; \
	done
	mise exec -- tuist generate --no-open --cache-profile none --configuration Release
	touch "$@"

build-ghostty-xcframework: # Build ghostty framework
	./scripts/build-ghostty.sh

inspect-dependencies: $(TUIST_INSTALL_STAMP) # Check for implicit Tuist dependencies
	mise exec -- tuist inspect dependencies --only implicit

warm-cache: $(TUIST_INSTALL_STAMP) # Warm the full Tuist cacheable graph
	mise exec -- tuist cache warm --configuration $(TUIST_CACHE_CONFIGURATION)

build-app: $(TUIST_DEVELOPMENT_GENERATION_STAMP) # Build the macOS app (Debug)
	bash -o pipefail -c 'xcodebuild -workspace "$(PROJECT_WORKSPACE)" -scheme "$(APP_SCHEME)" -configuration Debug build -skipMacroValidation 2>&1 | mise exec -- xcbeautify --disable-logging'

run-app: build-app # Build then launch (Debug) with log streaming
	@settings="$$(xcodebuild -workspace "$(PROJECT_WORKSPACE)" -scheme "$(APP_SCHEME)" -configuration Debug -showBuildSettings -json 2>/dev/null)"; \
	build_dir="$$(echo "$$settings" | jq -r '.[0].buildSettings.BUILT_PRODUCTS_DIR')"; \
	product="$$(echo "$$settings" | jq -r '.[0].buildSettings.FULL_PRODUCT_NAME')"; \
	exec_name="$$(echo "$$settings" | jq -r '.[0].buildSettings.EXECUTABLE_NAME')"; \
	"$$build_dir/$$product/Contents/MacOS/$$exec_name"

install-dev-build: build-app # install dev build to /Applications
	@settings="$$(xcodebuild -workspace "$(PROJECT_WORKSPACE)" -scheme "$(APP_SCHEME)" -configuration Debug -showBuildSettings -json 2>/dev/null)"; \
	build_dir="$$(echo "$$settings" | jq -r '.[0].buildSettings.BUILT_PRODUCTS_DIR')"; \
	product="$$(echo "$$settings" | jq -r '.[0].buildSettings.FULL_PRODUCT_NAME')"; \
	src="$$build_dir/$$product"; \
	dst="/Applications/$$product"; \
	if [ ! -d "$$src" ]; then \
		echo "app not found: $$src"; \
		exit 1; \
	fi; \
	echo "copying $$src -> $$dst"; \
	rm -rf "$$dst"; \
	ditto "$$src" "$$dst"; \
	echo "installed $$dst"

archive: $(TUIST_SOURCE_RELEASE_GENERATION_STAMP) # Archive Release build for distribution
	mkdir -p build
	bash -o pipefail -c 'xcodebuild -workspace "$(PROJECT_WORKSPACE)" -scheme "$(APP_SCHEME)" -configuration Release -destination "generic/platform=macOS" -archivePath build/supacode.xcarchive archive CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="$$APPLE_TEAM_ID" CODE_SIGN_IDENTITY="$$DEVELOPER_ID_IDENTITY_SHA" OTHER_CODE_SIGN_FLAGS="--timestamp" -skipMacroValidation $(XCODEBUILD_FLAGS) 2>&1 | mise exec -- xcbeautify --quiet --disable-logging'

export-archive: # Export xarchive
	bash -o pipefail -c 'xcodebuild -exportArchive -archivePath build/supacode.xcarchive -exportPath build/export -exportOptionsPlist build/ExportOptions.plist 2>&1 | mise exec -- xcbeautify --quiet --disable-logging'

test: $(TUIST_DEVELOPMENT_GENERATION_STAMP) # Run all tests
	@if [ -t 1 ]; then \
		bash -o pipefail -c 'xcodebuild test -workspace "$(PROJECT_WORKSPACE)" -scheme "$(APP_SCHEME)" -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" -skipMacroValidation -parallel-testing-enabled NO 2>&1 | mise exec -- xcbeautify --disable-logging'; \
	else \
		xcodebuild test -workspace "$(PROJECT_WORKSPACE)" -scheme "$(APP_SCHEME)" -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" -skipMacroValidation -parallel-testing-enabled NO; \
	fi

format: # Format code with swift format (local only).
	swift format -p --in-place --recursive --configuration ./.swift-format.json supacode supacode-cli supacodeTests SupacodeSettingsShared SupacodeSettingsFeature

lint: # Lint code with swiftlint
	mise exec -- swiftlint lint --quiet --config .swiftlint.yml

check: format lint # Format and lint

log-stream: # Stream logs from the app via log stream
	log stream --predicate 'subsystem == "app.supabit.supacode"' --style compact --color always

bump-version: # Bump app version (usage: make bump-version [VERSION=x.x.x] [BUILD=123])
	@if [ -z "$(VERSION)" ]; then \
		current="$$(/usr/bin/awk -F' = ' '/^MARKETING_VERSION = [0-9.]+$$/{print $$2; exit}' "$(PROJECT_CONFIG_PATH)")"; \
		if [ -z "$$current" ]; then \
			echo "error: MARKETING_VERSION not found"; \
			exit 1; \
		fi; \
		major="$$(echo "$$current" | cut -d. -f1)"; \
		minor="$$(echo "$$current" | cut -d. -f2)"; \
		patch="$$(echo "$$current" | cut -d. -f3)"; \
		version="$$major.$$minor.$$((patch + 1))"; \
	else \
		if ! echo "$(VERSION)" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$$'; then \
			echo "error: VERSION must be in x.x.x format"; \
			exit 1; \
		fi; \
		version="$(VERSION)"; \
	fi; \
	if [ -z "$(BUILD)" ]; then \
		build="$$(/usr/bin/awk -F' = ' '/^CURRENT_PROJECT_VERSION = [0-9]+$$/{print $$2; exit}' "$(PROJECT_CONFIG_PATH)")"; \
		if [ -z "$$build" ]; then \
			echo "error: CURRENT_PROJECT_VERSION not found"; \
			exit 1; \
		fi; \
		build="$$((build + 1))"; \
	else \
		if ! echo "$(BUILD)" | grep -qE '^[0-9]+$$'; then \
			echo "error: BUILD must be an integer"; \
			exit 1; \
		fi; \
		build="$(BUILD)"; \
	fi; \
	sed -i '' "s/^MARKETING_VERSION = [0-9.]*/MARKETING_VERSION = $$version/g" \
		"$(PROJECT_CONFIG_PATH)"; \
	sed -i '' "s/^CURRENT_PROJECT_VERSION = [0-9]*/CURRENT_PROJECT_VERSION = $$build/g" \
		"$(PROJECT_CONFIG_PATH)"; \
	git add "$(PROJECT_CONFIG_PATH)"; \
	git commit -S -m "bump v$$version"; \
	git tag -s "v$$version" -m "v$$version"; \
	echo "version bumped to $$version (build $$build), tagged v$$version"

bump-and-release: bump-version # Bump version and push tags to trigger release
	git push --follow-tags
	@tag="$$(git describe --tags --abbrev=0)"; \
	repo="$$(gh repo view --json nameWithOwner -q .nameWithOwner)"; \
	prev="$$(gh release view --json tagName -q .tagName 2>/dev/null || echo '')"; \
	tmp="$$(mktemp)"; \
	if [ -n "$$prev" ]; then \
		gh api "repos/$$repo/releases/generate-notes" -f tag_name="$$tag" -f previous_tag_name="$$prev" --jq '.body' > "$$tmp"; \
	else \
		gh api "repos/$$repo/releases/generate-notes" -f tag_name="$$tag" --jq '.body' > "$$tmp"; \
	fi; \
	$${EDITOR:-vim} "$$tmp"; \
	gh release create "$$tag" --notes-file "$$tmp"; \
	rm -f "$$tmp"
