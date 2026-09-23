import SwiftUI

/// Ready for the pipeline's failure presentation; adding the component does not start monitoring.
@MainActor
struct ScreenshotSaveRecoveryView: View {
    let failure: ScreenshotSaveFailure
    var isRetrying = false
    let retry: () -> Void
    let chooseDestination: () -> Void
    let revealOriginal: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(failure.title, systemImage: "exclamationmark.triangle")
                .font(.headline)
            Text(failure.message)
                .fixedSize(horizontal: false, vertical: true)
            Text(failure.originalURL.path)
                .font(.caption)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Original path: \(failure.originalURL.path)")
            VStack(alignment: .leading, spacing: 8) {
                ForEach(failure.actions) { action in
                    Button(action.title) { perform(action) }
                        .disabled(isRetrying)
                }
            }
            if isRetrying {
                ProgressView("Retrying save…")
                    .controlSize(.small)
            }
        }
        .padding()
        .accessibilityElement(children: .contain)
    }

    private func perform(_ action: ScreenshotSaveRecoveryAction) {
        switch action {
        case .retry: retry()
        case .chooseDestination: chooseDestination()
        case .revealOriginal: revealOriginal(failure.originalURL)
        }
    }
}
