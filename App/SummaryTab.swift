import AppKit
import SwiftUI
import TalkTrackDomain
import TalkTrackServices

/// One summary per recording, in recording order.
struct SummaryTab: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openSettings) private var openSettings
    @State private var presentation: SummaryPresentation
    let captureActive: Bool
    let export: ExportButton

    init(services: WorkspaceServices, meetingID: UUID, captureActive: Bool, export: ExportButton) {
        self.captureActive = captureActive; self.export = export
        _presentation = State(initialValue: SummaryPresentation(meetingID: meetingID, store: services.store,
            runner: services.runner, pipeline: services.summaries, model: services.summaryModel,
            settings: { SummaryModelOptions.settings(for: $0) }, templates: services.templates))
    }

    /// The text server when it is set up, then the downloaded local text models.
    private var modelOptions: [SummaryModelOption] {
        let local = (app.models?.items ?? []).filter(\.isTextModel).map {
            (id: $0.id, title: $0.title.replacingOccurrences(of: "Text processing: ", with: ""), installed: $0.state.isInstalled)
        }
        return SummaryModelOptions.make(server: app.textServer.summaryServer, local: local, localDefault: localDefault)
    }

    /// The local model chosen in Settings ▸ Models; Automatic picks it by memory.
    private var localDefault: String { app.models?.selectedTextModel ?? "" }

    /// The user's choice while it is still offered; otherwise the server, or the model for this Mac's memory.
    private var modelChoice: SummaryModelChoice {
        if let choice = presentation.modelChoice, modelOptions.contains(where: { $0.choice == choice }) { return choice }
        return SummaryModelOptions.defaultChoice(server: app.textServer.summaryServer, localDefault: localDefault)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                export
                Picker("Summary type", selection: $presentation.selection) {
                    if presentation.selection == nil {
                        Text("Choose a template").tag(SummaryTemplateChoice?.none)
                    }
                    ForEach(SummaryTemplates.current, id: \.type) { template in
                        Label(template.title, systemImage: template.icon).tag(SummaryTemplateChoice?.some(.builtIn(template.type)))
                    }
                    if !presentation.customTemplates.isEmpty {
                        Divider()
                        ForEach(presentation.customTemplates) { template in
                            Label(template.name, systemImage: CustomSummaryTemplate.icon).tag(SummaryTemplateChoice?.some(.custom(template.id)))
                        }
                    }
                }
                .frame(maxWidth: 290)
                .disabled(presentation.isBusy)
                .help("Used for the next summaries you generate")
                Picker("Model", selection: Binding(get: { modelChoice }, set: { presentation.modelChoice = $0 })) {
                    ForEach(modelOptions) { Text($0.title).tag($0.choice) }
                }
                .frame(maxWidth: 260)
                .disabled(presentation.isBusy)
                .help("The model for the next summaries you generate. A text server is set up in Settings ▸ Models.")
                Button("Generate Summaries", systemImage: "text.badge.plus") {
                    presentation.modelChoice = modelChoice
                    Task { await presentation.generate() }
                }
                .disabled(!presentation.canGenerate || captureActive)
                .help(captureActive ? "Stop recording before generating summaries" :
                    "Summarize each recording whose summary is missing or outdated, using the selected type")
                Spacer(minLength: 0)
            }
            if let error = presentation.error {
                Text(error).font(.callout).foregroundStyle(Color.errorText).textSelection(.enabled).id(error)
            }
            if captureActive {
                Text("Stop recording before generating summaries.").font(.callout).foregroundStyle(.secondary)
            }
            if presentation.loaded && presentation.selection == nil {
                Text("The template of these summaries was deleted. Choose a template to generate summaries.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Divider()
            if presentation.loaded && presentation.entries.isEmpty {
                ContentUnavailableView("No Recordings", systemImage: "text.alignleft",
                    description: Text("Record this meeting, then generate a summary for each recording."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 36) {
                        ForEach(presentation.entries) { entry in section(entry) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, 32).padding(.vertical, 16)
        .task {
            while !Task.isCancelled {
                await presentation.refresh()
                do { try await Task.sleep(for: .milliseconds(500)) } catch { break }
            }
        }
        .onChange(of: presentation.selection) { _, _ in Task { await presentation.refresh() } }
    }

    @ViewBuilder private func section(_ entry: SummaryPresentation.Entry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recording \(entry.number)").font(.title2.weight(.semibold))
                    Label(when(entry.recording), systemImage: "calendar").font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if let output = entry.output {
                    Button("Copy", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(output.text, forType: .string)
                    }
                    .help("Copy this summary as Markdown")
                }
                if entry.running {
                    Button("Cancel", role: .cancel) { Task { await presentation.cancel(entry) } }
                        .disabled(presentation.isBusy)
                        .help("Cancel generation and keep the previous summary of this recording")
                } else if entry.output != nil {
                    Button("Regenerate", systemImage: "arrow.clockwise") {
                        presentation.modelChoice = modelChoice
                        Task { await presentation.regenerate(entry) }
                    }
                        .disabled(!presentation.canRegenerate(entry) || captureActive)
                        .help("Summarize this recording again using the selected type")
                }
            }
            if let output = entry.output {
                HStack(spacing: 8) {
                    templateTag(output.job.settings, missing: entry.templateMissing)
                    tag(output.job.settings.summaryLanguage == .english ? "English" : "Russian", icon: "globe")
                    Text("Generated \(output.createdAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                    if entry.outdated {
                        Label("Outdated", systemImage: "clock.arrow.circlepath")
                            .font(.caption.weight(.medium)).foregroundStyle(Color.pausedText)
                            .help("This recording's transcript, the meeting title or the summary settings changed. Regenerate to update.")
                    }
                }
            }
            if let status = entry.status {
                // Centered: the message lines up with Retry and Download Model….
                HStack(alignment: .center, spacing: 8) {
                    if entry.running { ProgressView().controlSize(.small) }
                    Text(status).font(.callout).textSelection(.enabled).id(status)
                        .fixedSize(horizontal: false, vertical: true)
                    if entry.canRetry {
                        Button("Retry") { Task { await presentation.retry(entry) } }
                            .disabled(captureActive || !presentation.canRetry(entry))
                            .help(entry.templateMissing ? "The template of this request was deleted. Choose a template and generate the summary again."
                                  : "Retry using this request’s saved transcript and settings")
                    }
                    if entry.job?.stage == .waitingForModels {
                        Button("Download Model…") { app.showMissingModels([.summary]); app.showSettings(openSettings) }
                    }
                }
            }
            if let output = entry.output {
                SummaryDocumentView(markdown: output.text)
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
                    .padding(.top, 4)
                    .id(output.id)
            } else if let requirement = entry.requirement {
                Text(requirement).font(.callout).foregroundStyle(.secondary)
            } else if !entry.running && entry.job == nil {
                Text("No summary yet. Generate Summaries creates it.").font(.callout).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// The type or imported template a summary was made with; a deleted template keeps its saved name.
    @ViewBuilder private func templateTag(_ settings: ProcessingSettings, missing: Bool) -> some View {
        if settings.summaryType == .custom {
            let name = settings.customTemplate?.name ?? "Custom template"
            tag(missing ? "\(name) (template deleted)" : name, icon: CustomSummaryTemplate.icon)
                .help(missing ? "This summary’s template was deleted. Its text stays; choose a template to generate it again." : "Imported template")
        } else {
            let template = SummaryTemplates.template(settings.summaryType)
            tag(template?.title ?? settings.summaryType.rawValue, icon: template?.icon ?? "doc.text")
        }
    }

    private func tag(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon).font(.caption.weight(.medium))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(.quaternary, in: Capsule())
    }

    /// "Tuesday, October 14, 2026 · 09:00–09:42 · 42 min" in the recording's time zone.
    private func when(_ recording: Recording) -> String {
        let zone = TimeZone(identifier: recording.timeZoneIdentifier) ?? .current
        var day = Date.FormatStyle(date: .complete, time: .omitted); day.timeZone = zone
        var time = Date.FormatStyle(date: .omitted, time: .shortened); time.timeZone = zone
        var parts = [recording.startedAt.formatted(day)]
        if let end = recording.endedAt {
            parts.append("\(recording.startedAt.formatted(time))–\(end.formatted(time))")
            let minutes = Int((recording.activeDuration.seconds / 60).rounded())
            parts.append(minutes < 1 ? "under 1 min" : "\(minutes) min")
        } else {
            parts.append(recording.startedAt.formatted(time))
        }
        return parts.joined(separator: " · ")
    }
}
