VM Re-Sizer 0.2.0

- Native universal Mac app for Apple Silicon and Intel, macOS 13 or later.
- Linked stereo framing, background colors, separate full-resolution and Image3D exports.
- Help > Check for Updates queues a new release for installation after quitting.
- Automatic checking, download and installation every 15 minutes while the Mac is awake, signed in, online, and this app is closed. Automatic Updates can be disabled.
- GitHub repository and releases stay private. Existing local GitHub credentials are tried first; Help > Connect GitHub stores a read-only token in macOS Keychain if needed.
- Updates verify SHA-256, app identity, version, and code-signature integrity, preserve the installed path, and leave the app closed.
- Development source is included in the app and copied to a versioned folder beside it.

First installation: unzip VM-Re-Sizer-macOS.zip, drag VM Re-Sizer.app into Applications, and open it. Future releases install through the app's updater.

This personal build uses an ad-hoc code signature, not Apple Developer ID notarization. macOS may require allowing its first launch in Privacy & Security. Rounded preview corners are an approximate guide.
