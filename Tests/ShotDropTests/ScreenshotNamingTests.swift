import Foundation
import XCTest
@testable import ShotDrop

final class ScreenshotNamingTests: XCTestCase {
    private let instant = Date(timeIntervalSince1970: 1_735_691_445) // 2025-01-01 00:30:45 UTC.

    func testExpandsAllTokensAndKeepsLiteralText() throws {
        let plan = try makePlan(template: "{app} — {date} at {time}", appName: "Safari")
        XCTAssertEqual(plan.filename(collisionIndex: 0), "Safari — 2025-01-01 at 00-30-45.png")
        XCTAssertEqual(plan.directoryComponents, [])
    }

    func testMissingAndBlankAppNamesUseScreenshotFallback() throws {
        for name in [nil, "", " \t\n", ".", ".."] as [String?] {
            let plan = try makePlan(template: "{app}", appName: name)
            XCTAssertEqual(plan.stem, "Screenshot", "App name: \(String(describing: name))")
        }
    }

    func testSanitizesPathsControlsAndHiddenNames() throws {
        let plan = try makePlan(template: " .{app}. ", appName: "../A\\B:C\0D\nE")
        XCTAssertEqual(plan.stem, "-A-B-C-D-E")
        XCTAssertFalse(plan.filename(collisionIndex: 0).hasPrefix("."))
        for unsafe in ["/", "\\", ":", "\0", "\n"] {
            XCTAssertFalse(plan.stem.contains(unsafe))
        }
        for template in [".", "..", " ... "] {
            XCTAssertEqual(try makePlan(template: template).stem, "Screenshot")
        }
    }

    func testUnicodeAndJoinedEmojiArePreserved() throws {
        let name = "写真 Café e\u{301} 👩🏽‍💻"
        XCTAssertEqual(try makePlan(template: "{app}", appName: name).stem, name)
    }

    func testLongUnicodeNamesKeepWholeCharactersAndReserveCollisionBytes() throws {
        let grapheme = "👩🏽‍💻"
        let plan = try makePlan(template: String(repeating: grapheme, count: 100), sourceExtension: "JPEG")
        XCTAssertTrue(plan.stem.allSatisfy { String($0) == grapheme })
        for index in [0, 1, 98, 999_999, Int.max] {
            XCTAssertLessThan(plan.filename(collisionIndex: index).utf8.count, 255)
            XCTAssertTrue(plan.filename(collisionIndex: index).hasSuffix(".jpeg"))
        }
        XCTAssertEqual(plan.stem, try makePlan(
            template: String(repeating: grapheme, count: 100), sourceExtension: "JPEG"
        ).stem)
    }

    func testOversizedSingleGraphemeFallsBackToSafeStem() throws {
        let oversized = "A" + String(repeating: "\u{301}", count: 300)
        XCTAssertEqual(try makePlan(template: oversized).stem, "Screenshot")
    }

    func testCollisionNamesStartAtTwoAndSupportMaximumIndex() throws {
        let plan = try makePlan(template: "Capture")
        XCTAssertEqual(plan.filename(collisionIndex: 0), "Capture.png")
        XCTAssertEqual(plan.filename(collisionIndex: 1), "Capture (2).png")
        XCTAssertEqual(plan.filename(collisionIndex: 2), "Capture (3).png")
        XCTAssertEqual(plan.filename(collisionIndex: Int.max), "Capture (\(UInt(Int.max) + 1)).png")
        XCTAssertEqual(plan.filename(collisionIndex: -1), "Capture.png")
    }

    func testNormalizesSupportedExtensionsAndRejectsOtherValues() throws {
        for extensionName in ["PNG", "jpg", "JPEG", "HeIc"] {
            XCTAssertEqual(try makePlan(sourceExtension: extensionName).fileExtension, extensionName.lowercased())
        }
        for extensionName in ["", "gif", ".png", "png/../jpg", "png\0", " png"] {
            XCTAssertThrowsError(try makePlan(sourceExtension: extensionName)) { error in
                XCTAssertEqual(error as? ScreenshotNamingError, .unsupportedExtension(extensionName))
            }
        }
    }

    func testRejectsEmptyTemplates() {
        for template in ["", " \n\t"] {
            XCTAssertThrowsError(try makePlan(template: template)) { error in
                XCTAssertEqual(error as? ScreenshotNamingError, .emptyTemplate)
            }
        }
    }

    func testRejectsUnknownAndMalformedTokens() {
        for template in ["{year}", "{App}", "{}", "{\u{301}app}\u{301}"] {
            XCTAssertThrowsError(try makePlan(template: template)) { error in
                guard case .unknownToken = error as? ScreenshotNamingError else {
                    return XCTFail("Expected unknown token, received \(error)")
                }
                XCTAssertFalse(error.localizedDescription.isEmpty)
            }
        }
        for template in ["{date", "date}", "{{app}}", "{app}{", "}{"] {
            XCTAssertThrowsError(try makePlan(template: template)) { error in
                XCTAssertEqual(error as? ScreenshotNamingError, .unbalancedBraces)
            }
        }
    }

    func testAppNameIsNotRecursivelyExpandedAsTemplate() throws {
        XCTAssertEqual(try makePlan(template: "{app}", appName: "{date}").stem, "{date}")
    }

    func testDateDirectoriesAndTokensShareCaptureTimeZoneAtYearBoundary() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let plan = try ScreenshotNaming.plan(
            template: "{date}_{time}", sourceExtension: "png",
            context: ScreenshotNamingContext(appName: nil, capturedAt: instant, timeZone: zone),
            organizeByDate: true
        )
        XCTAssertEqual(plan.directoryComponents, ["2024", "12"])
        XCTAssertEqual(plan.stem, "2024-12-31_16-30-45")
    }

    private func makePlan(
        template: String = "{date}_{time}", appName: String? = nil, sourceExtension: String = "png"
    ) throws -> ScreenshotNamePlan {
        try ScreenshotNaming.plan(
            template: template, sourceExtension: sourceExtension,
            context: ScreenshotNamingContext(
                appName: appName, capturedAt: instant, timeZone: TimeZone(secondsFromGMT: 0)!
            ), organizeByDate: false
        )
    }
}
