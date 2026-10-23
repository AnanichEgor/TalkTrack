import AVFoundation
import Foundation
import Testing
import TalkTrackDomain
@testable import TalkTrackServices

/// The library for the native interface review (task 9.5), exported only when
/// `TALKTRACK_UI_REVIEW_LIBRARY` names an empty folder: long Russian titles,
/// descriptions, speaker names and notes, many meetings, and one meeting with
/// a long two-day transcript over real (silent) AAC audio, so the player and
/// highlight work. Day speakers are inserted directly, as in the rename fixture;
/// no models or capture are used.
@Suite struct UIReviewFixtureTests {
    static let root = ProcessInfo.processInfo.environment["TALKTRACK_UI_REVIEW_LIBRARY"]

    static let phrases = [
        "Коллеги, давайте ещё раз пройдёмся по срокам: релиз переносится на конец ноября, потому что интеграционное тестирование заняло больше времени, чем мы планировали.",
        "Согласен, но тогда нужно предупредить отдел продаж и обновить дорожную карту на внутреннем портале.",
        "Я подготовлю письмо клиентам.",
        "По бюджету: мы уложились в 42 миллиона рублей, хотя расходы на облачную инфраструктуру выросли почти на треть по сравнению с прошлым кварталом.",
        "Хорошо. А что с переводом документации на английский язык — это успеем до релиза или придётся выпускать в два этапа?",
        "Да.",
        "Предлагаю вынести этот вопрос на отдельную встречу в четверг и пригласить туда Александру Константиновну из юридического отдела.",
    ]
    /// Hand-written English for the Translation tab, phrase by phrase.
    static let english = [
        "Colleagues, let's go over the schedule once more: the release moves to the end of November, because integration testing took longer than we planned.",
        "Agreed, but then we need to warn the sales team and update the roadmap on the internal portal.",
        "I'll prepare a letter to our clients.",
        "On the budget: we stayed within 42 million rubles, although cloud infrastructure costs grew by almost a third compared with last quarter.",
        "Good. What about translating the documentation into English — will we make it before the release, or will we ship in two stages?",
        "Yes.",
        "I suggest we move this question to a separate meeting on Thursday and invite Alexandra Konstantinovna from the legal department.",
    ]

    /// Returns the hand-written English of each row instead of running a model.
    struct FixtureTranslation: TranslationTextInference {
        func translationTokenCount(_ model: ModelSnapshot, settings: ProcessingSettings, system: String, prompt: String) async throws -> Int {
            180 + prompt.count / 4
        }
        func translationText(_ model: ModelSnapshot, settings: ProcessingSettings, system: String, prompt: String,
                             outputTokens: Int) async throws -> TranslationTextResponse {
            let rows = try JSONDecoder().decode([IndexedTranslation.Row].self, from: Data(prompt.utf8))
            let output = rows.map { row in
                IndexedTranslation.Row(id: row.id, text: UIReviewFixtureTests.phrases.firstIndex(of: row.text).map { UIReviewFixtureTests.english[$0] } ?? row.text)
            }
            return TranslationTextResponse(text: String(decoding: try JSONEncoder().encode(IndexedTranslation.Response(translations: output)), as: UTF8.self),
                contextPlan: try TextContextPlanner.resolve(selection: settings.contextLimit, role: .translation,
                                                            inputTokens: 180 + prompt.count / 4, outputTokens: outputTokens),
                generatedTokens: max(1, output.reduce(0) { $0 + $1.text.count / 4 }))
        }
    }

