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
  structural checks, and ad-hoc code-signature consistency. It does not
  authenticate the publisher beyond GitHub account and release control; a
  signed-update scheme is planned. Reports of bypasses of the checks above are in
  scope.

The policy engine currently returns proposed actions; app wiring and process
termination execution are planned. Reports about the implemented core components
are welcome. Ordinary bugs and feature requests belong in GitHub issues.

If a credential is exposed, revoke or rotate it through its provider promptly.
Deleting a file or local Keychain item does not invalidate a token already copied.
