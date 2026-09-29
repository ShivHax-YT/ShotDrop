# ShotDrop

Copy and save screenshots automatically, without removing the originals.

ShotDrop is a local Swift 6 menu bar app for macOS 14 and later, using SwiftUI,
AppKit, ImageIO and Vision. There are no accounts, uploads or runtime dependencies.

## Use

1. Open ShotDrop and choose a save folder (default: `~/Pictures/ShotDrop`).
2. Confirm the folder used by macOS screenshots. Allow folder access if macOS asks.
3. Continue to Verify, then Done. The app starts watching for new screenshots.
4. Use the usual Shift–Command–3/4/5 shortcuts. Finalized screenshot files are
   copied to your chosen folder and published to the clipboard.

Existing files are excluded at startup. macOS's floating screenshot thumbnail can
hold a capture for several seconds before making the file available to ShotDrop.
Clipboard-only macOS captures do not create a source file and are not watched.

Features:
- Image, file, or combined clipboard contents; PNG, JPEG and HEIC image preparation.
- Safe names using `{app}`, `{date}` and `{time}`, collision suffixes and optional
  year/month folders. The original stays untouched, including on failure.
- Floating preview with a seven-second idle timeout and smooth fade, drag-out, recent 20 captures, copy/open/reveal, retry failed
  saves, and confirmed Move Saved Copy to Trash.
- On-device OCR, pinned windows (up to three), and annotation editors with arrow,
  rectangle, highlight, pixelation, visual blur, text, crop, undo/redo and separate
  Save Copy / Save & Copy export. Blur/pixelation are visual effects, not a secure
  redaction guarantee.
- Pause/resume, sleep/wake handling, optional sound and launch at login.
- Capture menu with screen, selection and window commands. Optional global
  Control–Option–3/4/5 shortcuts use the native system capture utility; macOS may
  require Screen Recording access for these commands. System shortcuts remain usable.

Opening the app after completed setup shows the library. Setup remains available
from its menu for changing folders. Settings changes to the destination pause
processing and reopen setup so the new folder is checked.

## Storage and limits

The production writer uses exclusive temporary files inside the chosen destination,
verifies bounded bytes, preserves screenshot metadata, and atomically publishes
without overwriting existing files. Temporary files are removed on handled failure.
A crash can leave a hidden `.shotdrop-*.tmp` in the destination; these files are not
replayed or automatically deleted. Legacy staging registries and files are preserved
and are no longer prerequisites for production saving.

Folder setup currently admits supported local APFS destinations. External/provider
volume compatibility is not claimed. Encoded files are limited to 64 MiB; OCR and
annotation decoding have additional pixel/memory bounds. `{app}` is sampled when a
ready capture is processed; macOS does not provide its original foreground app.

## Build and test

Xcode 27/Swift 6 tooling and XcodeGen are used for development. The deployment target
remains macOS 14. `project.yml` is the project source of truth.

```sh
make generate
make build
make test
make run
```

The local build is `build/Build/Products/Debug/ShotDrop.app`. Configure stable
Apple Development signing in ignored `Config/Local.xcconfig`. Ad-hoc rebuilds may
invalidate folder-access grants. No credentials belong in tracked files.

See [validation](docs/VALIDATION.md) for observed evidence and remaining platform
checks, and [release notes](docs/RELEASE.md) for distribution steps.

## Download

Download the DMG from [GitHub Releases](https://github.com/ShivHax-YT/ShotDrop/releases). The v0.1.0 preview supports macOS 14+ and contains Apple Silicon and Intel binaries. It is development signed, **not notarized**, and may be blocked by Gatekeeper on another Mac. See [release requirements](docs/RELEASE.md) and [validation coverage](docs/VALIDATION.md).
