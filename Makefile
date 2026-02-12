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
GHOSTTY_XCFRAMEWORK_PATH := $(CURRENT_MAKEFILE_DIR)/Frameworks/GhosttyKit.xcframework
GHOSTTY_RESOURCE_PATH := $(CURRENT_MAKEFILE_DIR)/Resources/ghostty
GHOSTTY_TERMINFO_PATH := $(CURRENT_MAKEFILE_DIR)/Resources/terminfo
GHOSTTY_BUILD_OUTPUTS := $(GHOSTTY_XCFRAMEWORK_PATH) $(GHOSTTY_RESOURCE_PATH) $(GHOSTTY_TERMINFO_PATH)
SPM_CACHE_DIR := /tmp/supacode-spm-cache/SourcePackages
VERSION ?=
BUILD ?=
XCODEBUILD_FLAGS ?=
.DEFAULT_GOAL := help
.PHONY: build-ghostty-xcframework build-app run-app install-dev-build archive export-archive format lint check test update-wt bump-version bump-and-release

help:  # Display this help.
	@-+echo "Run make with one of the following targets:"
	@-+echo
	@-+grep -Eh "^[a-z-]+:.*#" $(CURRENT_MAKEFILE_PATH) | sed -E 's/^(.*:)(.*#+)(.*)/  \1 @@@ \3 /' | column -t -s "@@@"

build-ghostty-xcframework: $(GHOSTTY_BUILD_OUTPUTS) # Build ghostty framework

$(GHOSTTY_BUILD_OUTPUTS):
	@cd $(CURRENT_MAKEFILE_DIR)/ThirdParty/ghostty && mise exec -- zig build -Doptimize=ReleaseFast -Demit-xcframework=true -Dsentry=false
	rsync -a ThirdParty/ghostty/macos/GhosttyKit.xcframework Frameworks
	@src="$(CURRENT_MAKEFILE_DIR)/ThirdParty/ghostty/zig-out/share/ghostty"; \
	dst="$(GHOSTTY_RESOURCE_PATH)"; \
	terminfo_src="$(CURRENT_MAKEFILE_DIR)/ThirdParty/ghostty/zig-out/share/terminfo"; \
	terminfo_dst="$(GHOSTTY_TERMINFO_PATH)"; \
	mkdir -p "$$dst"; \
	rsync -a --delete "$$src/" "$$dst/"; \
	mkdir -p "$$terminfo_dst"; \
	rsync -a --delete "$$terminfo_src/" "$$terminfo_dst/"

build-app: build-ghostty-xcframework # Build the macOS app (Debug)
	bash -o pipefail -c 'xcodebuild -project supacode.xcodeproj -scheme supacode -configuration Debug build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" -skipMacroValidation -clonedSourcePackagesDirPath $(SPM_CACHE_DIR) 2>&1 | mise exec -- xcsift -qw --format toon'

run-app: build-app # Build then launch (Debug) with log streaming
	@settings="$$(xcodebuild -project supacode.xcodeproj -scheme supacode -configuration Debug -showBuildSettings -json 2>/dev/null)"; \
	build_dir="$$(echo "$$settings" | jq -r '.[0].buildSettings.BUILT_PRODUCTS_DIR')"; \
	product="$$(echo "$$settings" | jq -r '.[0].buildSettings.FULL_PRODUCT_NAME')"; \
	exec_name="$$(echo "$$settings" | jq -r '.[0].buildSettings.EXECUTABLE_NAME')"; \
	"$$build_dir/$$product/Contents/MacOS/$$exec_name"

install-dev-build: build-app # install dev build to /Applications
	@settings="$$(xcodebuild -project supacode.xcodeproj -scheme supacode -configuration Debug -showBuildSettings -json 2>/dev/null)"; \
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

archive: build-ghostty-xcframework # Archive Release build for distribution
	bash -o pipefail -c 'xcodebuild -project supacode.xcodeproj -scheme supacode -configuration Release -archivePath build/supacode.xcarchive archive CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="$$APPLE_TEAM_ID" CODE_SIGN_IDENTITY="$$DEVELOPER_ID_IDENTITY_SHA" OTHER_CODE_SIGN_FLAGS="--timestamp" -skipMacroValidation -clonedSourcePackagesDirPath $(SPM_CACHE_DIR) $(XCODEBUILD_FLAGS) 2>&1 | mise exec -- xcsift -qw --format toon'

