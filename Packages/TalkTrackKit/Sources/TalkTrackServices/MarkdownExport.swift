import Foundation
import TalkTrackDomain

/// A meeting tab that can be exported on its own.
public enum MeetingExportSection: String, CaseIterable, Sendable {
    case transcript = "Transcript", notes = "Notes", summary = "Summary", translation = "Translation"
}

/// What one export reads, in one actor turn, so every section shows the same moment.
public struct MeetingExportSnapshot: Sendable {
    public struct Summary: Sendable {
        public let recording: Recording
        /// 1-based position in the meeting, as the Summary tab numbers it.
        public let number: Int
        public let text: String
        public let outdated: Bool
    }

    public struct Translation: Sendable {
        public let items: [TranscriptDisplayItem]
        public let language: OutputLanguage
        public let outdated: Bool
    }

    public let meeting: Meeting
    public let transcript: [TranscriptDisplayItem]
    /// Some recording still has only its live transcript.
    public let provisional: Bool
    public let notes: NotesRevision?
    /// Recordings with a summary, in capture order.
    public let summaries: [Summary]
    public let translation: Translation?
}

extension SessionStore {
    /// Committed content only; reading never changes the library. `settings` are
    /// the current output settings; a summary is compared under its own summary
    /// type, so the type picked for the next summaries does not mark it outdated.
    public func meetingExport(meetingID: UUID, settings: ProcessingSettings) throws -> MeetingExportSnapshot {
        let transcript = try meetingTranscript(meetingID: meetingID)
        let recordings = transcript.recordings.sorted { $0.startedAt < $1.startedAt }
        var summaries: [MeetingExportSnapshot.Summary] = []
        for (index, recording) in recordings.enumerated() {
            guard let output = try summary(meetingID: meetingID, recordingID: recording.id) else { continue }
            var own = settings
            own.summaryType = output.job.settings.summaryType
            summaries.append(.init(recording: recording, number: index + 1, text: output.text,
                                   outdated: try isOutdated(output, settings: own)))
        }
        var translation: MeetingExportSnapshot.Translation?
        if let output = try output(.translation, meetingID: meetingID) {
            translation = .init(items: try translatedItems(output), language: output.job.settings.translationLanguage,
                                outdated: try isOutdated(output, settings: settings))
        }
        return MeetingExportSnapshot(meeting: transcript.meeting, transcript: transcript.items,
            provisional: transcript.revisions.contains { $0.kind == .live },
            notes: try notes(meetingID: meetingID), summaries: summaries, translation: translation)
    }

    /// Which tabs have something to export, cheaply enough to ask while a tab is shown.
    public func exportableSections(meetingID: UUID) throws -> Set<MeetingExportSection> {
        var sections: Set<MeetingExportSection> = []
        let recordings = try recordings(meetingID: meetingID)
        if try recordings.contains(where: { try transcript(meetingID: meetingID, recordingID: $0.id)?.segments.isEmpty == false }) {
            sections.insert(.transcript)
        }
        if let notes = try notes(meetingID: meetingID), !MeetingMarkdownExport.notesMarkdown(notes, below: 0).isEmpty {
            sections.insert(.notes)
        }
        if try !summaries(meetingID: meetingID).isEmpty { sections.insert(.summary) }
        if try output(.translation, meetingID: meetingID) != nil { sections.insert(.translation) }
        return sections
    }
}

/// Markdown files of a meeting. Stored text is reproduced as is; only text that
/// would start a Markdown block at the beginning of a line is escaped, and
/// headings inside notes and summaries move down to nest under their section.
public enum MeetingMarkdownExport {
    /// One tab: `# <title> - <Tab>`, then its content; nil when the tab is empty.
    public static func markdown(_ snapshot: MeetingExportSnapshot, section: MeetingExportSection) -> String? {
        guard let body = body(snapshot, section: section, level: 1) else { return nil }
        return "# \(line(snapshot.meeting.title)) - \(section.rawValue)\n\n" + body + "\n"
    }

    /// The whole meeting: title, description, then Notes, Summary, Transcript and
    /// Translation, leaving out sections without content.
    public static func markdown(all snapshot: MeetingExportSnapshot) -> String {
        var parts = ["# " + line(snapshot.meeting.title)]
        let description = snapshot.meeting.description.trimmingCharacters(in: .whitespacesAndNewlines)
        if !description.isEmpty { parts.append(escaped(description)) }
        for section in [MeetingExportSection.notes, .summary, .transcript, .translation] {
            if let body = body(snapshot, section: section, level: 2) { parts.append("## \(section.rawValue)\n\n" + body) }
        }
        return parts.joined(separator: "\n\n") + "\n"
    }

