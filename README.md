# ShotDrop

Every screenshot is instantly copied AND saved exactly where you want it.

ShotDrop is a Swift 6 menu bar app for macOS 14 and later. The current M0
scaffold provides the app shell, settings skeleton, launch-at-login control,
and hosted unit tests. A filesystem-first screenshot detection service is implemented
and tested with synthetic images, but is not yet activated by the app. A source-preserving
organization service provides verified copies, naming templates, date folders, and collision
handling. Automatic clipboard copying, the complete app pipeline, history, and floating
previews are not implemented yet. See
[the roadmap](docs/ROADMAP.md) for remaining work.

## Development

Install Xcode with the macOS SDK and Swift 6 support, select it with Xcode's
Settings > Locations > Command Line Tools, and install
[XcodeGen](https://github.com/yonaskolb/XcodeGen). Apple Silicon is the primary
development platform. No third-party runtime dependencies are required.

Run commands from the repository root:

```sh
make generate  # Generate ShotDrop.xcodeproj from project.yml
make build     # Generate and build the Debug app
make test      # Generate and run hosted XCTest tests
make run       # Build and open the menu bar app
make clean     # Remove only this repository's build directory
```

`project.yml` is the source of truth; the generated `.xcodeproj` is ignored by
Git. Run `make generate` after adding files or changing target settings. Build
products and test results are under `build/`. The app is at
`build/Build/Products/Debug/ShotDrop.app`.

The equivalent build command is:

```sh
xcodegen generate
xcodebuild -project ShotDrop.xcodeproj -scheme ShotDrop -configuration Debug -derivedDataPath build build
```

ShotDrop uses `LSUIElement`, so it appears in the menu bar without a Dock icon.
Use its menu to open settings or quit. M0 does not watch the Desktop or request
Screen Recording access. Launch at login uses macOS `SMAppService`; registration
may need approval in System Settings > General > Login Items. A stable app
location and signing identity are recommended when checking login behavior.

## Local signing

The default configuration uses ad-hoc signing, allowing local builds without
a configured development team. Ad-hoc rebuilds can invalidate macOS permission
grants; do not use them to evaluate persistent file-access permissions.

For stable development signing, add your Apple account to Xcode, create an Apple
Development certificate, and create the gitignored `Config/Local.xcconfig`:

```xcconfig
DEVELOPMENT_TEAM = YOUR_TEAM_ID
CODE_SIGN_STYLE = Automatic
CODE_SIGN_IDENTITY = Apple Development
```

`Config/Base.xcconfig` includes that file when present. Keep team-specific signing
details out of tracked files. Distribution signing and notarization are future
work; these commands produce a local development build.

## Checks

After `make test`, launch the app and check that its menu opens, settings can be
reopened, and Quit exits cleanly. Test login registration only when intentionally
changing your Login Items, then restore the previous setting. Passing unit tests
does not establish actual login behavior or future screenshot permission behavior.

The original geometric placeholder icon is in `Resources/Assets.xcassets`.
Regenerate it with `python3 Resources/generate_icon.py`; no network or image
generation service is involved.

Built by a MacFleet Codex team. Contributor coordination starts with
[AGENTS.md](AGENTS.md) and [PROMPTS.md](PROMPTS.md).
