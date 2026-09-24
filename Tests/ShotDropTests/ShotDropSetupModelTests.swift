import Foundation
import XCTest
@testable import ShotDrop

@MainActor
final class ShotDropSetupModelTests: XCTestCase {
    private let source = URL(fileURLWithPath: "/fixture/source", isDirectory: true)
    private let destination = URL(fileURLWithPath: "/fixture/destination", isDirectory: true)

    func testBusyLabelNamesActualDefaultPreparationAndClearsAfterCompletion() async {
        let preparer = SetupSuspendedPreparer(proposedDestination: destination)
        let model = ShotDropSetupModel(destinationURL: destination, service: SetupServiceFixture(), defaultPreparer: preparer)
        await model.continueSetup(); await model.continueSetup()
        model.confirmCurrentSource(true)
        XCTAssertEqual(model.busyOperationTitle, "Checking folder access…")
        let task = Task { await model.continueSetup() }
        for _ in 0..<1000 {
            if await preparer.isSuspended { break }
            await Task.yield()
        }
        XCTAssertTrue(model.isBusy)
        XCTAssertFalse(model.canPerformPrimaryAction)
        await model.performPrimaryAction(chooseDestination: { XCTFail("Busy picker") }, chooseSource: { XCTFail("Busy picker") })
        XCTAssertEqual(model.busyOperationTitle, "Preparing default folder…")
        await preparer.resume()
        await task.value
        XCTAssertFalse(model.isBusy)
        XCTAssertFalse(model.isPreparingDefaultFolder)
        XCTAssertNil(model.inlineStatusMessage)
        XCTAssertEqual(model.pausedResultMessage, DefaultDestinationPreparationResult.enrolledPaused.message)
    }

    func testInvalidDestinationRequiresPickerAndCannotRepeatCheckAtEitherStage() async {
        for issue in [ShotDropSetupAccessIssue.missing, .changed, .unsupported, .unsafe] {
            for atSource in [false, true] {
                let service = SetupServiceFixture()
                let model: ShotDropSetupModel
                if atSource {
                    model = await sourceStep(service: service)
                    await service.setSeparationFailure(issue)
                } else {
                    model = ShotDropSetupModel(destinationURL: destination, service: service)
                    await model.continueSetup()
                    await service.setDestinationFailure(issue)
                }
                await model.continueSetup()
                XCTAssertTrue(model.destinationRequiresReselection)
                XCTAssertFalse(model.canContinue)
                XCTAssertEqual(model.primaryTitle, "Choose Another Save Folder…")
                XCTAssertTrue(model.canPerformPrimaryAction)
                XCTAssertEqual(model.primaryAction, .chooseDestination)
                let before = await service.calls
                var pickerCalls = 0
                await model.performPrimaryAction(chooseDestination: { pickerCalls += 1 }, chooseSource: { XCTFail("Wrong picker") })
                XCTAssertEqual(pickerCalls, 1)
                XCTAssertFalse(model.canContinue, "Opening/cancelling a picker cannot authorize a recheck")
                await model.continueSetup()
                let after = await service.calls
                XCTAssertEqual(before, after)
                model.selectDestination(URL(fileURLWithPath: "/fixture/new-destination"))
                XCTAssertFalse(model.destinationRequiresReselection)
                XCTAssertTrue(model.canContinue)
            }
        }
    }

    func testInvalidSourceRequiresPickerAndCannotRepeatCheck() async {
        for issue in [ShotDropSetupAccessIssue.missing, .changed, .unsupported, .unsafe] {
            let service = SetupServiceFixture()
            let model = await sourceStep(service: service)
            await service.setSourceFailure(issue)
            await model.continueSetup()
            XCTAssertTrue(model.sourceRequiresReselection)
            XCTAssertFalse(model.canContinue)
            XCTAssertEqual(model.primaryTitle, "Select Current Screenshot Folder…")
            XCTAssertTrue(model.canPerformPrimaryAction)
            XCTAssertEqual(model.primaryAction, .chooseSource)
            let before = await service.calls
            var pickerCalls = 0
            await model.performPrimaryAction(chooseDestination: { XCTFail("Wrong picker") }, chooseSource: { pickerCalls += 1 })
            XCTAssertEqual(pickerCalls, 1)
            XCTAssertFalse(model.canContinue)
            model.confirmCurrentSource(true)
            await model.continueSetup()
            let after = await service.calls
            XCTAssertEqual(before, after)
            model.selectSource(source)
            model.confirmCurrentSource(true)
            XCTAssertTrue(model.canContinue)
        }
    }

