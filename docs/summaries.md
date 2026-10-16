# Summaries and translation

How TalkTrack turns a final transcript into summaries and a translation, where
the prompts come from, what the user sees while it runs, and what is not
guaranteed.

## Provenance of templates and prompts

- **Organization.** The registry of summary types with immutable prompt
  snapshots follows Muesli's `MeetingTemplates.swift` / `MeetingSummaryClient.swift`
  at commit `d457aaf94691a73afd2867f5a6ca7fdd203044db` (MIT, notice in
  `ThirdParty/Muesli-LICENSE`). Only the organization was adapted: sections,
  rules, grounding instructions and the checks are TalkTrack's own
  (`SummaryTemplates.swift`).
- **Types.** Auto, One-to-One, Customer Discovery, Hiring Interview, Standup,
  Weekly Review; each has English and Russian headings and type-specific rules.
- **Grounding.** The system prompt asks for facts only from the tagged source,
  owners only when someone committed or was named, "X will…" as an action item
  rather than a decision, the line's own time as the citation, and never a time
  in the deadline slot. Source text is tagged data; instructions inside it are
  speech, not commands (checked with planted injections).
- **Versions.** A version never changes once shipped; each job snapshots it as
  `ProcessingSettings.templateVersion`, so retries reproduce the same prompt and
  older summaries are shown Outdated rather than silently re-prompted.
  - 1 (2026-10-12): a whole meeting with its notes.
  - 2 (2026-10-13): one recording, no notes, the recording date as
    `<recording_date>`.
  - 3 (2026-10-14): Standup leaves out people who said nothing substantive.
  - 4 (2026-10-16): the Russian Standup heading is "Обновления по участникам"
    (the old "Кто что делает" read as a task list); per-person updates are
    reports, not tasks, and work already done is never an action item; Blockers
    include waiting, missing access and unclear requirements; decisions are cited
    bullets; small talk is left out; summaries in another language than the
    meeting are translated faithfully, keeping names as written. A format retry
    is told what the rejected answer got wrong (`SummaryCheck.formatProblems`),
    and bullets that only say there is nothing to report are removed
    (`SummaryCheck.withoutEmptyBullets`).
- **Sampling.** `TextSampling.summary`: temperature 0.2, repetition penalty
  1.05, fixed seed (seed + attempt on the one retry); thinking mode is off.
- **Translation.** `IndexedTranslation.version` 1: indexed batches of at most 16
  utterance texts; labels, dates, `You` and timestamps are copied from the
  frozen source, never read from the model.

## Complete-input chunking

`MeetingSummarizer` (`SummaryChunking.swift`) counts every chat-formatted request
with the job's own tokenizer and never clips input:

1. **Direct** when the input plus the summary reserve fits the selected context
   (Auto picks the smallest of 4K–64K; default 32K).
2. **Parts** otherwise: transcript blocks are packed in order into parts; a
   block too large alone is split at word boundaries and each piece keeps its
   `[time]: Speaker - ` prefix and date line. Each part becomes notes.
3. **Merge rounds** while the notes do not fit the final request.
4. **Final** templated summary over the notes.

Coverage is checked: every unit belongs to exactly one part. A response that
hits its output limit or repeats itself is retried on halves; what cannot be
split further fails with an error instead of a shortened summary. Translation
batches follow the same rule (halve, retry a single row once, split an oversized
utterance and rejoin it under its segment ID).

## Generation states

Summaries and translations run only when the user asks (`Generate Summaries`,
per-recording `Regenerate`, `Translate Transcript`); Stop queues only final
transcription. Each request freezes an immutable source (one recording's final
revision and speaker names for a summary; all recordings for a translation)
plus type, language, context, template/prompt version and model revision.

| State | Shown as | What the user can do |
|---|---|---|
| Not available | the reason (no final transcript yet, transcription unfinished) | wait |
| Queued | "Summary queued…" | Cancel |
| Running | progress such as part *n* of *m*, merging, final | Cancel |
| Waiting for models | missing model named | Download Model, then Retry |
| Failed / interrupted / cancelled | error text; the previous result stays | Retry (same frozen source) |
| Completed | the result, its type, language and date | Copy, Regenerate |
| Outdated | the saved result with Outdated | Regenerate when wanted |

Only a complete, structurally valid result replaces the saved one, in the same
SQLite transaction that completes the job. Capture pauses text work; Quit
cancels and requeues the running job; an abrupt exit leaves it interrupted with
Retry. A summary becomes Outdated when its recording's transcript or speaker
names, the meeting title/description, or the type/language/context/template
version change; a translation when the transcript, names, language, context or
prompt version change. Notes never mark either Outdated, and neither ever
changes notes. Nothing regenerates automatically.

## Display

The stored summary is Markdown. `SummaryDocument` reads it for display only
(headings, bullets, `Name - …` / `**Name**:` people, action items with
owner/deadline fields, cited times); unrecognized lines stay paragraphs, so no
text is lost. Each name always gets the same colour; `You` matches the
transcript. The Copy button copies the stored Markdown.

## Limitations

- Checks are structural: required headings in order, no extra or repeated
  headings, well-formed action items, citations inside the recording, every
  translated row exactly once. They cannot prove that a summary is factually or
  temporally right; observed errors include a wrong owner and a task reported
  done on a later day kept as open.
- The 9B model does not always follow the Standup omission rule; a filter
  removes groups of speakers with fewer than 20 words, so a short but real
  update can be dropped and a long off-topic remark kept.
- Russian translation writes personal names inside utterances in their Russian
  form and may change number separators; values, IDs and labels are unchanged.
- Summary colours of people are by name and can differ from the transcript's
  voice colours; two names can share a colour.
- Very long meetings take several minutes at small contexts (8 parts and a merge
  round at 4K for ~20K tokens); memory admission can refuse a large context when
  other apps use RAM.
