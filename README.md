# VM Re-Sizer

A native macOS app to frame existing side-by-side stereo photos for View-Master-style reels. Each eye scales around its center using the same transform. The preview has approximate curved corners; exports are rectangular.

## Install

Download **VM-Re-Sizer-macOS.zip** from [the latest release](https://github.com/TedInVR/VMReSizer/releases/latest), unzip, and drag **VM Re-Sizer.app** to **Applications**. Open it once to register its background updater. Requires macOS 13+, supports Apple Silicon and Intel. Apple Command Line Tools are needed only if private GitHub access must be saved using Apple's Git Keychain helper; existing GitHub CLI logins can also be reused.

This personal app is ad-hoc signed, not Developer ID notarized. macOS may require allowing its first launch in Privacy & Security.

## Use

Import or drop a full-width side-by-side image. Fit Entire Image adds padding; Fill Frame crops to fill. Both eyes always stay linked and centered. Swap left/right for cross-eyed source order. Half-width SBS should be expanded before import. Odd-width inputs are rejected to avoid uneven eye images.

Choose either or both export sizes:

- Full resolution: approximately one source pixel per output pixel. Zooming out adds canvas; zooming in crops it. Output dimensions change with framing; the 1112:955 ratio is rounded to the nearest pixel.
- Image3D: exactly 1112 × 955 pixels per eye.

JPEG maximum quality or PNG lossless. Every operation creates a new folder of separate Left/Right files. Square output corners contain the chosen background. Source files are unchanged. Color is converted to sRGB. Source disparity scales with zoom; the app does not reconverge the stereo pair.

## Updates

**Help > Check for Updates** checks private GitHub releases and queues a newer version. Downloads and installation wait for app exit. Exporting prevents quitting until the export completes.

**Automatic Updates** is enabled by default and can be disabled in Help. A per-user LaunchAgent runs every 900 seconds while awake and signed into a graphical session. It performs no network checks, downloads, or installation while the app is running. When the network is unavailable it retries on a later scheduled run. A manual request works even with automatic updates disabled. Installation leaves the app closed.

A process lock excludes simultaneous installation and application use. If launched during the brief background check/install, the app asks to reopen when that operation finishes. Downloads go under Application Support, not Downloads. SHA-256, app identifier, version and ad-hoc signature integrity are checked. Failed replacement restores the old app. The app remains at its current location, preserving Dock shortcuts. Keep it in Applications.

The repository stays private. GitHub CLI credentials and existing Git Keychain credentials are tried automatically. If those lack access, use **Help > Connect GitHub** and provide a fine-grained token restricted to this repository with **Contents: Read-only**. It is validated and saved through Apple's signed Keychain credential helper, not in plaintext settings. Tokens are never embedded in builds, source, logs or command arguments. Reconnect if a token expires. No token is needed in GitHub Actions; it uses its temporary built-in repository token.

Update state and logs: `~/Library/Application Support/VM Re-Sizer/`.
Agent: `~/Library/LaunchAgents/com.tedwhitten.vmresizer.updater.plist`.
Development source is bundled under `Contents/Resources/Development` and copied to `VM Re-Sizer Development/<version>` beside the installed app. Existing version directories are retained; the installed app does not run development source.

## Development and releases

Edit the source in this repository, increment both version entries in `Info.plist`, update `RELEASE_NOTES.md`, and commit to `main`. GitHub Actions tests real exports and update safeguards on macOS, builds both architectures, verifies the code signature, and publishes an immutable versioned release with an archive and checksum. Existing release versions are never overwritten. The updater only uses published stable releases.

Local commands:

```sh
bash scripts/test.sh
bash scripts/build.sh
```

Keyboard shortcuts are listed in Help. Custom shortcut editing is not yet implemented. The rounded frame guide is approximate; it is not a measured Image3D die-cut template.