    func testDestinationAccessAndAvailabilityRemainRetryable() async {
        for issue in [ShotDropSetupAccessIssue.denied, .unavailable] {
            let service = SetupServiceFixture()
            await service.setDestinationFailure(issue)
            let model = ShotDropSetupModel(destinationURL: destination, service: service)
            await model.continueSetup(); await model.continueSetup()
            XCTAssertFalse(model.destinationRequiresReselection)
            XCTAssertTrue(model.canContinue)
            XCTAssertEqual(model.primaryTitle, "Retry")
            await service.setDestinationFailure(nil)
            await model.continueSetup()
            XCTAssertEqual(model.step, .source)
            model.confirmCurrentSource(true)
            await service.setSeparationFailure(issue)
            await model.continueSetup()
            XCTAssertTrue(model.canContinue)
            XCTAssertEqual(model.primaryTitle, "Retry")
            await service.setSeparationFailure(nil)
            await model.continueSetup()
            XCTAssertTrue(model.showsPausedSetup)
        }
    }

    func testAlternateUnavailableReadinessHasStableDetailsAndSurvivesDeferral() async {
        let service = SetupServiceFixture()
        let gate = SetupGateFixture(destination: false, pipeline: false, review: false)
        let model = await sourceStep(service: service, gate: gate)
        await model.continueSetup()
        XCTAssertTrue(model.showsPausedSetup)
        XCTAssertNil(model.inlineStatusMessage)
        XCTAssertEqual(model.pausedResultMessage, model.pausedSetupMessage)
        XCTAssertFalse(model.canContinue)
        XCTAssertFalse(model.canRunTest)
        XCTAssertTrue(model.canPerformPrimaryAction)
        XCTAssertEqual(model.primaryAction, .details)
        await model.performPrimaryAction(chooseDestination: { XCTFail("Paused picker") }, chooseSource: { XCTFail("Paused picker") })
        XCTAssertTrue(model.isShowingSetupDetails)
        let before = await service.calls
        await model.continueSetup()
        model.notNow(); model.reopen()
        XCTAssertTrue(model.showsPausedSetup)
        XCTAssertEqual(model.statusMessage, model.pausedSetupMessage)
        await model.continueSetup()
        let after = await service.calls
        XCTAssertEqual(before, after)
        let count = await gate.count
        XCTAssertEqual(count, 1)
        XCTAssertFalse(model.canRunTest)
    }

    func testDurableReviewRestoreNeverPreparesOrApprovesAndSurvivesReopen() async {
        for result in [DefaultDestinationPreparationResult.reviewRequired, .enrolledPaused, .reservedRecovery] {
            let preparer = SetupDefaultPreparerFixture(proposedDestination: destination, result: result, reviewResult: result)
            let model = ShotDropSetupModel(destinationURL: destination, defaultPreparer: preparer)
            await model.restoreReviewState()
            XCTAssertEqual(model.defaultPreparationResult, result)
            XCTAssertTrue(model.showsPausedSetup)
            XCTAssertFalse(model.canRunTest)
            model.notNow(); model.reopen()
            XCTAssertEqual(model.defaultPreparationResult, result)
            await model.continueSetup()
            let count = await preparer.count
            XCTAssertEqual(count, 0)
            XCTAssertFalse(model.canRunTest)
        }
    }

