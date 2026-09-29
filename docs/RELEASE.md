# Distribution checklist

Local development builds are separate from a notarized public release.

- Build Release with `xcodebuild -project ShotDrop.xcodeproj -scheme ShotDrop -configuration Release -derivedDataPath build-release build`.
- Use a Developer ID Application identity and hardened runtime for distribution.
  Development signing is for local use, not public distribution.
- Verify with `codesign --verify --deep --strict --verbose=2 ShotDrop.app`.
- Package with `ditto -c -k --keepParent ShotDrop.app ShotDrop.zip`.
- With the owner's configured Keychain notary profile, submit the archive using
  `xcrun notarytool submit ShotDrop.zip --keychain-profile PROFILE --wait`.
- Staple the accepted ticket with `xcrun stapler staple ShotDrop.app`, then validate
  the ticket and Gatekeeper assessment on a downloaded copy on another Mac.
- Before publishing, exercise fresh setup, folder denial/recovery, launch at login,
  native capture commands, restart, sleep/wake, clipboard consumers and VoiceOver
  on macOS 14 and the current macOS release. Check at least one multiple-display
  setup and pinned-window behavior in Spaces/fullscreen.

A notarized production release requires the owner's distribution identity/profile.
The 0.1.1 preview package includes a universal macOS DMG (Apple Silicon and Intel; macOS 14+). It is Apple Development signed and is not notarized. Gatekeeper may block it on other Macs. Do not describe this preview as a notarized production release. Local signing settings, build outputs, and user screenshots are excluded from source control.