    /// `<Meeting> - <Tab>.md`, or `<Meeting>.md` for the whole meeting, with
    /// characters a file name cannot hold replaced by `-`.
    public static func fileName(title: String, section: MeetingExportSection?) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters).union(.newlines)
        var name = String(String.UnicodeScalarView(title.unicodeScalars.map { invalid.contains($0) ? "-" : $0 }))
            .trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ".")))
        if name.isEmpty { name = "Meeting" }
        return name + (section.map { " - \($0.rawValue)" } ?? "") + ".md"
    }

    /// The section body under a heading of `level`; nil when there is nothing.
    static func body(_ snapshot: MeetingExportSnapshot, section: MeetingExportSection, level: Int) -> String? {
        switch section {
        case .transcript:
            guard snapshot.transcript.contains(where: { if case .speech = $0 { true } else { false } }) else { return nil }
            return ((snapshot.provisional ? ["_Provisional live transcript._"] : []) + items(snapshot.transcript))
                .joined(separator: "\n\n")
        case .notes:
            guard let notes = snapshot.notes else { return nil }
            let text = notesMarkdown(notes, below: level)
            return text.isEmpty ? nil : text
        case .summary:
            guard !snapshot.summaries.isEmpty else { return nil }
            let heading = String(repeating: "#", count: min(level + 1, 6))
            return snapshot.summaries.map { summary in
                var parts = ["\(heading) Recording \(summary.number) · \(started(summary.recording))"]
                if summary.outdated { parts.append("_Outdated._") }
                let text = nested(summary.text, below: level + 1).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { parts.append(text) }
                return parts.joined(separator: "\n\n")
            }.joined(separator: "\n\n")
        case .translation:
            guard let translation = snapshot.translation, !translation.items.isEmpty else { return nil }
            var parts = ["_Translated to \(translation.language == .english ? "English" : "Russian")._"]
            if translation.outdated { parts.append("_Outdated._") }
            return (parts + items(translation.items)).joined(separator: "\n\n")
        }
    }

    /// Notes as Markdown, one paragraph per line except consecutive list items,
    /// with their headings nested below `level`. Plain-text revisions are escaped
    /// by `NotesDocument`, so their `#` and `*` stay literal.
    static func notesMarkdown(_ notes: NotesRevision, below level: Int) -> String {
        let document = notes.document
        var result = ""
        var previousList = false
        for paragraph in document.paragraphs {
            let markdown = NotesDocument(paragraphs: [paragraph]).markdown
            if paragraph.style == .body && paragraph.text.trimmingCharacters(in: .whitespaces).isEmpty { previousList = false; continue }
            if !result.isEmpty { result += paragraph.style.isList && previousList ? "\n" : "\n\n" }
            result += markdown
            previousList = paragraph.style.isList
        }
        return nested(result, below: level)
    }

    /// Each separator and speech block is its own paragraph, as the tab shows it.
    static func items(_ items: [TranscriptDisplayItem]) -> [String] {
        items.map { item in
            switch item {
            case .date(let day):
                // Generated text: a run of dashes followed by text is neither a rule nor a list.
                day.text + (day.note.map { "\n_\($0)_" } ?? "")
            case .speech(let block):
                escaped(block.text)
            }
        }
    }

    /// "October 5, 2026 at 16:00" in the recording's time zone, matching its separator.
    static func started(_ recording: Recording) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: recording.timeZoneIdentifier) ?? .current
        formatter.dateFormat = "yyyy-MM-dd"
        let date = TranscriptDateSeparator.display(formatter.string(from: recording.startedAt))
        formatter.dateFormat = "HH:mm"
        return "\(date) at \(formatter.string(from: recording.startedAt))"
    }

    /// Moves every heading outside code fences down so the shallowest one sits
    /// directly below `level`, clamped at `######`.
    static func nested(_ markdown: String, below level: Int) -> String {
        var lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var fenced = false
        var headings: [(index: Int, level: Int)] = []
        for (index, text) in lines.enumerated() {
            let trimmed = text.drop { $0 == " " }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { fenced.toggle(); continue }
            guard !fenced, text.hasPrefix("#") else { continue }
            let hashes = text.prefix { $0 == "#" }.count
            let rest = text.dropFirst(hashes)
            if hashes <= 6, rest.isEmpty || rest.hasPrefix(" ") { headings.append((index, hashes)) }
        }
        guard let shallowest = headings.map(\.level).min() else { return markdown }
        let shift = max(0, level + 1 - shallowest)
        for heading in headings {
            lines[heading.index] = String(repeating: "#", count: min(heading.level + shift, 6))
                + lines[heading.index].dropFirst(heading.level)
        }
        return lines.joined(separator: "\n")
    }

    /// Text that must read as text: each line starting like a Markdown block
    /// (heading, quote, list, numbered list, link label, rule, code indent) gets
    /// a backslash; the rest is verbatim.
    static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n").map { raw in
            let line = String(raw.drop { $0 == " " || $0 == "\t" })
            guard let first = line.first else { return line }
            if "#>-*+=[_|`~".contains(first) { return "\\" + line }
            let digits = line.prefix { $0.isASCII && $0.isNumber }
            if !digits.isEmpty, let next = line.dropFirst(digits.count).first, next == "." || next == ")" {
                return digits + "\\" + line.dropFirst(digits.count)
            }
            return line
        }.joined(separator: "\n")
    }

    /// A title on one line.
    private static func line(_ text: String) -> String {
        text.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }
}
