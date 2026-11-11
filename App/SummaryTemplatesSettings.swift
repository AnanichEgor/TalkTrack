import AppKit
import SwiftUI
import TalkTrackDomain
import TalkTrackServices
import UniformTypeIdentifiers

/// Settings ▸ Summaries: imported templates, the built-in types, the guide
/// download and the import with its checks (custom-summary-templates D9).
struct SummaryTemplatesSettings: View {
    @Bindable var presentation: SummaryTemplatesPresentation
    /// A file that passed the checks, waiting for Add/Replace.
    @State private var pending: PendingImport?
    /// Errors of a refused file.
    @State private var refused: Refusal?
    @State private var deleting: Deletion?
    @State private var shownPrompt: ShownPrompt?
    @State private var replacingGuide: URL?
    @State private var message: String?

    struct PendingImport: Identifiable {
        let id = UUID()
        let text: String
        let check: SummaryTemplateCheck
    }
    struct Refusal: Identifiable {
        let id = UUID()
        let fileName: String
        let errors: [String]
    }
    struct Deletion: Identifiable {
        let id: UUID
        let name: String
        let summaries: Int
    }
    struct ShownPrompt: Identifiable {
        let id = UUID()
        let title: String
        let text: String
    }

    var body: some View {
        Form {
            Section {
                Text("Add your own summary types by importing a template file. Download the guide and the example, then give them to your AI assistant together with a description of your meetings and ask it to write a template. Or edit the example by hand.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Download Guide & Example…", systemImage: "arrow.down.doc") { chooseGuideFolder() }
                        .help("Save the template guide and an example template, both in English")
                    Button("Import Template…", systemImage: "square.and.arrow.down") { chooseTemplateFile() }
                        .help("Check a template file and add it to the summary types")
                }
                if let message {
                    Text(message).font(.callout).foregroundStyle(.secondary).id(message)
                }
                if let error = presentation.error {
                    Text(error).font(.callout).foregroundStyle(Color.errorText).textSelection(.enabled).id(error)
                }
            }
            Section("Your Templates") {
                if presentation.templates.isEmpty && presentation.damaged.isEmpty {
                    Text("No imported templates").foregroundStyle(.secondary)
                }
                ForEach(presentation.templates) { template in
                    row(icon: CustomSummaryTemplate.icon, title: template.name,
                        detail: sectionsText(template.file.sections.count) + (template.file.purpose.isEmpty ? "" : " · \(template.file.purpose)")) {
                        Button("Show Prompt") { show(template.template) }
                            .accessibilityLabel("Show prompt of \(template.name)")
                        Button("Export…") { export(presentation.exportText(template), name: template.name) }
                            .accessibilityLabel("Export \(template.name)")
                        Button("Delete…", role: .destructive) { Task { await confirmDelete(template.id, name: template.name) } }
                            .accessibilityLabel("Delete \(template.name)")
                    }
                }
                ForEach(presentation.damaged) { damaged in
                    row(icon: "exclamationmark.triangle", title: damaged.name, detail: damaged.reason) {
                        Button("Delete…", role: .destructive) { Task { await confirmDelete(damaged.id, name: damaged.name) } }
                            .accessibilityLabel("Delete \(damaged.name)")
                    }
                }
            }
            Section {
                ForEach(presentation.builtIn, id: \.type) { template in
                    row(icon: template.icon, title: template.title, detail: template.purpose) {
                        Button("Show Prompt") { show(template) }
                            .accessibilityLabel("Show prompt of \(template.title)")
                        Button("Export…") { export(presentation.exportText(template), name: template.title) }
                            .accessibilityLabel("Export \(template.title)")
                            .help("Save this type as a template file to start your own from")
                    }
                }
            } header: {
                Text("Built-in Templates")
            } footer: {
                Text("Prompts and exported built-in templates use the summary language set in Text.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await presentation.refresh() }
        .sheet(item: $pending) { item in ImportConfirmation(item: item, presentation: presentation) { saved in
            pending = nil
            if let saved { message = "“\(saved.name)” is available in the Summary tab." }
        } }
        .sheet(item: $shownPrompt) { prompt in PromptSheet(prompt: prompt) { shownPrompt = nil } }
        .alert("This file cannot be imported", isPresented: Binding(get: { refused != nil }, set: { if !$0 { refused = nil } }),
               presenting: refused) { _ in
            Button("OK") { refused = nil }
        } message: { refusal in
            Text(refusalText(refusal))
        }
        .confirmationDialog(deleting.map { "Delete “\($0.name)”?" } ?? "", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            presenting: deleting) { item in
            Button("Delete Template", role: .destructive) {
                deleting = nil
                Task { await presentation.delete(item.id); message = "“\(item.name)” was deleted." }
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: { item in
            Text(deleteText(item))
        }
        .confirmationDialog("Replace the existing guide and example?", isPresented: Binding(get: { replacingGuide != nil }, set: { if !$0 { replacingGuide = nil } }),
                            presenting: replacingGuide) { folder in
            Button("Replace") { replacingGuide = nil; writeGuide(to: folder) }
            Button("Cancel", role: .cancel) { replacingGuide = nil }
        } message: { folder in
            Text("\(SummaryTemplatesPresentation.existingGuideFiles(in: folder).joined(separator: " and ")) already exist in “\(folder.lastPathComponent)”.")
        }
        #if DEBUG && TALKTRACK_DEVTOOLS
        .onReceive(NotificationCenter.default.publisher(for: .reviewImportTemplate)) { note in
            if let url = note.object as? URL { Task { await importFile(url) } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .reviewDownloadGuide)) { note in
            if let url = note.object as? URL { saveGuide(to: url) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .reviewTemplateAction)) { note in
            guard let command = note.object as? String, let colon = command.firstIndex(of: ":") else { return }
            let action = command[..<colon], name = String(command[command.index(after: colon)...])
            if let template = presentation.templates.first(where: { $0.name == name }) {
                if action == "delete" { Task { await confirmDelete(template.id, name: template.name) } }
                if action == "prompt" { show(template.template) }
            } else if let template = presentation.builtIn.first(where: { $0.title == name }), action == "prompt" {
                show(template)
            }
        }
        #endif
    }

    private func row(icon: String, title: String, detail: String, @ViewBuilder actions: () -> some View) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium).lineLimit(1).truncationMode(.tail)
                if !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            HStack(spacing: 6) { actions() }.fixedSize().controlSize(.small)
        }
        .padding(.vertical, 2)
    }

    private func sectionsText(_ count: Int) -> String { count == 1 ? "1 section" : "\(count) sections" }

    private func refusalText(_ refusal: Refusal) -> String {
        let shown = refusal.errors.prefix(5).joined(separator: "\n")
        let more = refusal.errors.count > 5 ? "\nand \(refusal.errors.count - 5) more" : ""
        return "\(refusal.fileName):\n\(shown)\(more)\n\nNothing was saved. Correct the file and import it again."
    }

    private func deleteText(_ item: Deletion) -> String {
        var text = "This cannot be undone. Summaries already made with it stay readable."
        if item.summaries > 0 {
            text += item.summaries == 1 ? " 1 summary that uses it and has not finished will be cancelled."
                : " \(item.summaries) summaries that use it and have not finished will be cancelled."
        }
        return text
    }

    private func confirmDelete(_ id: UUID, name: String) async {
        deleting = Deletion(id: id, name: name, summaries: await presentation.unfinishedSummaries(using: id))
    }

    private func show(_ template: SummaryTemplate) {
        shownPrompt = ShownPrompt(title: template.title, text: presentation.prompt(template))
    }

    private func chooseTemplateFile() {
        let panel = NSOpenPanel()
        panel.title = "Import Template"
        panel.prompt = "Check and Import"
        panel.allowedContentTypes = [UTType(filenameExtension: "md", conformingTo: .plainText) ?? .plainText, .plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await importFile(url) }
    }

    private func importFile(_ url: URL) async {
        message = nil
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
            refused = Refusal(fileName: url.lastPathComponent, errors: ["The file is not readable UTF-8 text."])
            return
        }
        let check = await presentation.check(text)
        if check.canImport { pending = PendingImport(text: text, check: check) }
        else { refused = Refusal(fileName: url.lastPathComponent, errors: check.errors.map(\.text)) }
    }

