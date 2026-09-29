# ShotDrop local validation — 2026-09-25

Work performed in the existing repository by one agent, without workers or hooks.
The recovered `7b4e42f` source is the baseline of `codex/shotdrop-finish`.

## Observed native behavior

- Reproduced the installed app's original step-3 dead end, including the
  “Saving is paused” screen with only View Setup Details.
- Rebuilt with the existing Apple Development team; installed to
  `/Applications/ShotDrop.app`, preserving the previous app as a hidden rollback copy.
- Advanced repaired setup through destination/source checks to step 4 with Done
  enabled. Restarted into the ready library instead of onboarding.
- Created an explicitly synthetic 1600×840 test image with screenshot metadata in
  the confirmed source folder. The installed detector processed it automatically.
  Source and saved-copy SHA-256 matched, and history recorded save/copy success.
- Exercised Copy Text: the native UI reported Text copied for the generated text.
- Exercised Pin, manager Show, annotation Rectangle creation, and Save & Copy.
  Export existed, differed from the original, and history recorded save/copy success.
- Native inspection exposed a collapsed pin viewport and stale history after
  annotation export. Both were repaired and the pin viewport received a native
  layout regression assertion.
- Pause and Resume changed the actual runtime state and returned to Ready.
- A sampled idle development process reported 0.0% CPU and approximately 118 MiB
  RSS after editor/pin use. This is a point observation, not a sustained benchmark.

## Automated evidence

The test suite exercises source preservation, exclusive publication/collisions,
changed-source rejection, symlink/traversal rejection, temporary-file cleanup,
metadata retention, date folders, real FSEvents-to-save-to-private-pasteboard,
production setup advancement, direct annotation export, PNG variants, OCR,
pinned geometry and lifecycle, history, and cancellation/race behavior.

- Full run: 514 tests, zero failures, including the legacy 10,000-transaction stress test.
- After adding chronological-history and deduplication-capacity regressions: 515 tests,
  zero failures. Only the unchanged 10,000-transaction test was omitted from this rerun.
- Debug and Release builds succeeded with Apple Development signing.
- Test logs: `/tmp/shotdrop-final-test.log`, `/tmp/shotdrop-final-regression2.log`.
  Release log: `/tmp/shotdrop-release-final.log`. Xcode result bundles are in
  `build/Logs/Test/`.
- `git diff --check` passed.

## Limits of this evidence

The first live image was a generated fixture. A separate native macOS file,
`Screenshot 2026-09-25 at 1.24.00 AM.png`, appeared during the session and was also
processed: save/copy history outcomes were successful and the destination SHA-256
matched its original. The exact shortcut/selector interaction was not observable
through the app-bound computer-use surface, so shortcut-to-file latency is not
established. No claim is made about all
clipboard-consuming applications, drag-out destinations, VoiceOver speech,
physical multi-display/Spaces/fullscreen behavior, denied TCC on a fresh account,
login after an actual reboot, macOS 14 runtime, or external volumes.

Optional capture commands use the system capture utility and may require macOS
Screen Recording approval. Local signing/build success is not notarization or
public distribution acceptance; see RELEASE.md.

## Final installed Release check

The signed Release build passed strict/deep codesign verification, launched from
`/Applications/ShotDrop.app`, and reopened into Ready with existing history in
chronological order. The repaired pin was shown again: its image and all controls
were visibly present. The verification pin was then closed, leaving the library ready.


## September 29 setup and thumbnail follow-up (0.1.1)

The installed Settings window reproduced “Finish Setup…” alongside “Ready”.
Settings now hides that onboarding action after recorded completion; Setup remains
accessible from the library/menu. The final 0.1.1 (2) Release build was installed
and visually verified with the button absent and all existing preferences retained.

The thumbnail now waits seven idle seconds and fades over 250 ms (120 ms with
Reduce Motion). Hover, keyboard focus, menus, dragging, and in-progress actions
retain the preview; leaving interaction starts a fresh idle interval. Fade cleanup
owns the departing panel so it cannot dismiss a newer capture. Native testing
found that passive SwiftUI logical focus incorrectly retained the preview forever.
Retention and the focus ring now require actual key-window ownership.

On the final installed build, Capture → Screen produced a native screenshot at
12:04:28 PDT. The original remained in place, history reported successful copy
and save, and both files were 1,535,595 bytes with SHA-256
`c3a9db73bb9ac82baab36de1a2b18f03c039a679b548c4ead12966267edc371b`.
The floating preview was visibly present without a false focus ring. App logs
recorded presentation at 12:04:29.487, fade start at 12:04:36.543, and completion at
12:04:36.801: 7.056 seconds visible before a 258 ms fade. The next native inspection
showed the library, with the thumbnail gone. Settings then showed copied/saved
success and no Finish Setup prompt. Timing evidence comes from the native AppKit
animation lifecycle, not a frame-by-frame recording.

The preceding native pass verified that the thumbnail's Open Screenshot action
opened the saved image in Preview. Preview's New from Clipboard produced the same
full-resolution 2940 × 1912 image; the temporary verification document was saved
locally and closed. Thumbnail file actions now offer Open Recents after a verified
file becomes unavailable, while cached preview pixels remain copyable. Recovery
is covered by a real missing-file regression test; Return/Space handling and
semantic keyboard focus colors were added, but full keyboard/VoiceOver acceptance
is not claimed.

80 focused automated checks passed across preferences, setup, processing, history,
thumbnail identity/OCR/policy, and file actions after the focus fix. After the
recovery/keyboard changes, the relevant 21 checks passed again; these overlap the
80, rather than representing 101 distinct tests. The final universal Release build
and strict/deep signature verification passed.

The final DMG passed integrity verification and was mounted read-only without
opening Finder. Its app reported 0.1.1, contained arm64 and x86_64 binaries, passed
strict/deep signature verification, and matched the installed Release executable
SHA-256 `0f35f91cdd6d2fff4342aa91b7353dfa6db09e3b224821003516c3b677b5e6a6`.
The volume contained ShotDrop.app and the Applications shortcut and was detached.
DMG SHA-256: `e10f2db524385a5a8433dc30675bbf8bc2c42346afc33c990567247c84336eff`.
This is an Apple Development signed preview, not a notarized production release.
The hardware, OS, fresh-account, and distribution limits above still apply.
