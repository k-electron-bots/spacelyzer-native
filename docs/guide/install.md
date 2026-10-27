# Install and permissions

## Requirements
macOS 14 or later. Spacelyzer is early software (version 0.9.x); see [verification status](../verification/README.md) before relying on it for important cleanup.

## Install from the DMG
1. Download the latest DMG from [GitHub releases](https://github.com/k-electron-bots/spacelyzer-native/releases).
2. Open the DMG. You get one window: the app on the left, your Applications folder on the right.
3. Drag Spacelyzer onto Applications.

![The install window: drag Spacelyzer onto Applications](../images/install-dmg-window.png)

Captured on a shared CI Mac from the 0.9.0 DMG in [run 40507867386](https://github.com/k-electron-bots/spacelyzer-native/actions/runs/40507867386) (the DMG install check on the tested commit de2d6e2; its title bar shows version 0.9.0). The window is shown as the CI Mac rendered it, not a personal Mac.

## First launch
The build is self-signed, not notarized, so macOS blocks the first open. On macOS 14 and later (steps verified against the macOS 14+ Gatekeeper flow):

1. Try to open the app once. macOS shows a warning and does not open it.
2. Go to **System Settings > Privacy & Security**.
3. Under Security, choose **Open Anyway** for Spacelyzer. macOS may ask for your login password.

Do not disable Gatekeeper or clear quarantine flags. Diagnostic builds are not a substitute for a release-readiness gate.

## Protected folders
Full Disk Access in **System Settings > Privacy & Security** may be needed to read protected locations; it does not guarantee complete coverage of every protected path. Without it, the app reports unreadable locations. A partial scan is not a complete view of your disk.

![The in-app banner shown when Full Disk Access is missing](../images/install-fda-banner.png)

Captured October 2026 on a CI Mac (run 39947043378) from the test-only build over a disposable sample folder; window-only capture. The banner sits below the filter controls.

No networking code is present in the app. Scanning and filtering run locally.

Continue with the [quick start](quick-start.md).
