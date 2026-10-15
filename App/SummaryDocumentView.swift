import AppKit
import SwiftUI
import TalkTrackServices

/// A generated summary laid out for reading: section headings with icons,
/// people's names in their own colour, action items with owner and deadline,
/// and cited transcript times as small marks. The text stays selectable.
struct SummaryDocumentView: View {
    let document: SummaryDocument

    init(markdown: String) { document = SummaryDocument(markdown: markdown) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(document.blocks.enumerated()), id: \.offset) { index, block in
                row(block, first: index == 0)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: 760, alignment: .leading)
    }

    @ViewBuilder private func row(_ block: SummaryDocument.Block, first: Bool) -> some View {
        switch block {
        case .heading(let title):
            VStack(alignment: .leading, spacing: 6) {
                Label {
                    Text(title).font(.title3.weight(.semibold))
                } icon: {
                    Image(systemName: Self.icon(title)).foregroundStyle(.tint).font(.body.weight(.medium))
                }
                Divider()
            }
            .padding(.top, first ? 0 : 22).padding(.bottom, 8)
            .accessibilityAddTraits(.isHeader)
        case .empty(let text):
            Text(text).font(.body).italic().foregroundStyle(.secondary).padding(.vertical, 3)
        case .paragraph(let text):
            Text(Self.inline(text)).font(.body).lineSpacing(3).padding(.vertical, 4)
                .fixedSize(horizontal: false, vertical: true)
        case .item(let item):
            itemRow(item)
        }
    }

    private func itemRow(_ item: SummaryDocument.Item) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Group {
                if let checked = item.task {
                    Image(systemName: checked ? "checkmark.square" : "square").foregroundStyle(.secondary)
                } else {
                    Text(item.level == 0 ? "•" : "◦").foregroundStyle(.secondary)
                }
            }
            .frame(width: 14, alignment: .center)
            VStack(alignment: .leading, spacing: 4) {
                line(item)
                if item.task != nil, item.owner != nil || item.due != nil || !item.times.isEmpty {
                    HStack(spacing: 14) {
                        if let owner = item.owner {
                            Label { Text(owner).foregroundStyle(Self.unspecified(owner) ? .secondary : Self.personColor(owner)).fontWeight(.medium) }
                                icon: { Image(systemName: "person").foregroundStyle(.secondary) }
                                .help("Owner")
                        }
                        if let due = item.due {
                            Label { Text(due).fontWeight(.medium) } icon: { Image(systemName: "calendar").foregroundStyle(.secondary) }
                                .help("Due")
                        }
                        if !item.times.isEmpty {
                            Label { Text(item.times.joined(separator: ", ")).monospacedDigit() }
                                icon: { Image(systemName: "clock").foregroundStyle(.secondary) }
                                .foregroundStyle(.secondary).help("Time in the transcript")
                        }
                    }
                    .font(.callout)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(item.level) * 22)
        .padding(.vertical, item.task == nil ? 3 : 5)
    }

    /// Person, text and time marks as one wrapping text.
    private func line(_ item: SummaryDocument.Item) -> some View {
        var text = AttributedString()
        if let person = item.person {
            var name = AttributedString(person)
            name.font = .body.weight(.semibold)
            name.foregroundColor = Self.personColor(person)
            text += name
            if !item.text.isEmpty { text += AttributedString(item.text.first?.isPunctuation == true ? "" : ": ") }
        }
        text += Self.inline(item.text)
        for time in item.task == nil ? item.times : [] {
            text += AttributedString("  ")
            var mark = AttributedString("\u{2009}\(time)\u{2009}")
            mark.font = .callout.monospacedDigit()
            mark.foregroundColor = .secondary
            mark.backgroundColor = Color.secondary.opacity(0.12)
            text += mark
        }
        return Text(text).font(.body).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
    }

    /// Bold and italics from the summary's Markdown; plain text if it does not parse.
    static func inline(_ markdown: String) -> AttributedString {
        (try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(markdown)
    }

    static func unspecified(_ owner: String) -> Bool {
        ["not specified", "не указан"].contains(owner.lowercased())
    }

    /// The same name always gets the same colour; "You" matches the transcript.
    static func personColor(_ name: String) -> Color {
        let key = name.trimmingCharacters(in: .whitespaces).lowercased()
        if key == "you" { return Color.readable(.systemTeal) }
        let palette: [NSColor] = [.systemBlue, .systemPurple, .systemOrange, .systemPink, .systemIndigo, .systemBrown, .systemGreen, .systemCyan]
        let hash = key.unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value }
        return Color.readable(palette[Int(hash % UInt32(palette.count))])
    }

    /// An icon for a template heading in either language.
    static func icon(_ title: String) -> String {
        let english = SummaryTemplates.current.lazy.flatMap(\.sections)
            .first { $0.english == title || $0.russian == title }?.english ?? title
        return switch english {
        case "Summary", "Highlights": "text.quote"
        case "Key Points", "Experience Discussed": "list.bullet"
        case "Decisions": "checkmark.seal"
        case "Action Items", "Next Steps": "checklist"
        case "Open Questions", "Candidate's Questions": "questionmark.bubble"
        case "Updates by Person", "Updates": "person.2"
        case "Blockers", "Concerns and Blockers", "Risks and Issues", "Concerns": "exclamationmark.triangle"
        case "Feedback": "bubble.left.and.bubble.right"
        case "For Next Time", "Next Week": "calendar"
        case "Customer Context", "Candidate Overview": "person.text.rectangle"
        case "Problems and Pain Points": "bandage"
        case "Current Workflow and Tools": "wrench.and.screwdriver"
        case "Needs and Requests": "star"
        case "Buying Process": "creditcard"
        case "Strengths": "hand.thumbsup"
        case "Logistics": "shippingbox"
        case "Progress by Area": "chart.bar"
        case "Metrics": "number"
        default: "doc.text"
        }
    }
}
