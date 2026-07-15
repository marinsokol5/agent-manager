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

# Build variant — the whole reason a locally built app can coexist with the
# released one. `dev` (the default, what `make build`/`make run` produce) stamps
# a distinct bundle ID, launchd labels, workspace, and app name so it never
# collides with the `prod` build that `make release` ships (and brew installs).
# The single source of truth at runtime is AppVariant/WakeVariant, kept in sync
# with the values below by the AGENT_MANAGER_DEV compile define. Never release
# the dev variant. See AGENTS.md "Build, run, test".
VARIANT ?= dev
IS_PROD = $(filter prod,$(VARIANT))

BUNDLE_ID    = $(if $(IS_PROD),com.agent-manager.app,com.agent-manager.app.dev)
APP_NAME     = $(if $(IS_PROD),Agent Manager,Agent Manager (Dev))
EXEC_NAME    = $(APP_NAME)
HELPER_LABEL = $(if $(IS_PROD),com.agent-manager.wake-helper,com.agent-manager.dev.wake-helper)
SCHEDULER_LABEL = $(if $(IS_PROD),com.agent-manager.scheduler,com.agent-manager.dev.scheduler)
APP_BASENAME = $(if $(IS_PROD),AgentManager,AgentManager-dev)
DEV_DEFINE   = $(if $(IS_PROD),,-Xswiftc -DAGENT_MANAGER_DEV)

# Notarization credentials, stored once in the login keychain with:
#   xcrun notarytool store-credentials agent-manager \
#     --apple-id <apple-id-email> --team-id H33MHC4C79
# (use an app-specific password from account.apple.com)
NOTARY_PROFILE ?= agent-manager

VERSION := $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Support/Info.plist.in)
RELEASE_ZIP = .build/AgentManager-$(VERSION).zip

# The assembled .app bundle. A real bundle (not the bare SwiftPM executable) is
# what makes SMAppService work: the wake-helper daemon plist ships inside
# Contents/Library/LaunchDaemons and the app registers it with a one-time
# System Settings approval instead of sudo. `am` rides along in Contents/MacOS
# so the scheduler agent's program path resolves next to the app.
# Keep the *prod* path (.build/AgentManager.app) stable: launchd's
# Background-items approval is tied to it (a `make clean` therefore costs a
# re-approval). The dev variant assembles alongside it at .build/AgentManager-dev.app.
APP_BUNDLE = .build/$(APP_BASENAME).app
CONTENTS = $(APP_BUNDLE)/Contents

.PHONY: build run clean release publish icon

build:
	swift build -c $(CONFIG) $(DEV_DEFINE)
	rm -rf $(APP_BUNDLE)
	mkdir -p $(CONTENTS)/MacOS $(CONTENTS)/Resources $(CONTENTS)/Library/LaunchDaemons $(CONTENTS)/Library/LaunchAgents
	sed -e 's/__BUNDLE_ID__/$(BUNDLE_ID)/g' -e "s/__APP_NAME__/$(APP_NAME)/g" -e "s/__EXEC_NAME__/$(EXEC_NAME)/g" Support/Info.plist.in > $(CONTENTS)/Info.plist
	cp Support/AgentManager.icns $(CONTENTS)/Resources/
	sed -e 's/__HELPER_LABEL__/$(HELPER_LABEL)/g' -e 's/__BUNDLE_ID__/$(BUNDLE_ID)/g' Support/wake-helper.plist.in > $(CONTENTS)/Library/LaunchDaemons/$(HELPER_LABEL).plist
	sed -e 's/__SCHEDULER_LABEL__/$(SCHEDULER_LABEL)/g' -e 's/__BUNDLE_ID__/$(BUNDLE_ID)/g' Support/scheduler.plist.in > $(CONTENTS)/Library/LaunchAgents/$(SCHEDULER_LABEL).plist
	cp $(BIN_DIR)/am $(BIN_DIR)/am-wake-helper $(CONTENTS)/MacOS/
	cp $(BIN_DIR)/AgentManager "$(CONTENTS)/MacOS/$(EXEC_NAME)"
	cp -R $(BIN_DIR)/AgentManager_AgentManager.bundle $(CONTENTS)/Resources/
	codesign --force $(CODESIGN_FLAGS) --sign "$(CODESIGN_ID)" $(CONTENTS)/MacOS/am-wake-helper
	codesign --force $(CODESIGN_FLAGS) --sign "$(CODESIGN_ID)" $(CONTENTS)/MacOS/am
	codesign --force $(CODESIGN_FLAGS) --sign "$(CODESIGN_ID)" $(APP_BUNDLE)

