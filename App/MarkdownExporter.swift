import AppKit
import TalkTrackDomain
import TalkTrackServices
import UniformTypeIdentifiers

/// Saves a meeting tab, or the whole meeting, as a Markdown file the user places.
/// Reads committed content; the library is never written.
@MainActor enum MarkdownExporter {
    /// The folder of the last export, offered first next time.
    static let folderKey = "markdownExportFolder"

    /// `section` nil exports the whole meeting (`Export All…`).
    static func export(meetingID: UUID, section: MeetingExportSection?, services: WorkspaceServices,
                       workspace: WorkspacePresentation) async {
        // Notes typed in the last moment are still in the autosave buffer.
        try? await services.notes.flush(meetingID: meetingID)
        let snapshot: MeetingExportSnapshot
        do {
            var settings = ProcessingPreferences.snapshot()
            settings.templateVersion = IndexedTranslation.version
            snapshot = try await services.store.meetingExport(meetingID: meetingID, settings: settings)
        } catch {
            workspace.issue = WorkspaceIssue(message: "This meeting could not be read for export.", recovery: error.localizedDescription)
            return
        }
        let markdown = section.map { MeetingMarkdownExport.markdown(snapshot, section: $0) } ?? MeetingMarkdownExport.markdown(all: snapshot)
        guard let markdown else {
            workspace.issue = WorkspaceIssue(message: "Nothing to export.", recovery: "This tab has no content yet.")
            return
        }
        let panel = NSSavePanel()
        panel.title = section.map { "Export \($0.rawValue)" } ?? "Export Meeting"
        panel.allowedContentTypes = [UTType(filenameExtension: "md", conformingTo: .plainText) ?? .plainText]
        panel.nameFieldStringValue = MeetingMarkdownExport.fileName(title: snapshot.meeting.title, section: section)
        panel.directoryURL = lastFolder
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            // Written beside the destination and renamed over it, so a failure leaves no partial file.
            try Data(markdown.utf8).write(to: url, options: .atomic)
            UserDefaults.standard.set(url.deletingLastPathComponent().path, forKey: folderKey)
        } catch {
            workspace.issue = WorkspaceIssue(message: "“\(url.lastPathComponent)” could not be saved.",
                recovery: "\(url.deletingLastPathComponent().path): \(reason(error))")
        }
    }

    private static var lastFolder: URL {
        if let path = UserDefaults.standard.string(forKey: folderKey) {
            var isFolder: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isFolder), isFolder.boolValue { return URL(fileURLWithPath: path) }
        }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// The underlying POSIX reason ("Permission denied") reads better than Cocoa's generic sentence.
    private static func reason(_ error: Error) -> String {
        if let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
            return String(cString: strerror(Int32(underlying.code)))
        }
        return error.localizedDescription
    }
}