    private func export(_ text: String, name: String) {
        let panel = NSSavePanel()
        panel.title = "Export Template"
        panel.allowedContentTypes = [UTType(filenameExtension: "md", conformingTo: .plainText) ?? .plainText]
        panel.nameFieldStringValue = name.replacingOccurrences(of: "/", with: "-") + ".md"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
            message = "Exported “\(name)” to \(url.lastPathComponent)."
        } catch { message = "The template could not be saved: \(error.localizedDescription)" }
    }

    private func chooseGuideFolder() {
        let panel = NSOpenPanel()
        panel.title = "Download Guide & Example"
        panel.prompt = "Save Here"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        saveGuide(to: folder)
    }

    private func saveGuide(to folder: URL) {
        if SummaryTemplatesPresentation.existingGuideFiles(in: folder).isEmpty { writeGuide(to: folder) }
        else { replacingGuide = folder }
    }

    private func writeGuide(to folder: URL) {
        do {
            try SummaryTemplatesPresentation.writeGuide(to: folder)
            message = "Saved \(SummaryTemplateGuide.guideFileName) and \(SummaryTemplateGuide.exampleFileName) to “\(folder.lastPathComponent)”."
            NSWorkspace.shared.activateFileViewerSelecting([folder.appendingPathComponent(SummaryTemplateGuide.guideFileName)])
        } catch { message = "The guide could not be saved: \(error.localizedDescription)" }
    }
}