    func testDefaultPreparationRequiresConfirmationAndAlwaysKeepsProcessingPaused() async {
        for result in [DefaultDestinationPreparationResult.enrolledPaused, .reviewRequired,
                       .reservedRecovery, .unreservedRecovery, .missingPictures, .unsupported, .retryable,
                       .cloudStatusUnknown, .providerStatusUnknown] {
            let preparer = SetupDefaultPreparerFixture(proposedDestination: destination, result: result)
            let model = ShotDropSetupModel(destinationURL: destination, service: SetupServiceFixture(),
                                           gate: SetupGateFixture.approved, defaultPreparer: preparer)
            await model.continueSetup()
            await model.continueSetup()
            XCTAssertEqual(model.step, .source)
            await model.continueSetup()
            let before = await preparer.count
            XCTAssertEqual(before, 0)
            model.confirmCurrentSource(true)
            await model.continueSetup()
            let after = await preparer.count
            XCTAssertEqual(after, 1)
            XCTAssertEqual(model.defaultPreparationResult, result)
            XCTAssertEqual(model.statusMessage, result.message)
            if result == .cloudStatusUnknown { XCTAssertTrue(model.statusMessage?.contains("iCloud") == true) }
            if result == .providerStatusUnknown { XCTAssertTrue(model.statusMessage?.contains("storage provider") == true) }
            if result == .cloudStatusUnknown || result == .providerStatusUnknown {
                XCTAssertTrue(result.message.contains("Pictures folder"))
                XCTAssertTrue(result.message.contains("default-location eligibility"))
                XCTAssertFalse(result.message.contains("this folder"))
            }
            if !result.permitsRetry {
                XCTAssertNil(model.inlineStatusMessage)
                XCTAssertEqual(model.pausedResultMessage, result.message)
            }
            XCTAssertEqual(model.canContinue, result.permitsRetry)
            XCTAssertEqual(model.showsPausedSetup, !result.permitsRetry)
            let expectedLabel: String
            switch result {
            case .enrolledPaused: expectedLabel = "Prepared default · Saving paused"
            case .reservedRecovery, .unreservedRecovery: expectedLabel = "Default folder kept for review"
            default: expectedLabel = "Proposed default"
            }
            XCTAssertEqual(model.destinationStatusLabel, expectedLabel)
            XCTAssertFalse(model.canRunTest)
            XCTAssertEqual(model.step, .source)
            model.showSetupDetails()
            XCTAssertEqual(model.isShowingSetupDetails, !result.permitsRetry)
            XCTAssertEqual(result.detailsActionTitle, result == .unsupported ? "View Requirements…" : "View Setup Details…")
            XCTAssertFalse(result.reviewGuidance.isEmpty)
            XCTAssertFalse(model.canRunTest)
            XCTAssertEqual(model.defaultPreparationResult, result)
            model.dismissSetupDetails()
            XCTAssertFalse(model.isShowingSetupDetails)
            if !result.permitsRetry {
                await model.continueSetup()
                let unchangedCount = await preparer.count
                XCTAssertEqual(unchangedCount, 1)
                model.showSetupDetails()
                model.notNow()
                XCTAssertFalse(model.isShowingSetupDetails)
                XCTAssertTrue(model.isDeferred)
                XCTAssertFalse(model.isPresented)
                XCTAssertFalse(model.canRunTest)
                model.reopen()
                XCTAssertFalse(model.isShowingSetupDetails)
                XCTAssertFalse(model.canRunTest)
            }
        }
    }

