import SwiftUI
import TalkTrackDomain
import TalkTrackServices

struct TranslationTab: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openSettings) private var openSettings
    @State private var presentation: TranslationPresentation
    @State private var index: TranscriptPlaybackIndex?
    let player: MeetingPlayer
    let captureActive: Bool

    init(services: WorkspaceServices, meetingID: UUID, captureActive: Bool) {
        player = services.player; self.captureActive = captureActive
        _presentation = State(initialValue: TranslationPresentation(meetingID: meetingID, store: services.store,
            runner: services.runner, pipeline: services.translations, model: services.translationModel))
    }
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Button(presentation.output == nil ? "Translate Transcript" : "Translate Again", systemImage: "character.book.closed") {
                        Task { await presentation.generate() }
                    }
                    .disabled(!presentation.canGenerate || captureActive)
                    .help("Translate the final transcript into the language selected in Settings")
                    if presentation.running {
                        Button("Cancel", role: .cancel) { Task { await presentation.cancel() } }.disabled(presentation.isBusy)
                            .help("Cancel generation and keep the previous translation")
                    }
                    Spacer()
                    Button("Language Settings…") { app.showSettings(openSettings, tab: .text) }
                }
                if let status = presentation.status {
                    // Centered: the message lines up with Retry and Download Model….
                    HStack(alignment: .center, spacing: 8) {
                        if presentation.running { ProgressView().controlSize(.small) }
                        Text(status).font(.callout).textSelection(.enabled).id(status)
                            .fixedSize(horizontal: false, vertical: true)
                        if presentation.canRetry {
                            Button("Retry") { Task { await presentation.retry() } }.disabled(captureActive)
                                .help("Retry using this request’s saved transcript and settings")
                        }
                        if presentation.job?.stage == .waitingForModels {
                            Button("Download Model…") { app.showMissingModels([.translation]); app.showSettings(openSettings) }
                        }
                    }
                }
                if let error = presentation.error {
                    Text(error).font(.callout).foregroundStyle(Color.errorText).textSelection(.enabled).id(error)
                }
                if let reason = presentation.requirement { Text(reason).font(.callout).foregroundStyle(.secondary) }
                else if captureActive { Text("Stop recording before translating.").font(.callout).foregroundStyle(.secondary) }
                if let output = presentation.output {
                    HStack {
                        Text(output.job.settings.translationLanguage == .english ? "English" : "Russian")
                        Text(output.createdAt, style: .date)
                        if presentation.outdated {
                            Label("Outdated", systemImage: "clock.arrow.circlepath")
                                .help("The transcript or translation settings changed. Translate again to update.")
                        }
                    }
                    .font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 32).padding(.top, 16)
            Group {
                if presentation.output != nil {
                    Divider().padding(.horizontal, 32).padding(.top, 8)
                    translatedText
                } else if !presentation.running {
                    ContentUnavailableView("No Translation", systemImage: "character.book.closed",
                        description: Text("Translate the final transcript. Dates, speaker names and timestamps stay with their original audio."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else { Spacer() }
            }
        }
        .onChange(of: IndexKey(items: presentation.items, meetingID: player.meetingID, duration: player.duration), initial: true) {
            index = player.meetingID == presentation.meetingID
                ? player.timeline.map { TranscriptPlaybackIndex(timeline: $0, items: presentation.items) } : nil
        }
        .task {
            while !Task.isCancelled {
                await presentation.refresh()
                do { try await Task.sleep(for: .milliseconds(500)) } catch { break }
            }
        }
    }

    private struct IndexKey: Equatable { let items: [TranscriptDisplayItem]; let meetingID: UUID?; let duration: MediaTime? }

    /// The block under the playhead, as in Transcript.
    private var highlighted: String? {
        guard let index, player.meetingID == presentation.meetingID else { return nil }
        switch player.state {
        case .playing: break
        case .paused, .failed: guard player.position > .zero else { return nil }
        case .unavailable, .ended: return nil
        }
        return index.activeItem(at: player.position)
    }

    /// Laid out like Transcript: `[time]:` plays the original audio, the name in
    /// its speaker color, the block under the playhead highlighted and followed.
    private var translatedText: some View {
        let current = highlighted
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(presentation.items) { item in
                        switch item {
                        case .date(let day):
                            Text(day.text).font(.callout).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 8)
                        case .speech(let block):
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                timestamp(block, id: item.id, current: item.id == current)
                                speech(block)
                            }
                            .font(.title3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(item.id == current ? Color.accentColor.opacity(0.14) : .clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                            .accessibilityElement(children: .contain)
                            .accessibilityAddTraits(item.id == current ? .isSelected : [])
                            .id(item.id)
                        }
                    }
                }
                .padding(.horizontal, 32).padding(.vertical, 16)
            }
            .onChange(of: current) { _, id in
                guard let id, player.state == .playing else { return }
                withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .id(presentation.output?.id)
    }

    @ViewBuilder private func timestamp(_ block: TranscriptBlock, id: String, current: Bool) -> some View {
        let label = Text("[\(block.timestamp)]:").foregroundStyle(.secondary).monospacedDigit()
        if let start = index?.start(of: id) {
            Button { player.play(from: start, meetingID: presentation.meetingID) } label: { label }
                .buttonStyle(.plain)
                .disabled(!player.canPlay)
                .help(player.captureActive ? "Playback is unavailable while TalkTrack is recording" : "Play the original audio from \(block.timestamp)")
                .accessibilityLabel("Play from \(block.timestamp)")
                .accessibilityValue(current ? "Now playing" : "")
        } else {
            label
        }
    }

    private func speech(_ block: TranscriptBlock) -> some View {
        var name = AttributedString(block.speakerLabel)
        name.font = MeetingTranscriptView.nameFont
        name.foregroundColor = Color.speaker(block.speaker, order: presentation.speakerIDs)
        let text = block.segments.map { $0.correctedText ?? $0.originalText }.joined(separator: " ")
        return Text(name + AttributedString(" - " + text)).lineSpacing(5).textSelection(.enabled)
    }
}
