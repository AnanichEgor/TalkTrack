import AppKit
import SwiftUI
import TalkTrackDomain

/// The block styles the toolbar offers; lists are toggled separately.
enum NotesTextSize: String, CaseIterable, Identifiable {
    case title = "Title", heading = "Heading", body = "Body"
    var id: Self { self }

    var shortcut: String {
        switch self {
        case .title: "⇧⌘T"
        case .heading: "⇧⌘H"
        case .body: "⇧⌘B"
        }
    }
}

/// Toolbar state and commands for the notes text view.
@MainActor final class NotesEditorController: ObservableObject {
    @Published fileprivate(set) var size = NotesTextSize.body
    @Published fileprivate(set) var isBold = false
    @Published fileprivate(set) var isItalic = false
    @Published fileprivate(set) var list: NotesDocument.Style?
    @Published fileprivate(set) var isFocused = false
    fileprivate weak var textView: NotesTextView?

    func setSize(_ size: NotesTextSize) { textView?.setSize(size) }
    func toggleBold() { textView?.toggleTrait(.boldFontMask) }
    func toggleItalic() { textView?.toggleTrait(.italicFontMask) }
    func toggleBullets() { textView?.toggleList(.bullet) }
    func toggleChecklist() { textView?.toggleList(.task(done: false)) }
    func focus() {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
    }
}

/// Formatted notes over an AppKit text view. `markdown` is reported on every
/// edit; `document` is shown once per `loadID`.
struct NotesEditor: NSViewRepresentable {
    let document: NotesDocument
    let loadID: UUID
    let isEditable: Bool
    let controller: NotesEditorController
    let onChange: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let textView = NotesTextView(frame: scroll.contentView.bounds)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 14, height: 14)
        textView.drawsBackground = false
        textView.isRichText = true
        textView.allowsUndo = true
        textView.importsGraphics = false
        textView.usesFindBar = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.typingAttributes = NotesTextView.attributes(for: .body)
        textView.delegate = context.coordinator
        textView.controller = controller
        textView.setAccessibilityLabel("Meeting notes")
        scroll.documentView = textView
        controller.textView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NotesTextView else { return }
        context.coordinator.onChange = onChange
        textView.controller = controller
        controller.textView = textView
        textView.isEditable = isEditable
        if context.coordinator.loadID != loadID {
            context.coordinator.loadID = loadID
            textView.load(document)
        }
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var loadID: UUID?
        var onChange: (String) -> Void = { _ in }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NotesTextView else { return }
            textView.normalize()
            textView.publishState()
            onChange(textView.document.markdown)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            (notification.object as? NotesTextView)?.publishState()
        }

        func textView(_ textView: NSTextView, willChangeSelectionFromCharacterRange old: NSRange,
                      toCharacterRange new: NSRange) -> NSRange {
            (textView as? NotesTextView)?.outsideMarker(new, from: old) ?? new
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString text: String?) -> Bool {
            guard text == " ", let textView = textView as? NotesTextView else { return true }
            return !textView.autoformatList(before: range)
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard let textView = textView as? NotesTextView else { return false }
            switch selector {
            case #selector(NSResponder.insertNewline(_:)): return textView.insertParagraph()
            case #selector(NSResponder.deleteBackward(_:)): return textView.deleteMarker()
            default: return false
            }
        }
    }
}

/// A checklist box at the start of a task paragraph.
final class ChecklistAttachment: NSTextAttachment {
    let done: Bool

    init(done: Bool) {
        self.done = done
        super.init(data: nil, ofType: nil)
        let symbol = done ? "checkmark.circle.fill" : "circle"
        let color: NSColor = done ? .controlAccentColor : .secondaryLabelColor
        let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: done ? "Done" : "Not done")?
            .withSymbolConfiguration(configuration)
        bounds = CGRect(x: 0, y: -3, width: 17, height: 17)
    }

    required init?(coder: NSCoder) { nil }
}

final class NotesTextView: NSTextView {
    weak var controller: NotesEditorController?

    static let blockKey = NSAttributedString.Key("TalkTrackNotesBlock")
    static let bulletMarker = "•\t"
    static let attachmentCharacter = Character(UnicodeScalar(NSTextAttachment.character)!)

