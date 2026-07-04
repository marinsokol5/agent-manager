# Code-signing identity. Defaults to the Developer ID the app ships with — the
# string is public knowledge (it's embedded in every signed binary), only the
# private key is secret. Signing dev builds with the shipping identity is the
# point: keychain/TCC/BTM grants bind to the cert and survive rebuilds and
# releases. Contributors without this cert override with a local self-signed one:
#   make build CODESIGN_ID="AgentManager Dev"
CODESIGN_ID ?= Developer ID Application: Marin Sokol (H33MHC4C79)

# Extra codesign flags. Empty for day-to-day builds (fast, works offline);
# `make release` injects the hardened runtime + secure timestamp that
# notarization requires.
CODESIGN_FLAGS ?=

# Build configuration: debug for dev, release for `make release`.
CONFIG ?= debug
BIN_DIR = .build/$(CONFIG)

# Notarization credentials, stored once in the login keychain with:
#   xcrun notarytool store-credentials agent-manager \
#     --apple-id <apple-id-email> --team-id H33MHC4C79
# (use an app-specific password from account.apple.com)
NOTARY_PROFILE ?= agent-manager

VERSION := $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Support/Info.plist)
RELEASE_ZIP = .build/AgentManager-$(VERSION).zip

# The assembled .app bundle. A real bundle (not the bare SwiftPM executable) is
# what makes SMAppService work: the wake-helper daemon plist ships inside
# Contents/Library/LaunchDaemons and the app registers it with a one-time
# System Settings approval instead of sudo. `am` rides along in Contents/MacOS
# so the scheduler agent's program path resolves next to the app.
# Keep the path stable: launchd's Background-items approval is tied to it
# (a `make clean` therefore costs a re-approval).
APP_BUNDLE = .build/AgentManager.app
CONTENTS = $(APP_BUNDLE)/Contents

.PHONY: build run clean release

build:
	swift build -c $(CONFIG)
	rm -rf $(APP_BUNDLE)
	mkdir -p $(CONTENTS)/MacOS $(CONTENTS)/Resources $(CONTENTS)/Library/LaunchDaemons
	cp Support/Info.plist $(CONTENTS)/Info.plist
	cp Support/com.agent-manager.wake-helper.plist $(CONTENTS)/Library/LaunchDaemons/
	cp $(BIN_DIR)/AgentManager $(BIN_DIR)/am $(BIN_DIR)/am-wake-helper $(CONTENTS)/MacOS/
	cp -R $(BIN_DIR)/AgentManager_AgentManager.bundle $(CONTENTS)/Resources/
	codesign --force $(CODESIGN_FLAGS) --sign "$(CODESIGN_ID)" $(CONTENTS)/MacOS/am-wake-helper
	codesign --force $(CODESIGN_FLAGS) --sign "$(CODESIGN_ID)" $(CONTENTS)/MacOS/am
	codesign --force $(CODESIGN_FLAGS) --sign "$(CODESIGN_ID)" $(APP_BUNDLE)

run: build
	pkill -x AgentManager 2>/dev/null || true
	sleep 0.2
	open $(APP_BUNDLE)

# Build, notarize, and staple a distributable zip at $(RELEASE_ZIP).
# The zip is submitted for notarization, the *app* gets the ticket stapled
# (tickets attach to bundles, not zips), and the zip is rebuilt from the
# stapled app so offline Gatekeeper checks pass for downloaders.
# Publishing is then e.g.: gh release create v$(VERSION) $(RELEASE_ZIP)
release:
	swift test
	$(MAKE) build CONFIG=release CODESIGN_FLAGS="--options runtime --timestamp"
	ditto -c -k --keepParent $(APP_BUNDLE) $(RELEASE_ZIP)
	xcrun notarytool submit $(RELEASE_ZIP) --keychain-profile $(NOTARY_PROFILE) --wait
	xcrun stapler staple $(APP_BUNDLE)
	ditto -c -k --keepParent $(APP_BUNDLE) $(RELEASE_ZIP)
	@echo "==> Notarized, stapled release ready: $(RELEASE_ZIP)"

clean:
	swift package clean
