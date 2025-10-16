# Security

## Reporting a vulnerability

Use **Security → Report a vulnerability** in this repository for a private report
when GitHub private vulnerability reporting is enabled. If that option is not
available, open an issue asking the maintainer to enable private reporting or
provide a private contact channel. Keep exploit details and sensitive data out of
that public issue.

A useful private report includes the affected version or commit, prerequisites,
reproduction steps, impact and a minimal example using synthetic data. Do not send
ADB keys, pairing secrets, personal clipboard content, device identifiers or
private files. There is no guaranteed response time or security support period;
fixes are developed against the latest source on `main`.

## Trust boundaries

Nearby uses Android Wireless debugging and the user's ADB authorization. Pair only
phones you own or are authorized to control, confirm prompts on the phone, and
use a trusted network. Pairing authorizes ADB access, which is broader than screen
viewing. Revoke unneeded debugging authorizations in Android's settings.

The app starts an owned ADB service bound to loopback and sends the pinned scrcpy
server and transfer helper to the selected phone. Text clipboard sharing is
controlled by active-session and foreground policies. File uploads use owned
staging files and atomic no-overwrite finalization. See
[architecture](docs/architecture.md) for those boundaries.

Bundled runtime sources, versions, hashes and notices are recorded in
`Sources/Nearby/Resources/Runtime/dependency-manifest.json` and
[THIRD-PARTY-NOTICES.txt](THIRD-PARTY-NOTICES.txt). Build scripts verify the pins
before packaging. A passing test suite or checksum does not establish that the
software has undergone an independent security audit.

## Downloaded alpha builds

Public alpha downloads are provided through
[this repository's GitHub Releases](https://github.com/abhinit21/nearby/releases).
They use ad-hoc signatures for bundle integrity and are **not Developer ID signed
or notarized by Apple**. macOS may block the initial launch. Follow the
[installation and verification instructions](docs/release.md#install-the-alpha)
only if you trust the official release. Do not disable Gatekeeper globally.

Each release includes `SHA256SUMS.txt` for its final DMG and ZIP. Matching a hash
checks download integrity; it does not prove safety or independently authenticate
the publisher. Alpha releases have no guaranteed support period and no automatic
updater. Report a security problem against the affected release and update
manually when a fix is published. Developer ID signing and notarization remain
future distribution work; see [releases](docs/release.md).