    func testFailedSourceAccessNeverPreparesDefault() async {
        let service = SetupServiceFixture()
        await service.setSourceFailure(.changed)
        let preparer = SetupDefaultPreparerFixture(proposedDestination: destination, result: .enrolledPaused)
        let model = ShotDropSetupModel(destinationURL: destination, service: service, defaultPreparer: preparer)
        await model.continueSetup()
        await model.continueSetup()
        model.confirmCurrentSource(true)
        await model.continueSetup()
        let count = await preparer.count
        XCTAssertEqual(count, 0)
        XCTAssertEqual(model.sourceIssue, .changed)
        XCTAssertTrue(model.canPerformPrimaryAction)
        var sourcePickerCalls = 0
        await model.performPrimaryAction(chooseDestination: { XCTFail("Wrong picker") }, chooseSource: { sourcePickerCalls += 1 })
        XCTAssertEqual(sourcePickerCalls, 1)
        let afterPicker = await preparer.count
        XCTAssertEqual(afterPicker, 0, "The recovery CTA must not prepare default storage")
        model.showSetupDetails()
        XCTAssertFalse(model.isShowingSetupDetails)
    }

    func testSelectionAndWelcomeDoNotRequestAccess() async {
        let service = SetupServiceFixture()
        let model = ShotDropSetupModel(service: service)
        model.selectDestination(destination)
        model.selectSource(source)
        model.confirmCurrentSource(true)
        model.reopen()
        await model.continueSetup()
        XCTAssertEqual(model.step, .destination)
        let calls = await service.calls
        XCTAssertEqual(calls, [])
        XCTAssertFalse(model.sourceConfirmedByUser)
    }

    func testPendingDestinationCanReachSourceButNeverTestWithDefaultGate() async {
        let service = SetupServiceFixture()
        let model = await sourceStep(service: service)
        XCTAssertTrue(model.destinationNeedsReview)
        XCTAssertTrue(model.canContinue)
        model.confirmCurrentSource(true)
        await model.continueSetup()
        XCTAssertEqual(model.step, .source)
        XCTAssertFalse(model.canRunTest)
        XCTAssertTrue(model.statusMessage?.contains("Automatic copying and saving are not available") == true)
        let calls = await service.calls
        XCTAssertEqual(calls, ["destination", "discover", "source", "destinationWithSource"])
    }

    func testRecordedSourcePreferenceDoesNotCountAsUserConfirmationOrReadAccess() async {
        let service = SetupServiceFixture()
        let model = ShotDropSetupModel(destinationURL: destination, service: service)
        await model.continueSetup()
        await model.continueSetup()
        XCTAssertEqual(model.sourceURL, source)
        XCTAssertFalse(model.sourceConfirmedByUser)
        XCTAssertFalse(model.canContinue)
        await model.continueSetup()
        let calls = await service.calls
        XCTAssertEqual(calls, ["destination", "discover"])
        model.confirmCurrentSource(true)
        XCTAssertTrue(model.canContinue)
    }

    func testEveryIndependentGateIsRequired() async {
        for mask in 0..<8 {
            let service = SetupServiceFixture()
            let gate = SetupGateFixture(destination: mask & 1 != 0,
                                        pipeline: mask & 2 != 0, review: mask & 4 != 0)
            let model = await sourceStep(service: service, gate: gate)
            model.confirmCurrentSource(true)
            await model.continueSetup()
            XCTAssertEqual(model.step, mask == 7 ? .test : .source, "mask \(mask)")
            XCTAssertEqual(model.canRunTest, mask == 7, "mask \(mask)")
        }
    }

    func testFullyTrueGateForDifferentFoldersDoesNotAuthorizeTest() async {
        let gate = SetupGateFixture(destination: true, pipeline: true, review: true, mismatched: true)
        let model = await sourceStep(gate: gate)
        model.confirmCurrentSource(true)
        await model.continueSetup()
        XCTAssertEqual(model.step, .source)
        XCTAssertFalse(model.canRunTest)
    }