    // MARK: Styles

    static func font(for style: NotesDocument.Style, bold: Bool = false, italic: Bool = false) -> NSFont {
        var font: NSFont = switch style {
        case .title: .systemFont(ofSize: 24, weight: .bold)
        case .heading: .systemFont(ofSize: 18, weight: .semibold)
        case .body, .bullet, .task: .systemFont(ofSize: 15)
        }
        if bold { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
        if italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        return font
    }

    static func paragraphStyle(for style: NotesDocument.Style) -> NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        switch style {
        case .title:
            paragraph.paragraphSpacingBefore = 10
            paragraph.paragraphSpacing = 6
        case .heading:
            paragraph.paragraphSpacingBefore = 8
            paragraph.paragraphSpacing = 4
        case .body:
            paragraph.paragraphSpacing = 5
        case .bullet, .task:
            paragraph.paragraphSpacing = 4
            paragraph.firstLineHeadIndent = 4
            paragraph.headIndent = 28
            paragraph.tabStops = [NSTextTab(textAlignment: .left, location: 28)]
            paragraph.defaultTabInterval = 28
        }
        return paragraph
    }

    static func attributes(for style: NotesDocument.Style, bold: Bool = false, italic: Bool = false) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font(for: style, bold: bold, italic: italic),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraphStyle(for: style),
        ]
        switch style {
        case .title: attributes[blockKey] = "title"
        case .heading: attributes[blockKey] = "heading"
        case .body, .bullet, .task: break
        }
        return attributes
    }

    static func render(_ paragraphs: [NotesDocument.Paragraph]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (index, paragraph) in paragraphs.enumerated() {
            let base = attributes(for: paragraph.style)
            switch paragraph.style {
            case .bullet:
                result.append(NSAttributedString(string: bulletMarker, attributes: base.merging([.foregroundColor: NSColor.secondaryLabelColor]) { $1 }))
            case .task(let done):
                let box = NSMutableAttributedString(attachment: ChecklistAttachment(done: done))
                box.addAttributes(base, range: NSRange(location: 0, length: box.length))
                box.append(NSAttributedString(string: "\t", attributes: base))
                result.append(box)
            case .title, .heading, .body: break
            }
            for run in paragraph.runs {
                result.append(NSAttributedString(string: run.text, attributes: attributes(for: paragraph.style, bold: run.bold, italic: run.italic)))
            }
            if index < paragraphs.count - 1 { result.append(NSAttributedString(string: "\n", attributes: base)) }
        }
        return result
    }

    // MARK: Reading the text back

    private var nsString: NSString { string as NSString }

    /// Paragraph ranges without their line breaks, covering `range`.
    private func paragraphs(in range: NSRange) -> [NSRange] {
        var result: [NSRange] = []
        var location = nsString.paragraphRange(for: NSRange(location: range.location, length: 0)).location
        repeat {
            let full = nsString.paragraphRange(for: NSRange(location: location, length: 0))
            var content = full
            if content.length > 0, nsString.character(at: NSMaxRange(content) - 1) == 10 { content.length -= 1 }
            result.append(content)
            location = NSMaxRange(full)
        } while location < NSMaxRange(range) && location < nsString.length
        // A trailing line break opens one more, empty paragraph.
        if location == nsString.length, NSMaxRange(range) == nsString.length, nsString.length > 0,
           nsString.character(at: nsString.length - 1) == 10, result.last.map(NSMaxRange) != nsString.length {
            result.append(NSRange(location: nsString.length, length: 0))
        }
        return result
    }

    /// The list marker's length and style at the start of a paragraph.
    private func marker(_ paragraph: NSRange) -> (length: Int, style: NotesDocument.Style)? {
        guard paragraph.length >= 2, let storage = textStorage else { return nil }
        if nsString.substring(with: NSRange(location: paragraph.location, length: 2)) == Self.bulletMarker { return (2, .bullet) }
        if nsString.character(at: paragraph.location + 1) == 9,
           let box = storage.attribute(.attachment, at: paragraph.location, effectiveRange: nil) as? ChecklistAttachment {
            return (2, .task(done: box.done))
        }
        return nil
    }

    private func style(_ paragraph: NSRange) -> NotesDocument.Style {
        if let marker = marker(paragraph) { return marker.style }
        guard let storage = textStorage, paragraph.location < storage.length else {
            return Self.blockStyle(typingAttributes)
        }
        return Self.blockStyle(storage.attributes(at: paragraph.location, effectiveRange: nil))
    }

    private static func blockStyle(_ attributes: [NSAttributedString.Key: Any]) -> NotesDocument.Style {
        switch attributes[blockKey] as? String {
        case "title": .title
        case "heading": .heading
        default: .body
        }
    }

    private func paragraphModel(_ range: NSRange) -> NotesDocument.Paragraph {
        let style = style(range)
        var content = range
        if let marker = marker(range) { content = NSRange(location: range.location + marker.length, length: range.length - marker.length) }
        var runs: [NotesDocument.Run] = []
        textStorage?.enumerateAttribute(.font, in: content) { value, runRange, _ in
            let text = nsString.substring(with: runRange).filter { $0 != Self.attachmentCharacter }
            let traits = (value as? NSFont).map { NSFontManager.shared.traits(of: $0) } ?? []
            runs.append(NotesDocument.Run(text, bold: traits.contains(.boldFontMask), italic: traits.contains(.italicFontMask)))
        }
        return NotesDocument.Paragraph(style, runs: runs.filter { !$0.text.isEmpty })
    }

    var document: NotesDocument {
        NotesDocument(paragraphs: paragraphs(in: NSRange(location: 0, length: nsString.length)).map(paragraphModel))
    }

    func load(_ document: NotesDocument) {
        textStorage?.setAttributedString(Self.render(document.paragraphs))
        undoManager?.removeAllActions()
        typingAttributes = Self.attributes(for: .body)
        setSelectedRange(NSRange(location: nsString.length, length: 0))
        normalize()
        publishState()
    }

    // MARK: Keeping paragraphs consistent

    /// Re-applies paragraph layout, heading markers and done-task styling
    /// after edits that joined or split paragraphs.
    func normalize() {
        guard let storage = textStorage, storage.length > 0 else { return }
        storage.beginEditing()
        for paragraph in paragraphs(in: NSRange(location: 0, length: storage.length)) {
            let style = style(paragraph)
            var full = paragraph
            if NSMaxRange(full) < storage.length { full.length += 1 }
            guard full.length > 0 else { continue }
            storage.addAttribute(.paragraphStyle, value: Self.paragraphStyle(for: style), range: full)
            switch style {
            case .title: storage.addAttribute(Self.blockKey, value: "title", range: full)
            case .heading: storage.addAttribute(Self.blockKey, value: "heading", range: full)
            case .body, .bullet, .task: storage.removeAttribute(Self.blockKey, range: full)
            }
            let start = marker(paragraph)?.length ?? 0
            let content = NSRange(location: paragraph.location + start, length: paragraph.length - start)
            if case .task(true) = style {
                storage.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue,
                                       .foregroundColor: NSColor.secondaryLabelColor], range: content)
            } else {
                storage.removeAttribute(.strikethroughStyle, range: content)
                storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: content)
            }
            if style == .bullet {
                storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: NSRange(location: paragraph.location, length: 1))
            }
        }
        storage.endEditing()
    }

    /// Keeps the caret out of list markers: moving left from an item's text
    /// goes to the previous line, any other landing goes after the marker.
    func outsideMarker(_ new: NSRange, from old: NSRange) -> NSRange {
        guard new.length == 0, new.location <= nsString.length else { return new }
        let paragraph = paragraphs(in: NSRange(location: new.location, length: 0))[0]
        guard let marker = marker(paragraph), new.location < paragraph.location + marker.length else { return new }
        if old.length == 0, old.location == paragraph.location + marker.length, paragraph.location > 0, new.location < old.location {
            return NSRange(location: paragraph.location - 1, length: 0)
        }
        return NSRange(location: paragraph.location + marker.length, length: 0)
    }

    // MARK: Editing commands

    /// Return continues a list, leaves an empty item, and ends a heading.
    func insertParagraph() -> Bool {
        let selection = selectedRange()
        let paragraph = paragraphs(in: selection)[0]
        let style = style(paragraph)
        if let marker = marker(paragraph) {
            if paragraph.length == marker.length {
                replace(paragraph, with: Self.render([NotesDocument.Paragraph()]), caret: 0)
                typingAttributes = Self.attributes(for: .body)
                return true
            }
            let next: NotesDocument.Style = if case .task = style { .task(done: false) } else { .bullet }
            let addition = NSMutableAttributedString(string: "\n", attributes: Self.attributes(for: .body))
            addition.append(Self.render([NotesDocument.Paragraph(next)]))
            replace(selection, with: addition, caret: addition.length)
            typingAttributes = Self.attributes(for: .body)
            return true
        }
        if style == .title || style == .heading, NSMaxRange(selection) == NSMaxRange(paragraph) {
            let addition = NSAttributedString(string: "\n", attributes: Self.attributes(for: style))
            replace(selection, with: addition, caret: 1)
            typingAttributes = Self.attributes(for: .body)
            return true
        }
        return false
    }

    /// Backspace right after a list marker removes the marker only.
    func deleteMarker() -> Bool {
        let selection = selectedRange()
        guard selection.length == 0 else { return false }
        let paragraph = paragraphs(in: selection)[0]
        guard let marker = marker(paragraph), selection.location == paragraph.location + marker.length else { return false }
        var model = paragraphModel(paragraph)
        model.style = .body
        replace(paragraph, with: Self.render([model]), caret: 0)
        return true
    }

    func setSize(_ size: NotesTextSize) {
        let style: NotesDocument.Style = switch size {
        case .title: .title
        case .heading: .heading
        case .body: .body
        }
        restyle { model in
            // Headings are bold by themselves; leaving one drops that weight.
            if model.style == .title || model.style == .heading {
                model.runs = model.runs.map { NotesDocument.Run($0.text, italic: $0.italic) }
            }
            model.style = style
        }
        if nsString.length == 0 || selectedRange().location == nsString.length && nsString.hasSuffix("\n") {
            typingAttributes = Self.attributes(for: style)
        }
        publishState()
    }

    func toggleList(_ list: NotesDocument.Style) {
        let affected = paragraphs(in: selectedRange())
        let isSame: (NotesDocument.Style) -> Bool = { style in
            switch (style, list) {
            case (.bullet, .bullet), (.task, .task): true
            default: false
            }
        }
        let remove = affected.allSatisfy { isSame(style($0)) }
        restyle { model in
            if model.style == .title || model.style == .heading {
                model.runs = model.runs.map { NotesDocument.Run($0.text, italic: $0.italic) }
            }
            model.style = remove ? .body : (isSame(model.style) ? model.style : list)
        }
        typingAttributes = Self.attributes(for: .body)
        publishState()
    }

    /// Rebuilds the selected paragraphs through the document model, keeping a
    /// single caret at the same place in its text.
    private func restyle(_ change: (inout NotesDocument.Paragraph) -> Void) {
        let selection = selectedRange()
        let affected = paragraphs(in: selection)
        guard let first = affected.first, let last = affected.last else { return }
        let union = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
        var models = affected.map(paragraphModel)
        for index in models.indices { change(&models[index]) }
        let rendered = Self.render(models)
        if affected.count == 1, selection.length == 0 {
            let oldStart = marker(first)?.length ?? 0
            let newStart = rendered.length - models[0].text.utf16.count
            let offset = max(0, selection.location - first.location - oldStart)
            replace(union, with: rendered, caret: min(rendered.length, newStart + offset))
        } else {
            replace(union, with: rendered, caret: nil)
        }
    }

    /// A space after `-` or `*` at the start of a line starts a bulleted list;
    /// after `[]` or `[ ]`, a checklist.
    func autoformatList(before range: NSRange) -> Bool {
        guard range.length == 0, !isApplyingAutoformat else { return false }
        let paragraph = paragraphs(in: range)[0]
        guard marker(paragraph) == nil, style(paragraph) == .body else { return false }
        let typed = nsString.substring(with: NSRange(location: paragraph.location, length: range.location - paragraph.location))
        let list: NotesDocument.Style
        switch typed {
        case "-", "*": list = .bullet
        case "[]", "[ ]": list = .task(done: false)
        default: return false
        }
        isApplyingAutoformat = true
        defer { isApplyingAutoformat = false }
        var model = paragraphModel(NSRange(location: range.location, length: NSMaxRange(paragraph) - range.location))
        model.style = list
        let rendered = Self.render([model])
        replace(paragraph, with: rendered, caret: 2)
        typingAttributes = Self.attributes(for: .body)
        publishState()
        return true
    }

    private var isApplyingAutoformat = false

    /// Marks the checklist items in the selection done, or not done when all are.
    func toggleTasksInSelection() {
        let tasks = paragraphs(in: selectedRange()).filter { if case .task = style($0) { true } else { false } }
        guard !tasks.isEmpty else { return }
        let allDone = tasks.allSatisfy { style($0) == .task(done: true) }
        let selection = selectedRange()
        undoManager?.beginUndoGrouping()
        for paragraph in tasks where style(paragraph) == .task(done: allDone) { toggleTask(at: paragraph.location) }
        undoManager?.endUndoGrouping()
        setSelectedRange(selection)
    }

    func toggleTrait(_ trait: NSFontTraitMask) {
        let selection = selectedRange()
        let manager = NSFontManager.shared
        if selection.length == 0 {
            if let font = typingAttributes[.font] as? NSFont {
                let has = manager.traits(of: font).contains(trait)
                typingAttributes[.font] = has ? manager.convert(font, toNotHaveTrait: trait) : manager.convert(font, toHaveTrait: trait)
            }
            publishState()
            return
        }
        guard let storage = textStorage else { return }
        var all = true
        storage.enumerateAttribute(.font, in: selection) { value, range, stop in
            guard nsString.substring(with: range).contains(where: { $0 != "\t" && $0 != "•" && $0 != Self.attachmentCharacter }) else { return }
            if let font = value as? NSFont, !manager.traits(of: font).contains(trait) { all = false; stop.pointee = true }
        }
        guard shouldChangeText(in: selection, replacementString: nil) else { return }
        storage.beginEditing()
        storage.enumerateAttribute(.font, in: selection) { value, range, _ in
            guard let font = value as? NSFont else { return }
            storage.addAttribute(.font, value: all ? manager.convert(font, toNotHaveTrait: trait) : manager.convert(font, toHaveTrait: trait), range: range)
        }
        storage.endEditing()
        didChangeText()
    }

    func toggleTask(at index: Int) {
        guard let storage = textStorage, index < storage.length,
              let box = storage.attribute(.attachment, at: index, effectiveRange: nil) as? ChecklistAttachment else { return }
        let range = NSRange(location: index, length: 1)
        let replacement = NSMutableAttributedString(attachment: ChecklistAttachment(done: !box.done))
        replacement.addAttributes(storage.attributes(at: index, effectiveRange: nil).filter { $0.key != .attachment }, range: NSRange(location: 0, length: 1))
        guard shouldChangeText(in: range, replacementString: replacement.string) else { return }
        storage.replaceCharacters(in: range, with: replacement)
        didChangeText()
    }

    private func replace(_ range: NSRange, with text: NSAttributedString, caret: Int?) {
        guard shouldChangeText(in: range, replacementString: text.string) else { return }
        textStorage?.replaceCharacters(in: range, with: text)
        didChangeText()
        setSelectedRange(caret.map { NSRange(location: range.location + $0, length: 0) }
                         ?? NSRange(location: range.location, length: text.length))
    }

    // MARK: Toolbar state

    func publishState() {
        guard let controller else { return }
        let selection = selectedRange()
        let paragraph = paragraphs(in: NSRange(location: min(selection.location, nsString.length), length: 0))[0]
        let style = style(paragraph)
        controller.size = switch style {
        case .title: .title
        case .heading: .heading
        case .body, .bullet, .task: .body
        }
        controller.list = style.isList ? style : nil
        var font = typingAttributes[.font] as? NSFont
        if selection.length > 0, let storage = textStorage {
            font = storage.attribute(.font, at: selection.location, effectiveRange: nil) as? NSFont
        }
        let traits = font.map { NSFontManager.shared.traits(of: $0) } ?? []
        controller.isBold = traits.contains(.boldFontMask) && (style != .title && style != .heading)
        controller.isItalic = traits.contains(.italicFontMask)
    }

    // MARK: Events

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let index = checkbox(at: point) {
            toggleTask(at: index)
            return
        }
        super.mouseDown(with: event)
    }

    /// A checklist circle responds to the first click even in a background window.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        guard let event else { return false }
        return checkbox(at: convert(event.locationInWindow, from: nil)) != nil
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard let layoutManager, let container = textContainer, let storage = textStorage else { return }
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard value is ChecklistAttachment else { return }
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
            rect.origin.x += textContainerOrigin.x
            rect.origin.y += textContainerOrigin.y
            addCursorRect(rect, cursor: .pointingHand)
        }
    }

    private func checkbox(at point: NSPoint) -> Int? {
        guard let layoutManager, let container = textContainer, let storage = textStorage, storage.length > 0 else { return nil }
        let local = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = layoutManager.glyphIndex(for: local, in: container)
        let index = layoutManager.characterIndexForGlyph(at: glyph)
        guard index < storage.length, storage.attribute(.attachment, at: index, effectiveRange: nil) is ChecklistAttachment else { return nil }
        let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).insetBy(dx: -3, dy: -3)
        return rect.contains(local) ? index : nil
    }

    override func paste(_ sender: Any?) { pasteAsPlainText(sender) }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, isEditable else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased()
        switch (flags, key) {
        case ([.command], "b"): toggleTrait(.boldFontMask)
        case ([.command], "i"): toggleTrait(.italicFontMask)
        case ([.command, .shift], "t"): setSize(.title)
        case ([.command, .shift], "h"): setSize(.heading)
        case ([.command, .shift], "b"): setSize(.body)
        case ([.command, .shift], "7"), ([.command, .shift], "&"): toggleList(.bullet)
        case ([.command, .shift], "l"): toggleList(.task(done: false))
        case ([.command, .shift], "u"): toggleTasksInSelection()
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { controller?.isFocused = true }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { controller?.isFocused = false }
        return result
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty else { return }
        let origin = NSPoint(x: textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0), y: textContainerOrigin.y)
        let placeholder = isEditable ? "Write your notes here…" : "Loading notes…"
        placeholder.draw(at: origin, withAttributes: [.font: Self.font(for: .body), .foregroundColor: NSColor.placeholderTextColor])
    }
}

