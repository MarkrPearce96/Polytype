# Releasing a new version

Two repos are involved: this one (`Polytype`, builds and publishes the
release) and `~/Developer/homebrew-tap` (holds the Homebrew Cask that
points at it). Both need updating for a release to actually reach users.

## Steps

1. **Bump the version.** Edit `scripts/build-bar.sh` and change the
   `APP_VERSION`/`APP_BUILD` defaults (used for local dev builds only —
   release CI overrides them from the git tag, but keep them in sync so a
   local build matches the last release).

2. **Commit and push to `main`:**
   ```bash
   git add scripts/build-bar.sh
   git commit -m "chore: bump version to X.Y.Z"
   git push origin main
   ```

3. **Tag and push.** The tag must exactly match the version — CI checks
   this and fails the build if it doesn't:
   ```bash
   git tag vX.Y.Z
   git push origin vX.Y.Z
   ```

4. **Watch the release workflow:**
   ```bash
   gh run watch "$(gh run list --workflow=release.yml --limit 1 --json databaseId --jq '.[0].databaseId')" --exit-status
   ```
   It imports the signing certificate, builds with `scripts/build-bar.sh`
   (signed with a personal Apple Development certificate — see "Signing"
   below), verifies the built version matches the tag, verifies the
   signature chains to a real Apple certificate, verifies the zip's
   structure, and publishes a GitHub Release with `Polytype.zip` attached.
   If it fails, read `gh run view --log-failed`, fix the problem, then see
   "If something goes wrong" below before re-tagging.

5. **Get the sha256** — either from the release notes (the workflow
   writes it there) or:
   ```bash
   curl -sL -o /tmp/Polytype.zip "https://github.com/MarkrPearce96/Polytype/releases/download/vX.Y.Z/Polytype.zip"
   shasum -a 256 /tmp/Polytype.zip
   ```

6. **Update the Cask in the tap repo** (`~/Developer/homebrew-tap`, a
   separate repo — this step is easy to forget):
   ```bash
   cd ~/Developer/homebrew-tap
   # edit Casks/polytype.rb: version "X.Y.Z", sha256 "<from step 5>"
   ruby -c Casks/polytype.rb && brew style Casks/polytype.rb
   git add Casks/polytype.rb
   git commit -m "fix: bump polytype to X.Y.Z"
   git push origin main
   ```

7. **Verify end to end:**
   ```bash
   git -C "$(brew --repository markrpearce96/tap)" pull
   brew upgrade --cask polytype   # or brew install --cask polytype if not yet installed
   ```

## If something goes wrong mid-release

If a tag's CI run fails *before* publishing a release, fix the problem,
then delete and re-push the tag:
```bash
git push origin :refs/tags/vX.Y.Z
git tag -d vX.Y.Z
git tag vX.Y.Z
git push origin vX.Y.Z
```

If a release *was* already published and needs redoing, delete it first:
```bash
gh release delete vX.Y.Z --yes
```

Never silently re-push over an existing tag or release — always delete
deliberately first, so it's a decision, not an accident.

## What CI checks for you automatically

- The signature chains to a real Apple certificate authority (Apple Root
  CA) — ad-hoc/self-signed would still run, but the Accessibility grant
  wouldn't survive an update (TCC keys on the signing identity).
- The built app's `CFBundleShortVersionString` matches the git tag.
- The release zip's top-level entry is exactly `Polytype.app`.

## Signing

Polytype isn't sandboxed and has no Safari extension, so plain ad-hoc
signing would technically run — but the Accessibility permission grant is
keyed to the code-signing identity, so every ad-hoc rebuild would force
users to re-grant Accessibility after each update. Signing with a stable,
real certificate avoids that:

- **Locally**: `scripts/build-bar.sh` auto-detects your local "Apple
  Development" identity from the keychain (or set `CODESIGN_IDENTITY` to
  override).
- **In CI**: the workflow imports that same certificate from two
  repository secrets, `APPLE_CERT_P12_BASE64` (the certificate + private
  key, exported with
  `security export -k <keychain> -t identities -f pkcs12 -P <password> -o cert.p12`,
  then base64-encoded) and `APPLE_CERT_PASSWORD` (the export password),
  into a throwaway keychain before building.
- The certificate expires after about a year — if a release build ever
  fails signing, export a fresh one from Xcode (Settings > Accounts >
  Manage Certificates > +) and update the two secrets.
- The app is not notarized (no paid Apple Developer account), so
  Gatekeeper's first-launch warning is unchanged — see the Cask's
  `caveats` for the one-time workaround.

## One-time setup (already done, listed for reference only)

The GitHub Actions workflow itself (`.github/workflows/release.yml`) and
the `APPLE_CERT_P12_BASE64` / `APPLE_CERT_PASSWORD` repository secrets
(see "Signing" above) — none of this needs repeating for a normal release.
