# Install and permissions

## Requirements
macOS 14 or later. Builds are in development; see [verification status](../verification/README.md) before relying on them for important cleanup.

## First launch
1. Download a development DMG from [GitHub releases](https://github.com/k-electron-bots/spacelyzer-native/releases).
2. Open the app. The build is self-signed, not notarized, so macOS may block launch.
3. Use **System Settings > Privacy & Security > Open Anyway** for this app. macOS may ask for your login password.

Do not disable Gatekeeper or clear quarantine flags. Diagnostic builds are not a substitute for a release-readiness gate.

## Protected folders
Full Disk Access in **System Settings > Privacy & Security** may be needed to read protected locations; it does not guarantee complete coverage of every protected path. Without it, the app reports unreadable locations. A partial scan is not a complete view of your disk.

No networking code is present in the app. Scanning and filtering run locally.

Continue with the [visual tour](tour.md).
