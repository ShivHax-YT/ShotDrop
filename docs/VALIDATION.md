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


## September 29 setup and thumbnail follow-up

The installed Settings window reproduced “Finish Setup…” alongside “Ready”.
Settings now hides that onboarding action after recorded completion; Setup remains
accessible from the library/menu. The repaired Release build was installed and
visually verified with the button absent and all existing user preferences retained.
Capture → Screen produced a new native PNG, the original remained in place, and
the saved copy matched its bytes (SHA-256 comparison). History reported successful
saving and copying, and the saved image opened in Preview.

The thumbnail timeout is now seven idle seconds followed by a 250 ms opacity fade
(120 ms with Reduce Motion). Hover, keyboard focus, menus, dragging, and in-progress
actions retain the preview; leaving that interaction starts a fresh seven-second
idle interval. Fade cleanup owns the departing panel so it cannot dismiss a new
capture. Thumbnail open/copy/reveal actions are connected to verified saved-file
actions, with manual clipboard intent protected from automatic capture publication.

80 focused automated checks passed across preferences, setup, processing, history,
thumbnail identity/OCR/policy, and file actions. Live timing, thumbnail actions, and
clipboard-consumer checks for the final thumbnail build are pending Desktop 2
confirmation. No public release asset has been changed by this follow-up.
