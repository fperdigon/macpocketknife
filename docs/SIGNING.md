# Signing, permissions and releases

Why MacPocketKnife releases use one stable self-signed certificate, how it is created and used in CI, and the gotchas found on the way. Contains no secrets. The bundle identifier is `io.github.fperdigon.macpocketknife`; the certificate name is "MacPocketKnife Signing". This is not notarization and does not remove the Gatekeeper warning.

## 1. Why this matters: ad-hoc signing loses permissions on every update

- `codesign -s -` (ad-hoc) gives the app no stable identity. macOS ties TCC grants (Microphone, Screen Recording, Speech Recognition, Accessibility, ...) and legacy Keychain item access to the code hash (cdhash), which changes with every build.
- Symptom: after each update the user must remove and re-add permissions, and the Keychain asks again.
- Stop-gap: on the first launch after an update, run `tccutil reset <Service> io.github.fperdigon.macpocketknife` for the app's own services (Microphone, ScreenCapture, SpeechRecognition). The app never touches other apps' entries.
- Real fix: sign every release with one stable certificate (section 3). macOS then identifies the app by its designated requirement (certificate + bundle id), so grants and Keychain items survive updates.

## 2. Other permission traps found

- **Hardened runtime needs the audio-input entitlement.** With `--options runtime`, an app without `com.apple.security.device.audio-input` is denied microphone access silently: no prompt, and the app never appears under Privacy > Microphone. Evidence: `log show --predicate 'subsystem == "com.apple.TCC"'` shows "Prompting policy for hardened runtime...". Fix: sign with `--entitlements` containing that key.
- The Microphone privacy pane has no "+" button. An app appears only after it requested access once.
- `CGPreflightScreenCaptureAccess` is unreliable. Derive "Screen Recording granted" from actually getting thumbnails or frames.
- Open the exact privacy panes with deep links: `x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture`, `...?Privacy_Microphone`, `...?Privacy_SpeechRecognition`.
- Make local builds identical to release builds (same bundle path, same entitlements, same signing mode), otherwise you debug a different app from the one users run.

## 3. Stable self-signed code-signing certificate (step by step)

What it gives: grants and Keychain items survive updates; the updater can require the same signer as the installed app.
What it does not give: Gatekeeper still warns (only Developer ID + notarization removes it). The first release signed this way needs one last re-grant of permissions. The private key must never be committed. Not a substitute for Apple notarization.

Rules learned the hard way:
- Keep key material OUTSIDE every repo, in a private directory outside every repository (for example `~/.signing/macpocketknife/`) with mode 700. Do not rely on `.gitignore` alone.
- Use macOS `/usr/bin/openssl` (LibreSSL). Its `.p12` imports with `security import` on CI runners; a newer OpenSSL 3 default (AES-256 PBES2) can fail there.
- Password prompts do not work in a chat tool's `!` box. Run interactive commands in a real terminal.
- `base64 -i missing | gh secret set NAME` prints "Set Actions secret" even when the file is missing, because it stores an EMPTY value. Always check the file size first (`test -s file && ...`).
- Re-running `openssl pkcs12 -export ... -out file` truncates the output file immediately. A recalled shell-history command can empty your only copy.
- Never `rm` key.pem/cert.pem before the `.p12` and its password are backed up AND the backup was opened once.
- Use ONE password for the `.p12` and for the GitHub secret; set both in one script run so they cannot differ.

Do it with one local script (kept outside the repository):

1. `mkdir -p ~/.signing/macpocketknife && chmod 700 ~/.signing ~/.signing/macpocketknife`
2. Generate key and certificate (config with `basicConstraints=critical,CA:false`, `keyUsage=critical,digitalSignature`, `extendedKeyUsage=critical,codeSigning`, CN `MacPocketKnife Signing`, 3650 days):
   `/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 3650 -config openssl.cnf`
3. Bundle with a password (typed in a real terminal, never echoed):
   `/usr/bin/openssl pkcs12 -export -inkey key.pem -in cert.pem -name "MacPocketKnife Signing" -out MacPocketKnife-signing.p12 -passout env:P12PW`
4. Verify before uploading: file is non-empty and `openssl pkcs12 -in file -noout -passin env:P12PW` succeeds.
5. Upload both GitHub Actions secrets (the user does this, an agent never handles them):
   `base64 -i MacPocketKnife-signing.p12 | gh secret set SIGNING_CERT_P12 --repo fperdigon/macpocketknife`
   `printf '%s' "$PW" | gh secret set SIGNING_CERT_PASSWORD --repo fperdigon/macpocketknife`
6. Back up the `.p12` and its password in a password manager (1Password attaches files; for Bitwarden free or the macOS Passwords app store the base64 text as a secure note; or keep an AES-256 encrypted disk image: `hdiutil create -encryption AES-256 -size 5m -fs APFS -volname SigningBackup SigningBackup.dmg`). Open the backup once to prove it works. Only then delete the loose `.pem` files.
7. Check with `gh secret list --repo fperdigon/macpocketknife` (names and dates only).

CI side (release `build` job only; publish jobs never get the secrets). In this repository it is implemented by `scripts/import-signing-identity.sh` (import), `scripts/make-app-bundle.sh` (signing with `SIGN_IDENTITY`, the entitlements file `Resources/MacPocketKnife.entitlements`) and `scripts/verify-dmg.sh` (`EXPECT_SIGNED_IDENTITY`). Steps in short:
- Create a temporary keychain in `$RUNNER_TEMP` with a random password, unlock it, `security import ... -P "$PASSWORD" -T /usr/bin/codesign`, then `security set-key-partition-list -S apple-tool:,apple: -s -k <kcpass> <keychain>`.
- The cert is self-signed and not trusted, so `security find-identity -v` hides it. Find it with `security find-identity -p codesigning` and sign by the SHA-1 hash, not by name.
- Sign with `--options runtime --entitlements <file> --timestamp=none` (no timestamp authority for a self-signed identity).
- Delete the temporary keychain in an `if: always()` step. If secrets are present but the import fails, fail the job; never silently fall back to ad-hoc. Without secrets (forks) fall back to ad-hoc with a visible warning.
- Verify the built DMG: `codesign --verify --deep --strict`, `codesign -dvv` shows the expected leaf certificate, and the entitlements are present.

Updater rule: if the running app is signed with a certificate, require the update to carry the same leaf certificate; if the running app is ad-hoc, allow the transition once.

Rotation: create a new cert, replace both secrets, expect one more permission re-grant.

## 4. Release pipeline lessons

- Split build from publish: `build` has `contents: read` and no token, uploads an artifact; separate `publish-nightly` (main only) and `publish-stable` (`v*` tags only, commit must be an ancestor of main and have a successful CI run). `permissions: {}` at workflow level, actions pinned by commit SHA, Xcode version pinned, concurrency groups per channel.
- Hosted macOS runners queue for up to an hour and sometimes cancel jobs: `gh run rerun <id> --failed`. A cancelled run shows up as "failure"; read the job conclusions before debugging code.
- CI Xcode/Swift is older than a developer's local toolchain: avoid long chained expressions and fancy default-argument initializers; compile-check against the CI Swift version.
- Hidden self-test launch flags in a shipped app are an attack surface: require an explicit env var and a safe output path.
- Auto-updaters must require a checksum, validate bundle structure (no symlinks, bundle id, version/channel), and verify the signature; the docs state honestly that nothing authenticates the publisher beyond control of the GitHub account (and the signing key) until a notarized, publisher-verified scheme exists.
