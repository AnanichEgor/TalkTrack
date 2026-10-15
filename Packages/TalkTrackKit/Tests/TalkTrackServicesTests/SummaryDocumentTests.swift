import Foundation
import Testing
@testable import TalkTrackServices

struct SummaryDocumentTests {
    @Test func readsHeadingsPeopleTasksAndTimes() {
        let document = SummaryDocument(markdown: """
            ## Кто что делает
            - **Дима**: закончил импорт [09:01:05]
              - **Next:** тесты
            - **Voice3:** ждёт доступ

            ## Блокеры
            Не отмечено.

            ## Решения
            - [09:00:00] Дата запуска не меняется.

            ## Задачи
            - [ ] протестировать сборку 42 — Ответственный: You — Срок: завтра [09:00:00]
            - [x] Send the deck — Owner: not specified [14:03]
            Free text stays.
            """)
        #expect(document.blocks == [
            .heading("Кто что делает"),
            .item(.init(level: 0, task: nil, person: "Дима", text: "закончил импорт", owner: nil, due: nil, times: ["09:01:05"])),
            .item(.init(level: 1, task: nil, person: "Next", text: "тесты", owner: nil, due: nil, times: [])),
            .item(.init(level: 0, task: nil, person: "Voice3", text: "ждёт доступ", owner: nil, due: nil, times: [])),
            .heading("Блокеры"),
            .empty("Не отмечено."),
            .heading("Решения"),
            .item(.init(level: 0, task: nil, person: nil, text: "Дата запуска не меняется.", owner: nil, due: nil, times: ["09:00:00"])),
            .heading("Задачи"),
            .item(.init(level: 0, task: false, person: nil, text: "протестировать сборку 42", owner: "You", due: "завтра", times: ["09:00:00"])),
            .item(.init(level: 0, task: true, person: nil, text: "Send the deck", owner: "not specified", due: nil, times: ["14:03"])),
            .paragraph("Free text stays."),
        ])
    }

    @Test func readsDashedNamesAndTimesInParentheses() {
        let document = SummaryDocument(markdown: """
            - Дима - Задача заблокирована ожиданием ответа от Scott (09:40:12).
            - Voice 3 - ждёт (09:41:02, 09:42:10)
            - Решение принято - без имени
            """)
        #expect(document.blocks == [
            .item(.init(level: 0, task: nil, person: "Дима", text: "Задача заблокирована ожиданием ответа от Scott.", owner: nil, due: nil, times: ["09:40:12"])),
            .item(.init(level: 0, task: nil, person: "Voice 3", text: "ждёт", owner: nil, due: nil, times: ["09:41:02", "09:42:10"])),
            .item(.init(level: 0, task: nil, person: nil, text: "Решение принято - без имени", owner: nil, due: nil, times: [])),
        ])
    }

    @Test func keepsUnrecognizedShapesAsText() {
        let document = SummaryDocument(markdown: "#NoSpace\n-not a bullet\n- **bold** in the middle — keeps dash")
        #expect(document.blocks == [
            .paragraph("#NoSpace"), .paragraph("-not a bullet"),
            .item(.init(level: 0, task: nil, person: nil, text: "**bold** in the middle — keeps dash", owner: nil, due: nil, times: [])),
        ])
    }
}
