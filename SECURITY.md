# Security policy

## Private reporting

Report suspected vulnerabilities privately through this repository's GitHub
Security tab: choose **Report a vulnerability** to open a private security
advisory. Do not post exploit details or credentials in public issues or pull
requests. If private reporting is unavailable, contact a repository maintainer
privately to arrange a private advisory before disclosing details publicly.

Include the affected version or revision, impact, reproduction steps using
synthetic data, and a suggested mitigation if known. Never include a live bot
token, personal identifiers, or unredacted logs. Maintainers can coordinate a
fix and disclosure through the advisory; no response deadline is guaranteed.

## Scope

- Token handling: Keychain storage, accidental disclosure through errors or
  logs, Telegram requests, redaction, and setup or removal of credentials.
- Process termination: incorrect console classification, current-user ownership
  checks, battery thresholds, retry limits, and actions affecting unrelated
  processes or other users' sessions.
- Updater: the in-app updater relies on HTTPS to github.com, a SHA-256 digest,
  structural checks, and code-signature consistency. A running app signed with a
  certificate only accepts updates with the same signer (certificate authority
  chain and leaf hash); a running ad-hoc app accepts any consistent signature so
  the move to the stable certificate is possible. It does not authenticate the
  publisher beyond GitHub account and release control, and anyone holding the
  signing key could sign updates; a notarized signed-update scheme is planned.
- Signing key: releases are signed with a self-signed certificate whose private
  key is stored only as GitHub Actions secrets (`SIGNING_CERT_P12`,
  `SIGNING_CERT_PASSWORD`), available to the release build job only. The
  certificate is not notarized or trusted by Gatekeeper. If you suspect the key
  leaked, report it privately. Rotation: create a new code-signing certificate,
  replace both secrets, and publish a new release; users re-grant permissions
  once, and updates from the old signer to the new one are refused by
  already-signed installs, which need a manual reinstall. Reports of bypasses of the checks above are in
  scope.

The policy engine currently returns proposed actions; app wiring and process
termination execution are planned. Reports about the implemented core components
are welcome. Ordinary bugs and feature requests belong in GitHub issues.

If a credential is exposed, revoke or rotate it through its provider promptly.
Deleting a file or local Keychain item does not invalidate a token already copied.
