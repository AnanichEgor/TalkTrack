import SwiftUI
import TalkTrackDomain
import TalkTrackServices

/// Reusable transcript content for the recording workspace. Its observer task
/// is owned by the capture presentation, so navigation cannot stop capture.
struct LiveTranscriptView: View {
    let presentation: LiveTranscriptPresentation
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(presentation.state.message)
                .font(.callout).foregroundStyle(.secondary)
                .accessibilityLabel(presentation.state.message)
            if let issue = presentation.lastFailureMessage {
                Text("Live processing issue: \(issue)")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(presentation.rows.enumerated()), id: \.element.id) { index, row in
                        if index == 0 || presentation.rows[index - 1].day.id != row.day.id {
                            Text("------------ [\(TranscriptDateSeparator.display(row.day.localDate))] ------------")
                                .font(.caption).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("[\(timestamp(row))]: \(row.speakerLabel) · Provisional")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(row.text).textSelection(.enabled)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }
    private func timestamp(_ row: LiveUtterance) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: row.day.timeZoneIdentifier)
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: row.wallClockStart)
    }
}