export-archive: # Export xarchive
	bash -o pipefail -c 'xcodebuild -exportArchive -archivePath build/supacode.xcarchive -exportPath build/export -exportOptionsPlist build/ExportOptions.plist 2>&1 | mise exec -- xcsift -qw --format toon'

test: build-ghostty-xcframework
	xcodebuild test -project supacode.xcodeproj -scheme supacode -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" -skipMacroValidation -clonedSourcePackagesDirPath $(SPM_CACHE_DIR) 2>&1

format: # Format code with swift-format (local only)
	swift-format -p --in-place --recursive --configuration ./.swift-format.json supacode supacodeTests

lint: # Lint code with swiftlint
	mise exec -- swiftlint --fix --quiet
	mise exec -- swiftlint lint --quiet --config .swiftlint.yml

check: format lint # Format and lint

update-wt: # Download git-wt binary to Resources
	@mkdir -p "$(CURRENT_MAKEFILE_DIR)/Resources/git-wt"
	@curl -fsSL "https://raw.githubusercontent.com/khoi/git-wt/refs/heads/main/wt" -o "$(CURRENT_MAKEFILE_DIR)/Resources/git-wt/wt"
	@chmod +x "$(CURRENT_MAKEFILE_DIR)/Resources/git-wt/wt"
	@git add "$(CURRENT_MAKEFILE_DIR)/Resources/git-wt/wt"
	@git commit -m "update git-wt"

bump-version: # Bump app version (usage: make bump-version [VERSION=x.x.x] [BUILD=123])
	@if [ -z "$(VERSION)" ]; then \
		current="$$(/usr/bin/awk -F' = ' '/MARKETING_VERSION = [0-9.]+;/{gsub(/;/,"",$$2);print $$2; exit}' "$(CURRENT_MAKEFILE_DIR)/supacode.xcodeproj/project.pbxproj")"; \
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
		build="$$(/usr/bin/awk -F' = ' '/CURRENT_PROJECT_VERSION = [0-9]+;/{gsub(/;/,"",$$2);print $$2; exit}' "$(CURRENT_MAKEFILE_DIR)/supacode.xcodeproj/project.pbxproj")"; \
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
	sed -i '' "s/MARKETING_VERSION = [0-9.]*;/MARKETING_VERSION = $$version;/g" \
		"$(CURRENT_MAKEFILE_DIR)/supacode.xcodeproj/project.pbxproj"; \
	sed -i '' "s/CURRENT_PROJECT_VERSION = [0-9]*;/CURRENT_PROJECT_VERSION = $$build;/g" \
		"$(CURRENT_MAKEFILE_DIR)/supacode.xcodeproj/project.pbxproj"; \
	git add "$(CURRENT_MAKEFILE_DIR)/supacode.xcodeproj/project.pbxproj"; \
	git commit -m "bump v$$version"; \
	git tag -s "v$$version" -m "v$$version"; \
	echo "version bumped to $$version (build $$build), tagged v$$version"

bump-and-release: bump-version # Bump version and push tags to trigger release
	git push --follow-tags
	@tag="$$(git describe --tags --abbrev=0)"; \
	repo="$$(gh repo view --json nameWithOwner -q .nameWithOwner)"; \
	prev="$$(gh release view --json tagName -q .tagName 2>/dev/null || echo '')"; \
	tmp=$$(mktemp); \
	if [ -n "$$prev" ]; then \
		gh api "repos/$$repo/releases/generate-notes" -f tag_name="$$tag" -f previous_tag_name="$$prev" --jq '.body' > "$$tmp"; \
	else \
		gh api "repos/$$repo/releases/generate-notes" -f tag_name="$$tag" --jq '.body' > "$$tmp"; \
	fi; \
	$${EDITOR:-vim} "$$tmp"; \
	gh release create "$$tag" --notes-file "$$tmp"; \
	rm -f "$$tmp"