    func testDoneOnlyClosesAndReopenInvalidatesReadinessButRetainsDraft() async {
        let service = SetupServiceFixture()
        let model = await sourceStep(service: service, gate: SetupGateFixture.approved)
        model.confirmCurrentSource(true)
        await model.continueSetup()
        XCTAssertEqual(model.primaryTitle, "Done")
        XCTAssertTrue(model.canContinue)
        await model.continueSetup()
        XCTAssertFalse(model.isPresented)
        XCTAssertFalse(model.isDeferred)
        let before = await service.calls
        model.reopen()
        let after = await service.calls
        XCTAssertEqual(before, after)
        XCTAssertEqual(model.step, .welcome)
        XCTAssertEqual(model.destinationURL, destination)
        XCTAssertEqual(model.sourceURL, source)
        XCTAssertFalse(model.sourceConfirmedByUser)
        XCTAssertFalse(model.canRunTest)
    }

    func testUnknownDiscoveryOffersManualSelectionWithoutInventingCurrentSource() async {
        let service = SetupServiceFixture()
        await service.setDiscovery(.unknown)
        let model = await sourceStep(service: service)
        XCTAssertNil(model.sourceURL)
        XCTAssertTrue(model.statusMessage?.contains("Choose that folder yourself or retry") == true)
        model.selectSource(source)
        XCTAssertFalse(model.sourceConfirmedByUser)
        XCTAssertFalse(model.canContinue)
        let calls = await service.calls
        XCTAssertEqual(calls, ["destination", "discover"])
    }

    func testChangedDiscoveryRetainsUserSourceAndRequiresExplicitSelection() async {
        let service = SetupServiceFixture()
        let model = await sourceStep(service: service)
        model.confirmCurrentSource(true)
        await service.setDiscovery(.known(URL(fileURLWithPath: "/fixture/moved")))
        await model.retrySourceDiscovery()
        XCTAssertEqual(model.sourceURL, source)
        XCTAssertFalse(model.sourceConfirmedByUser)
        XCTAssertTrue(model.statusMessage?.contains("appears to have changed") == true)
    }

    func testReopenRechecksPreferencesWithoutSilentlyAdoptingAnExtantNewSource() async {
        let service = SetupServiceFixture()
        let model = await sourceStep(service: service, gate: SetupGateFixture.approved)
        await model.continueSetup()
        let moved = URL(fileURLWithPath: "/fixture/new-source")
        await service.setDiscovery(.known(moved))
        model.reopen()
        await model.continueSetup()
        await model.continueSetup()
        XCTAssertEqual(model.sourceURL, source)
        XCTAssertEqual(model.sourceIssue, .changed)
        XCTAssertFalse(model.sourceConfirmedByUser)
        model.confirmCurrentSource(true)
        XCTAssertFalse(model.canContinue, "A checkbox must not silently accept a known changed source")
        model.selectSource(moved)
        XCTAssertFalse(model.canContinue)
        model.confirmCurrentSource(true)
        XCTAssertTrue(model.canContinue)
        await model.continueSetup()
        let expectations = await service.expectations
        XCTAssertNil(expectations.last!)
        XCTAssertEqual(model.sourceURL, moved)
    }

    func testUnknownPreferencesAfterReopenRetainDraftButRequireConfirmation() async {
        let service = SetupServiceFixture()
        let model = await sourceStep(service: service)
        await service.setDiscovery(.unknown)
        model.reopen()
        await model.continueSetup()
        await model.continueSetup()
        XCTAssertEqual(model.sourceURL, source)
        XCTAssertTrue(model.isSourceLocationUnknown)
        XCTAssertFalse(model.sourceConfirmedByUser)
        XCTAssertFalse(model.canContinue)
    }

    func testDirectoryURLHintDoesNotInventAChangedSource() async {
        let service = SetupServiceFixture()
        let model = await sourceStep(service: service)
        await service.setDiscovery(.known(URL(fileURLWithPath: source.path, isDirectory: false)))
        await model.retrySourceDiscovery()
        XCTAssertNil(model.sourceIssue)
        XCTAssertFalse(model.requiresSourceSelection)
        model.confirmCurrentSource(true)
        XCTAssertTrue(model.canContinue)
    }

