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
DERIVED_DATA_PATH := $(CURRENT_MAKEFILE_DIR)/.build/DerivedData
APP_SCHEME := supacode
PROJECT_CONFIG_PATH := Configurations/Project.xcconfig
TUIST_GENERATION_STAMP_DIR := $(CURRENT_MAKEFILE_DIR)/.build/.tuist-generated-stamps
TUIST_INSTALL_STAMP := $(TUIST_GENERATION_STAMP_DIR)/.installed
TUIST_DEVELOPMENT_GENERATION_STAMP := $(TUIST_GENERATION_STAMP_DIR)/development
TUIST_SOURCE_GENERATION_STAMP := $(TUIST_GENERATION_STAMP_DIR)/none
TUIST_RELEASE_GENERATION_STAMP := $(TUIST_GENERATION_STAMP_DIR)/development-release
# Test targets use explicit source globs expanded at generation time, so a new
# test file must trigger a regen or it would silently run in no bundle.
TUIST_GENERATION_INPUTS := Project.swift Workspace.swift Tuist.swift Tuist/Package.swift $(wildcard Tuist/Package.resolved) $(PROJECT_CONFIG_PATH) mise.toml scripts/build-ghostty.sh scripts/build-zmx.sh $(wildcard supacodeTests/*.swift)
TUIST_GENERATE_CACHE_PROFILE ?= development
TUIST_CACHE_CONFIGURATION ?= Debug
VERSION ?=
BUILD ?=
TITLE ?=
BODY ?=
# Export so headline markdown reaches the script without a shell re-parse of quotes/backticks.
export VERSION BUILD TITLE BODY
XCODEBUILD_FLAGS ?=
SUPACODE_SKIP_PREFLIGHT ?=
# Parallel test execution (Swift Testing in-process + one process per test bundle).
# Escape hatch: make test TEST_PARALLEL=NO.
TEST_PARALLEL ?= YES
# The explicit workspace scheme carries every test bundle; the auto-generated
# app scheme only tests supacodeTests.
TEST_SCHEME := supacode-tests
# xcodebuild's streamed log reduces a parallel-bundle failure to "Test case ... failed"; the assertion
# text only lives in the result bundle, which `make test` dumps on failure.
TEST_RESULT_BUNDLE := build/supacode-tests.xcresult

# Export a Zig-linkable Xcode per build recipe (no global xcode-select -s). Plain
# assignment so a missing Xcode aborts the recipe under -e.
SELECT_DEVELOPER_DIR = DEVELOPER_DIR="$$(./scripts/select-developer-dir.sh)"; export DEVELOPER_DIR

.DEFAULT_GOAL := help
.PHONY: doctor preflight build-ghostty-xcframework build-zmx generate-project generate-project-sources inspect-dependencies warm-cache build-app run-app install-dev-build archive export-archive format lint check test bump-version bump-and-release log-stream

ifdef CI
TUIST_INSTALL_FLAGS := --force-resolved-versions
SUPACODE_SKIP_PREFLIGHT := 1
else
TUIST_INSTALL_FLAGS :=
endif

help:  # Display this help.
	@-+echo "Run make with one of the following targets:"
	@-+echo
	@-+grep -Eh "^[a-z-]+:.*#" "$(CURRENT_MAKEFILE_PATH)" | sed -E 's/^(.*:)(.*#+)(.*)/  \1 @@@ \3 /' | column -t -s "@@@"

generate-project: $(TUIST_GENERATION_STAMP_DIR)/$(TUIST_GENERATE_CACHE_PROFILE) # Resolve packages and generate Xcode workspace

generate-project-sources: $(TUIST_SOURCE_GENERATION_STAMP) # Resolve packages and generate a source-only Xcode workspace

$(TUIST_INSTALL_STAMP): $(TUIST_GENERATION_INPUTS) | preflight
	mkdir -p "$(TUIST_GENERATION_STAMP_DIR)"
	mise exec -- tuist install $(TUIST_INSTALL_FLAGS)
	touch "$@"

$(TUIST_GENERATION_STAMP_DIR)/%: $(TUIST_GENERATION_INPUTS) $(TUIST_INSTALL_STAMP)
	mkdir -p "$(TUIST_GENERATION_STAMP_DIR)"
	find "$(TUIST_GENERATION_STAMP_DIR)" -mindepth 1 -maxdepth 1 ! -name '.installed' -delete
	rm -rf supacode.xcodeproj supacode.xcworkspace
	rm -rf "$(DERIVED_DATA_PATH)"
	mise exec -- tuist generate --no-open --cache-profile "$*"
	touch "$@"

# Consumes the warmed Release binary cache, so archive compiles only the app shell.
$(TUIST_RELEASE_GENERATION_STAMP): $(TUIST_GENERATION_INPUTS) $(TUIST_INSTALL_STAMP)
	mkdir -p "$(TUIST_GENERATION_STAMP_DIR)"
	find "$(TUIST_GENERATION_STAMP_DIR)" -mindepth 1 -maxdepth 1 ! -name '.installed' -delete
	rm -rf supacode.xcodeproj supacode.xcworkspace
	rm -rf "$(DERIVED_DATA_PATH)"
	mise exec -- tuist generate --no-open --cache-profile development --configuration Release
	touch "$@"

doctor: # Diagnose build prerequisites and print the fix for each failure
	@./scripts/doctor.sh

# Order-only preflight on the install stamp, so every build flow fails fast with
# doctor's actionable message before tuist / xcodebuild / zig run. Never forces a
# rebuild. Skipped when SUPACODE_SKIP_PREFLIGHT is set (CI sets it above).
preflight:
	@[ -n "$(SUPACODE_SKIP_PREFLIGHT)" ] || ./scripts/doctor.sh --quiet

build-ghostty-xcframework: | preflight # Build ghostty framework
	./scripts/build-ghostty.sh

build-zmx: | preflight # Build bundled zmx binary from ThirdParty/zmx submodule
	./scripts/build-zmx.sh

inspect-dependencies: $(TUIST_INSTALL_STAMP) # Check for implicit Tuist dependencies
	mise exec -- tuist inspect dependencies --only implicit

warm-cache: $(TUIST_INSTALL_STAMP) # Warm the full Tuist cacheable graph
	mise exec -- tuist cache warm --configuration $(TUIST_CACHE_CONFIGURATION)

build-app: $(TUIST_DEVELOPMENT_GENERATION_STAMP) # Build the macOS app (Debug)
	$(SELECT_DEVELOPER_DIR); \
	bash -o pipefail -c 'xcodebuild -workspace "$(PROJECT_WORKSPACE)" -scheme "$(APP_SCHEME)" -configuration Debug -derivedDataPath "$(DERIVED_DATA_PATH)" build -skipMacroValidation $(XCODEBUILD_FLAGS) 2>&1 | { mise exec -- xcbeautify --disable-logging || cat; }'

run-app: build-app # Build then launch (Debug) with log streaming
	@$(SELECT_DEVELOPER_DIR); \
	settings="$$(xcodebuild -workspace "$(PROJECT_WORKSPACE)" -scheme "$(APP_SCHEME)" -configuration Debug -derivedDataPath "$(DERIVED_DATA_PATH)" -showBuildSettings -json 2>/dev/null)"; \
	build_dir="$$(echo "$$settings" | jq -r '.[0].buildSettings.BUILT_PRODUCTS_DIR')"; \
	product="$$(echo "$$settings" | jq -r '.[0].buildSettings.FULL_PRODUCT_NAME')"; \
	exec_name="$$(echo "$$settings" | jq -r '.[0].buildSettings.EXECUTABLE_NAME')"; \
	"$$build_dir/$$product/Contents/MacOS/$$exec_name"

install-dev-build: build-app # install dev build to /Applications
	@$(SELECT_DEVELOPER_DIR); \
	settings="$$(xcodebuild -workspace "$(PROJECT_WORKSPACE)" -scheme "$(APP_SCHEME)" -configuration Debug -derivedDataPath "$(DERIVED_DATA_PATH)" -showBuildSettings -json 2>/dev/null)"; \
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

archive: $(TUIST_RELEASE_GENERATION_STAMP) # Archive Release build for distribution
	mkdir -p build
	$(SELECT_DEVELOPER_DIR); \
	bash -o pipefail -c 'xcodebuild -workspace "$(PROJECT_WORKSPACE)" -scheme "$(APP_SCHEME)" -configuration Release -destination "generic/platform=macOS" -derivedDataPath "$(DERIVED_DATA_PATH)" -archivePath build/supacode.xcarchive archive CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="$$APPLE_TEAM_ID" CODE_SIGN_IDENTITY="$$DEVELOPER_ID_IDENTITY_SHA" OTHER_CODE_SIGN_FLAGS="--timestamp" -skipMacroValidation $(XCODEBUILD_FLAGS) 2>&1 | { mise exec -- xcbeautify --quiet --disable-logging || cat; }'

export-archive: # Export xarchive
	$(SELECT_DEVELOPER_DIR); \
	bash -o pipefail -c 'xcodebuild -exportArchive -archivePath build/supacode.xcarchive -exportPath build/export -exportOptionsPlist build/ExportOptions.plist 2>&1 | { mise exec -- xcbeautify --quiet --disable-logging || cat; }'

test: $(TUIST_DEVELOPMENT_GENERATION_STAMP) # Run all tests
	@$(SELECT_DEVELOPER_DIR); \
	rm -rf "$(TEST_RESULT_BUNDLE)"; \
	status=0; \
	if [ -t 1 ]; then \
		bash -o pipefail -c 'xcodebuild test -workspace "$(PROJECT_WORKSPACE)" -scheme "$(TEST_SCHEME)" -destination "platform=macOS" -derivedDataPath "$(DERIVED_DATA_PATH)" -resultBundlePath "$(TEST_RESULT_BUNDLE)" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" -skipMacroValidation -parallel-testing-enabled $(TEST_PARALLEL) 2>&1 | { mise exec -- xcbeautify --disable-logging || cat; }' || status=$$?; \
	else \
		xcodebuild test -workspace "$(PROJECT_WORKSPACE)" -scheme "$(TEST_SCHEME)" -destination "platform=macOS" -derivedDataPath "$(DERIVED_DATA_PATH)" -resultBundlePath "$(TEST_RESULT_BUNDLE)" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" -skipMacroValidation -parallel-testing-enabled $(TEST_PARALLEL) || status=$$?; \
	fi; \
	[ $$status -eq 0 ] || ./scripts/print-test-failures.sh "$(TEST_RESULT_BUNDLE)" || true; \
	exit $$status

format: # Format code with swift-format (mise-pinned for reproducibility).
	mise exec -- swift-format --parallel --in-place --recursive --configuration ./.swift-format.json supacode supacode-cli supacodeTests SupacodeSettingsShared SupacodeSettingsFeature

lint: # Lint code with swiftlint
	mise exec -- swiftlint lint --quiet --config .swiftlint.yml

check: format lint # Format and lint

log-stream: # Stream logs from the app via log stream
	log stream --predicate 'subsystem == "app.supabit.supacode"' --style compact --color always

bump-version: # Bump app version (usage: make bump-version VERSION=x.y.z [BUILD=123] [TITLE=… BODY=…])
	@./scripts/bump-version.sh

# main.yml detects the tag at HEAD and cuts the release, prepending its headline.
bump-and-release: bump-version # Bump version and push tags to trigger the release (usage: make bump-and-release VERSION=x.y.z [TITLE=… BODY=…])
	git push --follow-tags
