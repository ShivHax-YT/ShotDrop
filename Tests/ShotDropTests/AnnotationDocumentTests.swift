import Foundation
import XCTest
@testable import ShotDrop

final class AnnotationDocumentTests: XCTestCase {
    func testDimensionsRejectOverflowAndPixelBudget() throws {
        for dimensions in [(0, 1), (1, 0), (-1, 2), (Int.max, Int.max), (8001, 4000)] {
            XCTAssertThrowsError(try AnnotationDocument(width: dimensions.0, height: dimensions.1))
        }
        let document = try AnnotationDocument(width: 8000, height: 4000)
        XCTAssertEqual(document.state.crop, document.extent)
        XCTAssertFalse(document.isDirty)
    }

    func testCropUndoRedoRestoresHiddenMarksAndDivergenceClearsRedo() throws {
        var document = try AnnotationDocument(width: 100, height: 100)
        var state = document.state
        state.marks = [mark(.rectangle)]
        try document.commit(state)
        let original = document.state
        state.crop = CGRect(x: 50, y: 50, width: 30, height: 30)
        try document.commit(state)
        XCTAssertEqual(document.state.marks, original.marks, "Crop must preserve objects outside its bounds")
        document.undo()
        XCTAssertEqual(document.state, original)
        document.redo()
        XCTAssertEqual(document.state, state)
        document.undo()
        var divergent = document.state
        divergent.crop = CGRect(x: 0, y: 0, width: 10, height: 10)
        try document.commit(divergent)
        XCTAssertTrue(document.redoStates.isEmpty)
        let revision = document.revision
        document.redo()
        XCTAssertEqual(document.state, divergent)
        XCTAssertEqual(document.revision, revision)
    }

    func testSaveRequiresExactRevisionAndDirtyTracksUndoToSavedContent() throws {
        var document = try AnnotationDocument(width: 100, height: 100)
        var state = document.state
        state.marks = [mark(.text)]
        try document.commit(state)
        let savedRevision = document.revision
        try document.markSaved(revision: savedRevision)
        XCTAssertFalse(document.isDirty)
        state.marks[0].text = "Changed"
        try document.commit(state)
        XCTAssertThrowsError(try document.markSaved(revision: savedRevision)) {
            XCTAssertEqual($0 as? AnnotationFailure, .stale)
        }
        XCTAssertTrue(document.isDirty)
        document.undo()
        XCTAssertFalse(document.isDirty)
        XCTAssertGreaterThan(document.revision, savedRevision)
        document.redo()
        XCTAssertTrue(document.isDirty)
    }

    func testUndoBudgetAndNoOpCommitDoNotDestroyRedo() throws {
        var document = try AnnotationDocument(width: 100, height: 100)
        var state = document.state
        state.marks = [mark(.text)]
        for index in 0..<150 {
            state.marks[0].text = String(index)
            try document.commit(state)
        }
        XCTAssertEqual(document.undoStates.count, AnnotationDocument.maximumUndo)
        for _ in 0..<110 { document.undo() }
        XCTAssertEqual(document.state.marks.first?.text, "49")
        XCTAssertEqual(document.redoStates.count, AnnotationDocument.maximumUndo)
        let revision = document.revision
        try document.commit(document.state)
        XCTAssertEqual(document.revision, revision)
        XCTAssertEqual(document.redoStates.count, AnnotationDocument.maximumUndo)
        for _ in 0..<110 { document.redo() }
        XCTAssertEqual(document.state.marks.first?.text, "149")
        XCTAssertEqual(document.undoStates.count, AnnotationDocument.maximumUndo)
    }

    func testInvalidCropCannotMutateDocumentOrHistory() throws {
        var document = try AnnotationDocument(width: 100, height: 100)
        let original = document.state
        let invalid = [CGRect.zero, CGRect(x: 0.5, y: 0, width: 10, height: 10),
                       CGRect(x: -1, y: 0, width: 10, height: 10),
                       CGRect(x: 90, y: 90, width: 11, height: 10),
                       CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10),
                       CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 10)]
        for crop in invalid {
            var state = original
            state.crop = crop
            XCTAssertThrowsError(try document.commit(state))
            XCTAssertEqual(document.state, original)
            XCTAssertEqual(document.revision, 0)
            XCTAssertTrue(document.undoStates.isEmpty)
        }
    }

    func testArrowDegeneracyAndNumericValidation() throws {
        let document = try AnnotationDocument(width: 100, height: 100)
        var state = document.state
        var arrow = mark(.arrow)
        arrow.end = arrow.start
        state.marks = [arrow]
        XCTAssertThrowsError(try document.validate(state))
        arrow.end.x += 0.5
        state.marks = [arrow]
        XCTAssertThrowsError(try document.validate(state))
        arrow.end.x += 0.5
        state.marks = [arrow]
        XCTAssertNoThrow(try document.validate(state), "One-pixel horizontal arrows are valid")
        for number in [Double.nan, Double.infinity, -Double.infinity] {
            var invalid = mark(.rectangle)
            invalid.start.x = CGFloat(number)
            state.marks = [invalid]
            XCTAssertThrowsError(try document.validate(state))
            XCTAssertTrue(invalid.accessibilityDescription.contains("invalid geometry"))
            invalid = mark(.rectangle)
            invalid.stroke = number
            state.marks = [invalid]
            XCTAssertThrowsError(try document.validate(state))
            invalid = mark(.rectangle)
            invalid.color.alpha = number
            state.marks = [invalid]
            XCTAssertThrowsError(try document.validate(state))
        }
    }

    func testMarkIdentityToolsAndLimits() throws {
        let document = try AnnotationDocument(width: 100, height: 100)
        var state = document.state
        let rectangle = mark(.rectangle)
        state.marks = [rectangle, rectangle]
        XCTAssertThrowsError(try document.validate(state))
        for tool in [AnnotationTool.select, .crop] {
            state.marks = [mark(tool)]
            XCTAssertThrowsError(try document.validate(state))
        }
        state.marks = (0..<100).map { _ in mark(.rectangle) }
        XCTAssertNoThrow(try document.validate(state))
        state.marks.append(mark(.rectangle))
        XCTAssertThrowsError(try document.validate(state)) {
            XCTAssertEqual($0 as? AnnotationFailure, .tooManyEdits)
        }
    }

    func testTextBudgetCountsUTF8AndAggregateBytes() throws {
        let document = try AnnotationDocument(width: 100, height: 100)
        var state = document.state
        var text = mark(.text)
        text.text = String(repeating: "é", count: 2048)
        state.marks = [text]
        XCTAssertNoThrow(try document.validate(state))
        state.marks[0].text.append("x")
        XCTAssertThrowsError(try document.validate(state))
        state.marks = (0..<16).map { _ in
            var object = mark(.text)
            object.text = String(repeating: "x", count: 4096)
            return object
        }
        XCTAssertNoThrow(try document.validate(state))
        state.marks.append(mark(.text))
        XCTAssertThrowsError(try document.validate(state)) {
            XCTAssertEqual($0 as? AnnotationFailure, .tooLarge)
        }
    }

    private func mark(_ tool: AnnotationTool) -> AnnotationMark {
        AnnotationMark(tool: tool, start: CGPoint(x: 1, y: 2), end: CGPoint(x: 20, y: 30))
    }
}