    func testUnavailablePreviouslyCheckedSourceCanRetrySameIdentityWithoutRetargeting() async {
        let service = SetupServiceFixture()
        let model = await sourceStep(service: service, gate: SetupGateFixture.approved)
        await model.continueSetup()
        model.goBack()
        model.confirmCurrentSource(true)
        await service.setSourceFailure(.unavailable)
        await model.continueSetup()
        XCTAssertEqual(model.sourceIssue, .unavailable)
        XCTAssertTrue(model.canContinue)
        XCTAssertEqual(model.primaryTitle, "Retry")
        await service.setSourceFailure(nil)
        await model.continueSetup()
        let identities = await service.expectations
        XCTAssertEqual(identities.last!, SetupServiceFixture.identity(source))
        XCTAssertEqual(model.sourceURL, source)
        XCTAssertTrue(model.canRunTest)
    }

    func testDeniedSourceCannotReachGateAndCanRetry() async {
        let service = SetupServiceFixture()
        let gate = SetupGateFixture.approved
        let model = await sourceStep(service: service, gate: gate)
        await service.setSourceFailure(.denied)
        model.confirmCurrentSource(true)
        await model.continueSetup()
        XCTAssertEqual(model.step, .source)
        XCTAssertTrue(model.statusMessage?.contains("could not access") == true)
        let deniedCalls = await gate.count
        XCTAssertEqual(deniedCalls, 0)
        await service.setSourceFailure(nil)
        await model.continueSetup()
        XCTAssertTrue(model.canRunTest)
    }

    func testUnsafeSourceDestinationSeparationNeverReachesGate() async {
        let service = SetupServiceFixture()
        let gate = SetupGateFixture.approved
        let model = await sourceStep(service: service, gate: gate)
        await service.setSeparationFailure(.unsafe)
        model.confirmCurrentSource(true)
        await model.continueSetup()
        XCTAssertEqual(model.step, .source)
        XCTAssertTrue(model.statusMessage?.contains("separate") == true)
        let count = await gate.count
        XCTAssertEqual(count, 0)
    }

    func testUnavailableDestinationStaysOnDestination() async {
        let service = SetupServiceFixture()
        await service.setDestinationFailure(.missing)
        let model = ShotDropSetupModel(destinationURL: destination, service: service)
        await model.continueSetup()
        await model.continueSetup()
        XCTAssertEqual(model.step, .destination)
        XCTAssertFalse(model.destinationNeedsReview)
        let calls = await service.calls
        XCTAssertEqual(calls, ["destination"])
    }

    func testNotNowDiscardsLateAccessResultAndIsReversible() async {
        let service = SetupServiceFixture()
        let model = await sourceStep(service: service, gate: SetupGateFixture.approved)
        await service.suspendSource()
        model.confirmCurrentSource(true)
        let task = Task { await model.continueSetup() }
        await waitForSuspension(service)
        model.notNow()
        await service.resumeSource()
        await task.value
        XCTAssertFalse(model.isPresented)
        XCTAssertTrue(model.isDeferred)
        XCTAssertFalse(model.canRunTest)
        XCTAssertFalse(model.isBusy)
        model.reopen()
        XCTAssertEqual(model.step, .welcome)
        XCTAssertEqual(model.sourceURL, source)
        XCTAssertFalse(model.sourceConfirmedByUser)
    }

    func testBackInvalidatesLateAccessResult() async {
        let service = SetupServiceFixture()
        let model = await sourceStep(service: service, gate: SetupGateFixture.approved)
        await service.suspendSource()
        model.confirmCurrentSource(true)
        let task = Task { await model.continueSetup() }
        await waitForSuspension(service)
        model.goBack()
        await service.resumeSource()
        await task.value
        XCTAssertEqual(model.step, .destination)
        XCTAssertFalse(model.canRunTest)
        XCTAssertFalse(model.sourceConfirmedByUser)
    }

