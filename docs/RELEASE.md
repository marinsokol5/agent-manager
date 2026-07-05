# Releasing Agent Manager

How to cut a signed, notarized GitHub release. Releases are built and published
**manually from a Mac** with the Developer ID cert in its keychain — there is no
CI release pipeline (deliberate: keeps the signing key off shared compute).

The whole flow is driven by the `release` target in the [`Makefile`](../Makefile);
this doc is the surrounding checklist.

---

## One-time setup

Do these once per machine. They persist in the login keychain.

### 1. Developer ID signing identity

Signing binds Keychain / TCC / Background-items grants to the certificate, so the
same cert must sign every release. Confirm it's present:

```bash
security find-identity -v -p codesigning | grep "Developer ID Application"
# expect: Developer ID Application: Marin Sokol (H33MHC4C79)
```

If it's missing, install the cert + private key (from the Apple Developer account)
into the login keychain before continuing.

### 2. Notarization credentials

Store an App Store Connect app-specific password once, under the profile name the
Makefile expects (`agent-manager`):

```bash
xcrun notarytool store-credentials agent-manager \
  --apple-id marinsokol18@gmail.com --team-id H33MHC4C79
# paste an app-specific password generated at https://account.apple.com
```

Verify it works:

```bash
xcrun notarytool history --keychain-profile agent-manager
```

---

## Usual release

Every release, from a clean checkout on `main`:

### 1. Pick the version

The version is read from `CFBundleShortVersionString` in
[`Support/Info.plist`](../Support/Info.plist) and flows into the zip name and the
tag. Bump it there if this release should advance the number:

```bash
/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Support/Info.plist
# edit Support/Info.plist to bump, then commit the bump
```

### 2. Commit and clean the tree

`gh release create` tags whatever is committed at `HEAD`, so the working tree must
be clean and the version bump committed:

```bash
git status          # should be clean
git switch main && git pull
```

### 3. Build, test, notarize, staple

```bash
make release
```

This runs `swift test`, builds a release-config signed `.app` with the hardened
runtime + secure timestamp, zips it, submits to Apple with `--wait` (the polling
dots can take several minutes — normal), staples the notarization ticket to the
`.app`, and re-zips so the stapled ticket rides along. Output:
`.build/AgentManager-<version>.zip`.

### 4. Publish

```bash
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Support/Info.plist)
gh release create "v$VERSION" ".build/AgentManager-$VERSION.zip" \
  --title "Agent Manager $VERSION" \
  --notes "Download the zip, unzip, and drag AgentManager.app to /Applications."
```

### 5. Verify the published artifact

Download the release zip on a clean machine (or a fresh directory) and confirm
Gatekeeper accepts it offline:

```bash
spctl -a -vvv --type exec /path/to/AgentManager.app
# expect: accepted, source=Notarized Developer ID
```

---

## Notes

- **No CI secrets.** The signing key never leaves your Mac's keychain. If this
  ever moves to GitHub Actions, the cert (`.p12`) and an App Store Connect API key
  would have to live as encrypted Actions secrets scoped to a protected
  environment — see the discussion in the project history before doing that.
- **Keep the bundle path stable.** launchd's Background-items approval binds to
  `.build/AgentManager.app`; a `make clean` costs a re-approval but does not
  affect downloaders.
- **Tickets attach to bundles, not zips.** That's why `make release` re-zips the
  `.app` *after* stapling — the second zip is the one you publish.
