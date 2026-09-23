# ShotDrop — Dev log

One line per finished item: `YYYY-MM-DD HH:MM | #queue-id | commit | what | gotchas`

2026-09-22 20:17 | #4, #5, #6 (M0) | 42abd10 | Added XcodeGen app/test targets, original placeholder icon, native menu/Settings shell, persisted preferences, opt-in SMAppService control, and make recipes. Debug build and all 9 XCTest tests passed; app launched and codesign verified. | GUI inspection timed out twice (-10005), so live menu/Settings/Quit acceptance remains with QA. Actual launch-at-login and stable-signing TCC persistence unverified. Xcode emitted an AppIntents metadata skip warning and the test host logged unavailable system linkd service diagnostics without test failure.