    func testReopenInvalidatesLateAccessResultWithoutNewPrompts() async {
        let service = SetupServiceFixture()
        let model = await sourceStep(service: service, gate: SetupGateFixture.approved)
        await service.suspendSource()
        model.confirmCurrentSource(true)
        let task = Task { await model.continueSetup() }
        await waitForSuspension(service)
        let before = await service.calls
        model.reopen()
        await service.resumeSource()
        await task.value
        let after = await service.calls
        XCTAssertEqual(before, after)
        XCTAssertEqual(model.step, .welcome)
        XCTAssertFalse(model.canRunTest)
    }

    func testSelectionInvalidatesLateResultsWithoutReplacingNewDraft() async {
        let service = SetupServiceFixture()
        let model = await sourceStep(service: service, gate: SetupGateFixture.approved)
        await service.suspendSource()
        model.confirmCurrentSource(true)
        let task = Task { await model.continueSetup() }
        await waitForSuspension(service)
        let replacement = URL(fileURLWithPath: "/fixture/new-source")
        model.selectSource(replacement)
        await service.resumeSource()
        await task.value
        XCTAssertEqual(model.sourceURL, replacement)
        XCTAssertFalse(model.sourceConfirmedByUser)
        XCTAssertFalse(model.canRunTest)
        let calls = await service.calls
        XCTAssertEqual(calls.filter { $0 == "destinationWithSource" }.count, 0)
    }

    func testCallerCancellationCannotTurnLateSuccessIntoReadiness() async {
        let service = SetupServiceFixture()
        let model = await sourceStep(service: service, gate: SetupGateFixture.approved)
        await service.suspendSource()
        model.confirmCurrentSource(true)
        let task = Task { await model.continueSetup() }
        await waitForSuspension(service)
        task.cancel()
        await service.resumeSource()
        await task.value
        XCTAssertEqual(model.step, .source)
        XCTAssertFalse(model.canRunTest)
        XCTAssertFalse(model.isBusy)
    }

    func testPreviousSourceIdentitySurvivesReopenUntilExplicitReselection() async {
        let service = SetupServiceFixture()
        let model = await sourceStep(service: service, gate: SetupGateFixture.approved)
        model.confirmCurrentSource(true)
        await model.continueSetup()
        model.reopen()
        await model.continueSetup()
        await model.continueSetup()
        model.confirmCurrentSource(true)
        await model.continueSetup()
        var expectations = await service.expectations
        XCTAssertNil(expectations[0])
        XCTAssertEqual(expectations[1], SetupServiceFixture.identity(source))
        model.selectSource(source)
        model.confirmCurrentSource(true)
        await model.continueSetup()
        expectations = await service.expectations
        XCTAssertNil(expectations[2])
    }

    private func sourceStep(service: SetupServiceFixture = SetupServiceFixture(),
                            gate: any ShotDropSetupReadinessGating = ShotDropSetupUnavailableGate()) async -> ShotDropSetupModel {
        let model = ShotDropSetupModel(destinationURL: destination, service: service, gate: gate)
        await model.continueSetup()
        await model.continueSetup()
        XCTAssertEqual(model.step, .source)
        if model.sourceURL != nil { model.confirmCurrentSource(true) }
        return model
    }

    private func waitForSuspension(_ service: SetupServiceFixture) async {
        for _ in 0..<1000 {
            if await service.isSuspended { return }
            await Task.yield()
        }
        XCTFail("Source check did not suspend")
    }
}

private actor SetupSuspendedPreparer: DefaultDestinationSetupPreparing {
    nonisolated let proposedDestination: URL
    private var continuation: CheckedContinuation<Void, Never>?
    var isSuspended: Bool { continuation != nil }
    init(proposedDestination: URL) { self.proposedDestination = proposedDestination }
    func prepare(source: ShotDropSetupDirectoryIdentity) async -> DefaultDestinationPreparationResult {
        await withCheckedContinuation { continuation = $0 }
        return .enrolledPaused
    }
    func resume() { continuation?.resume(); continuation = nil }
}