/// Size, emphasis and list controls above the notes field.
struct NotesToolbar: View {
    @ObservedObject var controller: NotesEditorController
    let isEnabled: Bool
    var export: ExportButton?

    var body: some View {
        HStack(spacing: 4) {
            if let export {
                export
                Divider().frame(height: 18).padding(.horizontal, 4)
            }
            Picker("Text size", selection: Binding(get: { controller.size }, set: { controller.setSize($0) })) {
                ForEach(NotesTextSize.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden().pickerStyle(.segmented).fixedSize()
            .help("Text size: Title \(NotesTextSize.title.shortcut), Heading \(NotesTextSize.heading.shortcut), Body \(NotesTextSize.body.shortcut)")
            Divider().frame(height: 18).padding(.horizontal, 4)
            NotesToolbarButton(symbol: "bold", label: "Bold", help: "Bold (⌘B)", isOn: controller.isBold, action: controller.toggleBold)
            NotesToolbarButton(symbol: "italic", label: "Italic", help: "Italic (⌘I)", isOn: controller.isItalic, action: controller.toggleItalic)
            Divider().frame(height: 18).padding(.horizontal, 4)
            NotesToolbarButton(symbol: "list.bullet", label: "Bulleted list", help: "Bulleted list (⇧⌘7)",
                               isOn: controller.list == .bullet, action: controller.toggleBullets)
            NotesToolbarButton(symbol: "checklist", label: "Checklist", help: "Checklist (⇧⌘L). Click a circle or press ⇧⌘U to mark an item done",
                               isOn: { if case .task = controller.list { true } else { false } }(), action: controller.toggleChecklist)
            Spacer(minLength: 8)
            Text("Saved automatically").font(.caption).foregroundStyle(.secondary)
        }
        .disabled(!isEnabled)
    }
}

private struct NotesToolbarButton: View {
    let symbol: String
    let label: String
    let help: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 24)
                .background(isOn ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(isOn ? Color.accentColor : .primary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