/// Name, sections and warnings of a checked file; Add or Replace saves it.
private struct ImportConfirmation: View {
    let item: SummaryTemplatesSettings.PendingImport
    let presentation: SummaryTemplatesPresentation
    let done: (CustomSummaryTemplate?) -> Void
    @State private var saving = false

    var body: some View {
        let check = item.check
        VStack(alignment: .leading, spacing: 14) {
            Text(check.replaces != nil ? "Replace “\(check.replaces!)”?" : "Add “\(check.file?.name ?? "")”?")
                .font(.title3.weight(.semibold))
            if check.replaces != nil {
                Text("The template with this name is replaced by the file. Summaries made with the old version are shown as outdated.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let file = check.file {
                if !file.purpose.isEmpty { Text(file.purpose).font(.callout) }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sections").font(.callout.weight(.medium))
                    ForEach(Array(file.sections.enumerated()), id: \.offset) { _, section in
                        Label {
                            Text(section.heading + (section.heading == file.perPerson ? " (by person)" : "")
                                 + (section.explanation.isEmpty ? " (built-in explanation)" : ""))
                        } icon: { Image(systemName: "number").foregroundStyle(.secondary) }
                        .font(.callout)
                    }
                }
                if !file.rules.isEmpty {
                    Text(file.rules.count == 1 ? "1 rule" : "\(file.rules.count) rules").font(.callout).foregroundStyle(.secondary)
                }
            }
            if !check.warnings.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Warnings", systemImage: "exclamationmark.triangle").font(.callout.weight(.medium))
                        .foregroundStyle(Color.pausedText)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(check.warnings.enumerated()), id: \.offset) { _, warning in
                                Text(warning.text).font(.callout).fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 160)
                    Text("Warnings do not block the import.").font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { done(nil) }.keyboardShortcut(.cancelAction)
                Button(check.replaces != nil ? "Replace Template" : "Add Template") {
                    saving = true
                    Task { done(await presentation.save(item.text)) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(saving)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

/// The exact instructions a template gives the model, read-only.
private struct PromptSheet: View {
    let prompt: SummaryTemplatesSettings.ShownPrompt
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Prompt: \(prompt.title)").font(.title3.weight(.semibold))
            Text("What the model receives for a recording short enough for one request. The meeting title, date and transcript follow as source data.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                Text(prompt.text).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(prompt.text, forType: .string)
                }
                Spacer()
                Button("Done") { done() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 620, height: 520)
    }
}