    @Test(.enabled(if: root != nil)) func exportReviewLibrary() async throws {
        let url = URL(fileURLWithPath: try #require(Self.root), isDirectory: true)
        let library = try await OwnedLibrary().open(root: url)
        let store = try await SessionStore.open(library)
        let physical = "/" + DirectoryHandle.physicalComponents(library.directory).dropFirst().joined(separator: "/")
        let db = try SQLiteConnection(path: physical + "/Library.sqlite3")

        // Sidebar: many meetings, short and very long Russian text.
        let others = [
            ("Еженедельная планёрка", "Короткое описание"),
            ("Стратегическая сессия по развитию продуктовой линейки и выходу на рынки Центральной Азии в 2027 году",
             "Обсуждение приоритетов, распределения бюджета между командами, найма, партнёрских соглашений и рисков, связанных с локализацией и требованиями регуляторов в каждой из стран."),
            ("1:1", ""),
            ("Interview — Senior iOS Engineer", "Second round, system design"),
        ]
        for index in 0..<24 {
            let (title, description) = others[index % others.count]
            _ = try await store.createMeeting(MeetingDraft(title: index < others.count ? title : "\(title) №\(index + 1)",
                                                           description: description))
        }
        _ = try await store.createMeeting(MeetingDraft(title: "Встреча без записей", description: "Ещё ничего не записано"))

        let meeting = try await store.createMeeting(MeetingDraft(
            title: "Квартальное планирование: бюджет, сроки релиза и перевод документации для международных клиентов",
            description: "Длинная встреча на два дня с несколькими участниками. Проверяем перенос длинных строк, прокрутку длинной расшифровки и поведение плеера.",
            language: .russian))

        // Three recordings of silence: 60 and 20 minutes on one day, each with its own
        // separator, then 30 minutes three days later (a resumption).
        let plan: [(minutes: Int, date: String)] = [(60, "2026-10-05T09:00:00Z"), (20, "2026-10-05T13:00:00Z"),
                                                    (30, "2026-10-08T14:30:00Z")]
        var recordings: [Recording] = []
        for (index, item) in plan.enumerated() {
            let date = ISO8601DateFormatter().date(from: item.date)!
            let seconds = Double(item.minutes * 60)
            let origin = AVAudioTime.hostTime(forSeconds: 1_000 + Double(index) * 10_000)
            let recording = try Recording(meetingID: meeting.id, startedAt: date, timeZoneIdentifier: "Europe/Moscow")
            let writer = try await RecordingAudioWriter.create(library: library, recording: recording)
            var clock = CaptureIntervalClock()
            try clock.begin(hostTime: origin, wallClock: date, timeZoneIdentifier: "Europe/Moscow")
            try await writer.updateCaptureTiming(try clock.close(at: origin + AVAudioTime.hostTime(forSeconds: seconds)), state: .recording)
            let frames = Int(seconds) * 48_000, block = 48_000
            let silence = [Float](repeating: 0, count: block)
            for track in AudioTrack.allCases {
                for offset in stride(from: 0, to: frames, by: block) {
                    try await writer.append(track: track, samples: silence, activeStartFrame: UInt64(offset),
                                            hostTimeStart: origin + AVAudioTime.hostTime(forSeconds: Double(offset) / 48_000))
                }
            }
            let finished = try await writer.finish().recording
            try await store.saveRecording(finished)
            recordings.append(finished)
        }

        // Three system voices per day plus the microphone, a turn every 3.5 s.
        var speakers: [DaySpeaker] = []
        for recording in recordings {
            for number in 1...3 {
                let speaker = DaySpeaker(meetingID: meeting.id, dayID: recording.days[0].id, number: UInt(number))
                try db.execute("INSERT INTO records VALUES ('daySpeaker',?,?,?,?)", [
                    .text(speaker.id.uuidString), .text(speaker.meetingID.uuidString), .text(speaker.dayID.uuidString),
                    .blob(DomainCodec.encode(speaker))])
                speakers.append(speaker)
            }
        }
        var blocks = 0
        for (index, recording) in recordings.enumerated() {
            let voices = speakers.filter { $0.dayID == recording.days[0].id }
            let duration = recording.activeDuration.seconds
            var segments: [TranscriptSegment] = []
            for (turn, start) in stride(from: 0.0, to: duration - 3, by: 3.5).enumerated() {
                let microphone = turn % 4 == 3
                segments.append(TranscriptSegment(recordingID: recording.id, dayID: recording.days[0].id,
                    track: microphone ? .microphone : .system,
                    interval: try MediaInterval(start: MediaTime(seconds: start), end: MediaTime(seconds: start + 3)),
                    wallClockStart: recording.startedAt.addingTimeInterval(start),
                    speaker: microphone ? .microphone : .system(daySpeakerID: voices[turn % 3].id),
                    originalText: Self.phrases[turn % Self.phrases.count]))
            }
            blocks += segments.count
            let job = try await store.enqueue(kind: .finalTranscription, meetingID: meeting.id, recordingID: recording.id,
                                              settings: ProcessingSettings(meetingLanguage: .russian), models: [])
            try await store.publishTranscript(TranscriptRevision(recordingID: recording.id, sourceGeneration: recording.generation,
                kind: .final, segments: segments, modelRevisions: []), jobID: job.id)
            // Long and short Russian names for the first day's voices.
            if index == 0 {
                for (voice, name) in zip(voices.prefix(2), ["Александра Константиновна Преображенская", "Илья"]) {
                    let segment = try #require(segments.first { $0.speaker == .system(daySpeakerID: voice.id) })
                    let target = try await store.speakerRenameTarget(meetingID: meeting.id, recordingID: recording.id, segmentID: segment.id)
                    _ = try await store.renameSpeaker(target, name: name)
                }
            }
        }

        let notes = NotesRevision(meetingID: meeting.id, text: """
            Итоги встречи
            • Релиз переносится на конец ноября; предупредить отдел продаж до пятницы.
            • Бюджет квартала — 42 млн ₽, облачная инфраструктура +31 %.
            • Перевод документации: отдельная встреча в четверг с юридическим отделом.

            Вопросы без ответа: кто отвечает за локализацию интерфейса на казахский и узбекский языки и успеваем ли мы пройти согласование с регуляторами до запуска?
            """)
        try await store.stageNotes(notes)
        try await store.commitNotes(notes)

        // A summary per recording, so deleting one shows in the Summary tab.
        let summaryModel = try ModelCatalog.bundled().model(for: .summary).snapshot(for: .summary)
        for recording in recordings {
            let job = try await store.enqueueSummary(meetingID: meeting.id, recordingID: recording.id,
                settings: ProcessingSettings(summaryLanguage: .russian, contextLimit: .defaultSelection), model: summaryModel)
            try await SummaryJobPipeline(store: store, inference: SummaryJobInference()).run(jobID: job.id)
        }

        let model = ModelSnapshot(role: .translation, repository: "fixture", revision: "1",
                                  directory: try RelativePath("fixture/1"), preprocessingVersion: "1")
        let translation = try await store.enqueueTranslation(meetingID: meeting.id, settings: ProcessingSettings(
            translationLanguage: .english, contextLimit: .defaultSelection, templateVersion: IndexedTranslation.version), model: model)
        try await TranslationJobPipeline(store: store, inference: FixtureTranslation()).run(jobID: translation.id)

        let snapshot = try await store.meetingTranscript(meetingID: meeting.id)
        #expect(snapshot.items.count > blocks / 2)
        try await store.close()
        print("UI review library: \(url.path) — \(blocks) segments, \(snapshot.items.count) transcript items")
    }
}