private actor SetupDefaultPreparerFixture: DefaultDestinationSetupPreparing {
    nonisolated let proposedDestination: URL
    let result: DefaultDestinationPreparationResult
    let reviewResult: DefaultDestinationPreparationResult?
    var count = 0

    init(proposedDestination: URL, result: DefaultDestinationPreparationResult, reviewResult: DefaultDestinationPreparationResult? = nil) {
        self.proposedDestination = proposedDestination
        self.result = result
        self.reviewResult = reviewResult
    }
    func reviewState() async -> DefaultDestinationPreparationResult? { reviewResult }

    func prepare(source: ShotDropSetupDirectoryIdentity) async -> DefaultDestinationPreparationResult {
        count += 1
        return result
    }
}

private actor SetupServiceFixture: ShotDropSetupAccessServing {
    var calls: [String] = []
    var expectations: [ShotDropSetupDirectoryIdentity?] = []
    private var discovery: ShotDropSetupSourceResolution = .known(URL(fileURLWithPath: "/fixture/source", isDirectory: true))
    private var sourceFailure: ShotDropSetupAccessIssue?
    private var destinationFailure: ShotDropSetupAccessIssue?
    private var separationFailure: ShotDropSetupAccessIssue?
    private var shouldSuspend = false
    private var continuation: CheckedContinuation<Void, Never>?
    var isSuspended: Bool { continuation != nil }

    nonisolated static func identity(_ url: URL) -> ShotDropSetupDirectoryIdentity {
        ShotDropSetupDirectoryIdentity(path: url.path, device: 1, inode: url.path.contains("source") ? 2 : 3,
                                       birthSeconds: 1, birthNanoseconds: 0)
    }
    func setDiscovery(_ result: ShotDropSetupSourceResolution) { discovery = result }
    func setSourceFailure(_ issue: ShotDropSetupAccessIssue?) { sourceFailure = issue }
    func setDestinationFailure(_ issue: ShotDropSetupAccessIssue?) { destinationFailure = issue }
    func setSeparationFailure(_ issue: ShotDropSetupAccessIssue?) { separationFailure = issue }
    func suspendSource() { shouldSuspend = true }
    func resumeSource() { continuation?.resume(); continuation = nil; shouldSuspend = false }
    func discoverSource() async -> ShotDropSetupSourceResolution {
        calls.append("discover")
        return discovery
    }
    func checkSource(_ url: URL, expecting identity: ShotDropSetupDirectoryIdentity?) async -> ShotDropSetupSourceAccessResult {
        calls.append("source")
        expectations.append(identity)
        if shouldSuspend { await withCheckedContinuation { continuation = $0 } }
        if let sourceFailure { return .unavailable(sourceFailure) }
        return .accessible(Self.identity(url))
    }
    func checkDestination(_ url: URL, source: URL?, sourceIdentity: ShotDropSetupDirectoryIdentity?) async -> ShotDropSetupDestinationAccessResult {
        calls.append(source == nil ? "destination" : "destinationWithSource")
        if let destinationFailure { return .unavailable(destinationFailure) }
        if source != nil, let separationFailure { return .unavailable(separationFailure) }
        return .needsReview(Self.identity(url))
    }
}

private actor SetupGateFixture: ShotDropSetupReadinessGating {
    let destination: Bool
    let pipeline: Bool
    let review: Bool
    let mismatched: Bool
    var count = 0
    static var approved: SetupGateFixture { SetupGateFixture(destination: true, pipeline: true, review: true) }
    init(destination: Bool, pipeline: Bool, review: Bool, mismatched: Bool = false) {
        self.destination = destination
        self.pipeline = pipeline
        self.review = review
        self.mismatched = mismatched
    }
    func evaluate(_ binding: ShotDropSetupReadinessBinding) async -> ShotDropSetupReadiness {
        count += 1
        let actual = mismatched ? ShotDropSetupReadinessBinding(source: binding.destination, destination: binding.source) : binding
        return ShotDropSetupReadiness(binding: actual, destinationReady: destination,
                                      pipelineReady: pipeline, boundReviewApproved: review)
    }
}
