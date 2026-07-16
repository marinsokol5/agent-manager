#!/usr/bin/env bash
#
# One-command release: build + notarize + staple, publish the GitHub release,
# then update + push the Homebrew cask — with the sha256 taken straight from the
# zip we just built, so version/sha can never drift out of sync by hand.
#
# Usage:
#   Scripts/release.sh              # release the version in Support/Info.plist.in
#   Scripts/release.sh 0.1.3        # bump Info.plist.in to 0.1.3 (+commit), then release
#
# Env overrides:
#   REPO=marinsokol5/agent-manager        GitHub repo (owner/name)
#   TAP_DIR=~/projects/homebrew-tap        local clone of the Homebrew tap
#   NOTES="…"                              release notes (default: gh --generate-notes)
#   YES=1                                  skip the confirmation prompt
#   ALLOW_DIRTY=1                          allow a dirty working tree (not recommended)
#
# Prereqs: gh (authed), a notarytool keychain profile (see the Makefile), and a
# checked-out tap whose remote you can push.
set -euo pipefail

REPO="${REPO:-marinsokol5/agent-manager}"
TAP_DIR="${TAP_DIR:-$HOME/projects/homebrew-tap}"
CASK="$TAP_DIR/Casks/agent-manager.rb"
PLIST="Support/Info.plist.in"

cd "$(git rev-parse --show-toplevel)"

# 0. Optional version bump (only commits if the value actually changed). Keep the
#    compiled fallback in AppVersion.swift in lockstep with the plist, so the bare
#    `.build/debug/am --version` matches even before the next bundle is assembled.
if [[ $# -ge 1 ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $1" "$PLIST"
    /usr/bin/sed -i '' -E "s/(static let fallback = \")[^\"]*(\")/\1$1\2/" \
        Sources/AgentManagerCore/AppVersion.swift
    git add "$PLIST" Sources/AgentManagerCore/AppVersion.swift
    if ! git diff --cached --quiet; then
        git commit -m "Bump to $1" >/dev/null
        echo "==> bumped $PLIST to $1"
    fi
fi

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")"
TAG="v$VERSION"
ZIP=".build/AgentManager-$VERSION.zip"

# 1. Preflight — fail before we build/publish anything, not halfway through.
[[ -f "$CASK" ]] || { echo "!! cask not found: $CASK (set TAP_DIR)"; exit 1; }
if [[ -z "${ALLOW_DIRTY:-}" && -n "$(git status --porcelain)" ]]; then
    echo "!! working tree is dirty — commit first (or ALLOW_DIRTY=1):"; git status --short; exit 1
fi
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    echo "!! release $TAG already exists — bump the version first"; exit 1
fi

echo "==> release $TAG → $REPO"
echo "    cask: $CASK"
if [[ -z "${YES:-}" ]]; then
    [[ -t 0 ]] || { echo "!! non-interactive; set YES=1 to proceed"; exit 1; }
    read -r -p "Proceed? [y/N] " ans; [[ "$ans" == [yY]* ]] || { echo aborted; exit 1; }
fi

# 2. Build the notarized, stapled zip (runs the test suite first — see Makefile).
make release

# 3. Publish the GitHub release. Push HEAD first so the tag gh creates resolves
#    to a commit that's actually on the remote.
git push origin HEAD
if [[ -n "${NOTES:-}" ]]; then
    gh release create "$TAG" "$ZIP" --repo "$REPO" --title "Agent Manager $VERSION" --notes "$NOTES"
else
    gh release create "$TAG" "$ZIP" --repo "$REPO" --title "Agent Manager $VERSION" --generate-notes
fi

# 4. Update the cask: version + the sha256 of the zip we literally just shipped.
SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
/usr/bin/sed -i '' -E \
    -e "s/^  version \".*\"/  version \"$VERSION\"/" \
    -e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" \
    "$CASK"
git -C "$TAP_DIR" add Casks/agent-manager.rb
git -C "$TAP_DIR" commit -m "agent-manager $VERSION" >/dev/null
git -C "$TAP_DIR" push origin HEAD

# 5. Refresh the installed tap clone (so `brew upgrade` sees it now) + audit.
TAP_CLONE="$(brew --repository)/Library/Taps/marinsokol5/homebrew-tap"
[[ -d "$TAP_CLONE" ]] && git -C "$TAP_CLONE" pull --ff-only >/dev/null 2>&1 || true
brew audit --cask --online marinsokol5/tap/agent-manager || true

# 6. Upgrade the local install to the version we just shipped. Best-effort:
#    the release is already out, so a machine without the brew copy installed
#    must not turn the whole publish into a failure.
brew upgrade --yes --cask marinsokol5/tap/agent-manager \
    || echo "!! local brew upgrade failed — run manually: brew upgrade --cask agent-manager"

# 7. Restart the running app so the upgraded bundle takes over (the cask swap
#    leaves the old build running from a deleted bundle). Anchor the match to
#    the GUI executable only — the bundled `am` scheduler daemon and any
#    in-flight ping child live under the same bundle path but restart
#    themselves on upgrade (see AGENTS.md); never kill those.
APP_EXEC="/Applications/AgentManager.app/Contents/MacOS/Agent Manager"
if pkill -f "^$APP_EXEC" 2>/dev/null; then
    sleep 0.5
    open "/Applications/AgentManager.app" \
        || echo "!! relaunch failed — open Agent Manager manually"
    echo "==> restarted Agent Manager on the new build"
else
    echo "==> Agent Manager wasn't running — not relaunched"
fi

echo "==> $TAG published."
