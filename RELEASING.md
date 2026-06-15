# Releasing andross

This documents how to cut a signed, notarized, distributable build of
`andross.app`. The release pipeline is `scripts/release-sign.sh`; this file
explains the secrets it needs, the exact sequence, and which step a human owns.

> The actual signing/notarization requires an Apple **Developer ID** certificate
> and notarization credentials. Those are not checked into this repo and are not
> present in CI — they live in a maintainer's keychain. `release-sign.sh` is
> written to be one-command-ready once those secrets exist; it refuses to run
> (clean preflight failure, nothing signed) when they are missing.

---

## Required secrets

You provision these **once** on the release machine; the script reads them by
name.

1. **Developer ID Application certificate** (+ its private key) in your login
   keychain. This is issued from your Apple Developer account
   (Certificates → Developer ID Application) and is what `codesign` signs with.
   Confirm it is installed and find its exact identity string:

   ```bash
   security find-identity -v -p codesigning
   # → "Developer ID Application: CVER Inc. (TEAMID)"
   ```

   Export that string into `DEVELOPER_ID` (see below).

2. **A notarytool keychain profile** holding your notarization credentials.
   Create it once — the recommended path is an App Store Connect **API key**
   (Issuer ID + Key ID + `.p8` file):

   ```bash
   xcrun notarytool store-credentials "andross-notary" \
     --key      /path/to/AuthKey_XXXXXXXXXX.p8 \
     --key-id   XXXXXXXXXX \
     --issuer   xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
   ```

   (Alternatively, an Apple ID + app-specific password + team id:
   `--apple-id … --password … --team-id …`.) The profile name you choose here
   is what you pass as `NOTARY_PROFILE`. The actual credentials stay in the
   keychain — never in the repo or environment.

---

## Environment variables consumed by `release-sign.sh`

| Var              | Required | Default                      | Meaning                                                        |
| ---------------- | -------- | ---------------------------- | -------------------------------------------------------------- |
| `DEVELOPER_ID`   | yes      | —                            | Full `Developer ID Application: …` identity string             |
| `NOTARY_PROFILE` | yes      | —                            | `notarytool store-credentials` keychain profile name           |
| `APP_PATH`       | no       | `/Applications/andross.app`  | The built `.app` to sign                                       |
| `OUT_DIR`        | no       | `./dist`                     | Where the signed `.zip` release artifact is written           |

---

## Release sequence

### 1. Build the app (no Xcode required)

```bash
./scripts/build-app.sh          # → /Applications/andross.app
```

### 2. Sign + notarize + staple (one command)

```bash
DEVELOPER_ID="Developer ID Application: CVER Inc. (TEAMID)" \
NOTARY_PROFILE="andross-notary" \
./scripts/release-sign.sh
```

This runs, in order:

1. `codesign --deep --force --options runtime --timestamp` — signs with the
   **hardened runtime** (a notarization requirement) using `DEVELOPER_ID`.
2. `codesign --verify` (and an informational `spctl` check — Gatekeeper will
   still say *rejected* here; that clears after stapling in step 5).
3. `ditto -c -k --keepParent` — zips the `.app` into a notary submission
   archive.
4. `xcrun notarytool submit --keychain-profile "$NOTARY_PROFILE" --wait` —
   uploads to Apple and **blocks** until the verdict.
5. `xcrun stapler staple` (+ `stapler validate` and a final `spctl --assess`) —
   attaches the notarization ticket to the `.app` so it launches offline
   without a Gatekeeper prompt.
6. `ditto -c -k --keepParent` — zips the **stapled** `.app` as the final release
   artifact at `$OUT_DIR/andross.zip`.

If notarization is rejected, inspect the log:

```bash
xcrun notarytool log <submission-id> --keychain-profile "andross-notary"
```

### 3. Upload to GitHub — **human step**

`release-sign.sh` deliberately stops after producing `dist/andross.zip`. Cutting
the GitHub Release and uploading the artifact is done by a person, not the
script:

```bash
# Tag + release are a human action — review the build first.
gh release create vX.Y.Z dist/andross.zip \
  --title "andross vX.Y.Z" \
  --notes "…"
```

Keep the release tag in sync with `CFBundleShortVersionString` in
`scripts/build-app.sh` (currently `0.1.0`).

---

## Why the split

- **Reproducible build** (`build-app.sh`) needs only Apple's Command Line Tools
  and stays runnable by anyone / in CI.
- **Signing + notarization** (`release-sign.sh`) needs Apple Developer secrets,
  so it is isolated and fails safe when they are absent.
- **Publishing** (the `gh release` upload) is a deliberate human gate — no
  script in this repo pushes a release.
