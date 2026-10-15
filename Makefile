# Claude Pool build entry points.
#
# With full Xcode installed, `make build` uses XcodeGen + xcodebuild.
# With only the Command Line Tools, it builds with SwiftPM and assembles
# ClaudePool.app by hand (same layout, same signing). Override with
# BUILD_SYSTEM=xcode or BUILD_SYSTEM=swiftpm.

APP_NAME     := ClaudePool
BUILD_DIR    := build
APP          := $(BUILD_DIR)/$(APP_NAME).app
HELPER_NAME  := claude-pool-collector
ARCH         := arm64
SWIFT_FLAGS  := -Xswiftc -warnings-as-errors
PLIST        := Resources/Info.plist
VERSION      := $(shell /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' $(PLIST))
BUILD_NUMBER := $(shell /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' $(PLIST))
DMG          := $(BUILD_DIR)/$(APP_NAME)-$(VERSION).dmg

# With only the Command Line Tools, Swift Testing lives outside the default search paths.
CLT_DEV      := /Library/Developer/CommandLineTools/Library/Developer
ifneq ($(wildcard $(CLT_DEV)/Frameworks/Testing.framework),)
TEST_FLAGS   := -Xswiftc -F -Xswiftc $(CLT_DEV)/Frameworks \
                -Xlinker -rpath -Xlinker $(CLT_DEV)/Frameworks \
                -Xlinker -rpath -Xlinker $(CLT_DEV)/usr/lib
endif

# Signing. The default "-" is ad-hoc: fine locally, but Gatekeeper blocks the app on other Macs.
# For a release, pass a Developer ID identity and a notarytool keychain profile, e.g.
#   make notarize SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" NOTARY_PROFILE=claude-pool
SIGN_IDENTITY  ?= -
NOTARY_PROFILE ?=
ifeq ($(SIGN_IDENTITY),-)
TIMESTAMP    := --timestamp=none
else
TIMESTAMP    := --timestamp
endif

HAVE_XCODE   := $(shell xcodebuild -version >/dev/null 2>&1 && echo yes)
ifeq ($(HAVE_XCODE),yes)
BUILD_SYSTEM ?= xcode
else
BUILD_SYSTEM ?= swiftpm
endif

.PHONY: generate build test run dmg notarize icon version set-version clean live-check snapshots static-check symbol-check build-xcode build-swiftpm check-plist

generate:
	@command -v xcodegen >/dev/null || { echo "xcodegen not found: brew install xcodegen"; exit 1; }
	xcodegen generate --spec project.yml

build: build-$(BUILD_SYSTEM)

build-xcode: check-plist generate
	xcodebuild -project $(APP_NAME).xcodeproj -scheme $(APP_NAME) -configuration Release \
		-derivedDataPath $(BUILD_DIR)/DerivedData ARCHS=$(ARCH) CODE_SIGN_IDENTITY="$(SIGN_IDENTITY)" OTHER_CODE_SIGN_FLAGS="$(TIMESTAMP)" build
	rm -rf "$(APP)"
	cp -R "$(BUILD_DIR)/DerivedData/Build/Products/Release/$(APP_NAME).app" "$(APP)"
	@echo "Built $(APP)"

check-plist:
	@/usr/libexec/PlistBuddy -c 'Print :LSUIElement' Resources/Info.plist | grep -q true && \
	/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' Resources/Info.plist | grep -qx '$(APP_NAME)' || \
	{ echo "Resources/Info.plist is missing LSUIElement or CFBundleExecutable"; exit 1; }

build-swiftpm: check-plist
	swift build -c release --arch $(ARCH) $(SWIFT_FLAGS)
	@BIN=$$(swift build -c release --arch $(ARCH) --show-bin-path) && \
	rm -rf "$(APP)" && \
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Helpers" "$(APP)/Contents/Resources" && \
	cp Resources/Info.plist "$(APP)/Contents/Info.plist" && \
	cp Resources/AppIcon.icns "$(APP)/Contents/Resources/AppIcon.icns" && \
	printf 'APPL????' > "$(APP)/Contents/PkgInfo" && \
	cp "$$BIN/$(APP_NAME)" "$(APP)/Contents/MacOS/$(APP_NAME)" && \
	cp "$$BIN/$(HELPER_NAME)" "$(APP)/Contents/Helpers/$(HELPER_NAME)" && \
	codesign --force --options runtime $(TIMESTAMP) --identifier com.example.claudepool.collector \
		--sign "$(SIGN_IDENTITY)" "$(APP)/Contents/Helpers/$(HELPER_NAME)" && \
	codesign --force --options runtime $(TIMESTAMP) --sign "$(SIGN_IDENTITY)" "$(APP)" && \
	codesign --verify --strict --verbose=1 "$(APP)" && \
	echo "Built $(APP)"

test:
	swift test $(SWIFT_FLAGS) $(TEST_FLAGS)

run: build
	open "$(APP)"

# Drag-to-install disk image: build/ClaudePool-<version>.dmg with the app and an Applications link.
# Ad-hoc signed by default; use `make notarize` for a DMG that opens on other Macs without a warning.
dmg: build
	@rm -rf "$(BUILD_DIR)/dmg-root" "$(DMG)"
	@mkdir -p "$(BUILD_DIR)/dmg-root"
	ditto "$(APP)" "$(BUILD_DIR)/dmg-root/$(APP_NAME).app"
	ln -s /Applications "$(BUILD_DIR)/dmg-root/Applications"
	@# The app icon as the mounted volume's icon (SetFile ships with the Command Line Tools).
	cp Resources/AppIcon.icns "$(BUILD_DIR)/dmg-root/.VolumeIcon.icns"
	@if command -v SetFile >/dev/null; then SetFile -a C "$(BUILD_DIR)/dmg-root"; fi
	hdiutil create -volname "Claude Pool $(VERSION)" -srcfolder "$(BUILD_DIR)/dmg-root" -fs HFS+ -format UDZO -ov "$(DMG)"
	@rm -rf "$(BUILD_DIR)/dmg-root"
	@echo "Built $(DMG)"

# Developer ID-signed, notarized and stapled DMG. One-time setup:
#   xcrun notarytool store-credentials claude-pool --apple-id <id> --team-id <TEAMID>
notarize:
	@test "$(SIGN_IDENTITY)" != "-" || { echo "notarize needs SIGN_IDENTITY=\"Developer ID Application: …\""; exit 1; }
	@test -n "$(NOTARY_PROFILE)" || { echo "notarize needs NOTARY_PROFILE=<notarytool keychain profile>"; exit 1; }
	$(MAKE) dmg SIGN_IDENTITY="$(SIGN_IDENTITY)"
	codesign --force $(TIMESTAMP) --sign "$(SIGN_IDENTITY)" "$(DMG)"
	xcrun notarytool submit "$(DMG)" --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple "$(DMG)"
	spctl --assess --type open --context context:primary-signature --verbose "$(DMG)"
	@echo "Notarized $(DMG)"

# Redraws Resources/AppIcon.icns and AppIcon-1024.png from scripts/make-icon.swift.
icon:
	swift scripts/make-icon.swift Resources

version:
	@echo "$(VERSION) (build $(BUILD_NUMBER))"

# make set-version V=1.2.0 — sets the version and increments the build number.
set-version:
	@test -n "$(V)" || { echo "usage: make set-version V=1.2.0"; exit 1; }
	@/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString $(V)' $(PLIST)
	@/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion $(shell echo $$(($(BUILD_NUMBER) + 1)))' $(PLIST)
	@echo "Version $(V) (build $(shell echo $$(($(BUILD_NUMBER) + 1))))"

# Read-only checks against the real claude binary, Keychain sign-ins and login shell.
live-check:
	CLAUDE_POOL_LIVE=1 swift test $(SWIFT_FLAGS) $(TEST_FLAGS) --filter LiveAuditTests

# Renders every screen with sample data (light, dark, narrowest width) via real windows.
SNAPSHOT_DIR ?= build/snapshots
snapshots:
	CLAUDE_POOL_SNAPSHOT_DIR=$(abspath $(SNAPSHOT_DIR)) swift test $(SWIFT_FLAGS) $(TEST_FLAGS) --filter UISnapshotTests
	@echo "Snapshots in $(SNAPSHOT_DIR)"

static-check:
	@scripts/static-check.sh
	@if [ -d "$(APP)" ]; then scripts/symbol-check.sh "$(APP)"; else echo "symbol-check skipped: run 'make build' first"; fi

symbol-check:
	@scripts/symbol-check.sh "$(APP)"

clean:
	rm -rf .build $(BUILD_DIR) $(APP_NAME).xcodeproj
