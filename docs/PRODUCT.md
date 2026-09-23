# ShotDrop — Product

> Every screenshot is instantly copied AND saved exactly where you want it.

## Pitch
macOS makes you choose: save a screenshot to a file, or copy it to the clipboard. ShotDrop does both, every time, automatically. Take a screenshot the normal way, paste it anywhere a second later, and still find it filed in the folder you picked with a useful name.

## Who it's for
Anyone who screenshots all day: students, devs filing bugs, traders sharing charts, people in Discord/Slack.

## MVP features (v1.0)
1. Auto-copy: every new system screenshot (Cmd+Shift+3/4/5) is put on the clipboard as an image within ~300 ms.
2. Auto-save to a folder of the user's choice, with optional subfolders by date (YYYY/MM).
3. Smart rename templates: `{app}-{date}-{time}`, `{date} {time}`, custom. `{app}` = frontmost app when the shot was taken.
4. Floating thumbnail (bottom-right, like the system one) you can drag into any app, click to open, or swipe away.
5. Menu bar app with recent screenshots (last 20), quick copy/reveal/delete.
6. Settings: folder picker, rename template, what to copy (image / file / both), launch at login, sound on/off.
7. Onboarding that explains the Desktop/Documents folder permission prompt before macOS shows it.

## v1.1+
- Quick annotate window: arrow, rectangle, visual blur, text, and reversible crop. Explicit Save Copy or Save & Copy creates a separate verified PNG; ordinary close never copies. Production saving remains gated on the reviewed shared export path.
- OCR: "Copy text from screenshot" (Vision framework, on-device).
- Own capture hotkeys (region/window/fullscreen) using ScreenCaptureKit, as an alternative to the system shortcuts.
- Pin screenshot as a floating always-on-top window.
- Auto-delete originals from Desktop after moving (optional).

## Non-goals
Cloud upload, accounts, screen recording video (maybe later).

## UX principles
Use sensible defaults on supported local setups (folder: ~/Pictures/ShotDrop, template `{app}-{date}-{time}`). If the default folder cannot be safely prepared or verified, saving pauses and the original screenshot stays in place. A local-folder policy does not prove that an unrelated sync app is absent.
