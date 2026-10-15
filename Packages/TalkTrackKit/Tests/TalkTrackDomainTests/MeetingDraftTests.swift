import Testing
import TalkTrackDomain

@Test(arguments: ["", " \n\t", "\u{00a0}\u{2003}"])
func blankMeetingTitlesAreRejected(_ title: String) {
    #expect(throws: MeetingDraft.ValidationError.emptyTitle) {
        try MeetingDraft(title: title)
    }
}

@Test func multilingualContentIsRetained() throws {
    let draft = try MeetingDraft(
        title: "  Обсуждение проекта \n", description: "Задачи\nна октябрь", language: .russian
    )
    #expect(draft.title == "Обсуждение проекта")
    #expect(draft.description == "Задачи\nна октябрь")
    #expect(draft.language == .russian)
}