run: build
	pkill -f "$(notdir $(APP_BUNDLE))/Contents/MacOS/Agent Manager" 2>/dev/null || true
	sleep 0.2
	open $(APP_BUNDLE)

# release progress helpers -------------------------------------------------
# `make release` stamps an epoch at the top of the recipe and timestamps each
# phase, so the long notarization wait shows elapsed [mm:ss] instead of going
# silent. $(call elapsed,<msg>) prints "==> [mm:ss] <msg>"; messages must not
# contain commas — $(call) treats a comma as an argument separator.
RELEASE_START = .build/.release-start
elapsed = t=$$(( $$(date +%s) - $$(cat $(RELEASE_START)) )); printf '==> [%02d:%02d] %s\n' $$((t/60)) $$((t%60)) "$(1)"

# Build, notarize, and staple a distributable zip at $(RELEASE_ZIP).
# The zip is submitted for notarization, the *app* gets the ticket stapled
# (tickets attach to bundles, not zips), and the zip is rebuilt from the
# stapled app so offline Gatekeeper checks pass for downloaders.
# `make release` just builds the artifact; `make publish` (below) also cuts the
# GitHub release and updates the Homebrew cask.
# Force the prod variant for the whole release recipe (so $(APP_BUNDLE) etc.
# resolve to the released paths, not the default dev ones) and for the build
# sub-make. Never ship the dev variant.
release: VARIANT := prod
release:
	@mkdir -p .build && date +%s > $(RELEASE_START)
	@$(call elapsed,running tests)
	swift test
	@$(call elapsed,building signed release bundle)
	$(MAKE) build CONFIG=release VARIANT=prod CODESIGN_FLAGS="--options runtime --timestamp"
	@$(call elapsed,zipping bundle for notary submission)
	ditto -c -k --keepParent $(APP_BUNDLE) $(RELEASE_ZIP)
	@$(call elapsed,submitting to Apple notary — the slow part (usually 1-15 min))
	xcrun notarytool submit $(RELEASE_ZIP) --keychain-profile $(NOTARY_PROFILE) --wait
	@$(call elapsed,stapling notarization ticket to the app)
	xcrun stapler staple $(APP_BUNDLE)
	@$(call elapsed,re-zipping the stapled app)
	ditto -c -k --keepParent $(APP_BUNDLE) $(RELEASE_ZIP)
	@$(call elapsed,done)
	@echo "==> Notarized, stapled release ready: $(RELEASE_ZIP)"

# Full release: build + notarize (via `make release`), publish the GitHub
# release, and update + push the Homebrew cask. `make publish` ships the version
# currently in Support/Info.plist.in; `make publish V=0.1.3` bumps it first.
# See Scripts/release.sh for env overrides (REPO, TAP_DIR, NOTES, YES).
publish:
	@Scripts/release.sh $(V)

# Regenerate Support/AgentManager.icns from the code-defined brand mark.
# The .icns is committed, so normal builds don't run this; rerun (and commit
# the result) after changing AgentManagerLogo.
icon:
	mkdir -p .build
	swiftc -O -parse-as-library \
		Scripts/render-icon.swift \
		Sources/AgentManager/AgentManagerLogo.swift \
		-o .build/render-icon
	.build/render-icon Support/AgentManager.icns

clean:
	swift package clean
