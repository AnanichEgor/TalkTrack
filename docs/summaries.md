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
  - 5 (2026-11-11): same sections and rules. Notes on the parts of a long
    recording are grouped under plain labels ("Topics:", "Facts and numbers:" …)
    instead of `## ` headings, and the final summary is told the labels are not
    its headings: with `##` notes, 9B at 8K copied `## Facts and Numbers` into
    summaries and failed the format check (`SummaryPrompt.labelledNotes`).
    Custom templates are snapshotted with the current version. Prompts contain
    no Russian: for a Russian summary they name the headings and the fixed
    words ("None noted.", "Owner:", "Owner: not specified", "Due:") in English
    and ask for the content in Russian; the format check runs on that English
    frame, then `SummaryCheck.localizedFrame` puts in the Russian headings and
    words before saving. An imported template's own headings are used verbatim.
- **Sampling.** `TextSampling.summary`: temperature 0.2, repetition penalty
  1.05, fixed seed (seed + attempt on the one retry); thinking mode is off.
- **Translation.** `IndexedTranslation.version` 1: indexed batches of at most 16
  utterance texts; labels, dates, `You` and timestamps are copied from the
  frozen source, never read from the model.

## Custom templates

Users add their own summary types by importing a Markdown file (Settings ▸
Summaries ▸ Import Template…); there is no in-app editor.

- **Format.** A header between `---` lines with `name` (required), `purpose`,
  `rules` (a list) and `per_person`, then one `## Heading` and its explanation
  per section (`SummaryTemplateFile`). Headings appear in the summary exactly as
  written, whatever the summary language. Decisions, Action Items and Open
  Questions (English or Russian, any case) may have no explanation and then take
  the built-in guidance. One code fence around the whole file is ignored.
- **Bundled guide and example.** `TalkTrack Summary Template Guide.md` and
  `Example Template.md` are TalkTrackServices resources, in English only; Settings
  ▸ Summaries ▸ Download Guide & Example… saves both. The guide has a section for
  AI assistants that write a template from the user's description.
- **Same core.** A custom template is a `SummaryTemplate` of type `.custom` over
  the current prompt core: grounding, action-item form, citations, translation,
  format checks and retries, long-meeting chunking and the empty-bullet filter
  are the built-in ones. Only sections, explanations and rules differ. The
  brief-speaker filter runs only in the section named by `per_person`, which also
  adds Standup's per-person rule.
- **Validation** (`SummaryTemplateValidator`, no model needed). Errors refuse the
  import with their line: no header, missing or long name, unknown or repeated
  header field (with a suggestion for typos), no sections or more than 12, bad or
  repeated headings, a section without explanation, a `#` line in an
  explanation, `per_person` naming no section, a field over its limit, or a
  template over the size budget. Warnings never block: more than 8 sections,
  very short explanations, requests for tables/JSON/numbering/headings,
  computed times or guessed speakers, rules that repeat the core, headings in
  another language than the summary language, nearly identical explanations.
- **Size budget.** Sections, explanations and rules are estimated as UTF-8
  bytes / 3 and limited to 700 estimated tokens; explanations to 600 and rules
  to 400 characters, at most 10 rules, names and headings to 60. Measured with
  the 9B and 4B tokenizers (identical counts) on 2026-11-11: real tokens are
  0.62–0.69 of the estimate for English text and about 0.5 for Russian. The
  final request without any recording (prompt, the longest retry note, a
  60-character title and 300-character description) takes 1153–1318 tokens for
  the built-in types, 1192 for the example, 1396 for an 8-section Russian
  template estimated at 696, and 1554 for an English template estimated at 728.
  The budget was set when 4K was selectable: there a template at the budget left
  about 500 tokens for the recording's notes. Since 2026-11-11 the smallest
  context is 8K, which leaves several thousand. Measure again with
  `scripts/inference-fixture.sh template-budget <out.json> [<template.md> ...]`
  (local developer tool).
- **Storage.** `~/Library/Application Support/TalkTrack/Templates`: `<id>.md`
  (the imported text, LF, one trailing newline) and `Templates.json` (names,
  order, import dates), shared by all libraries on the Mac. Re-importing a file
  with an existing name replaces that template after confirmation and keeps its
  place; only the current version is kept. A file that no longer parses is
  listed as damaged with Delete only.
- **Provenance.** A job references the template by id, name and SHA-256 of its
  text (`ProcessingSettings.customTemplate`) and stores no content. The summary
  records the hash of the version actually used
  (`GeneratedOutput.templateContentHash`); Retry resolves the template again and
  uses its current version. Replacing a template marks its summaries Outdated.
- **Missing template.** A summary whose template was deleted, or whose library
  was opened on another Mac, stays readable with its stored name and "(template
  deleted)"; it is not Outdated. The picker asks to choose a template and
  Generate, Regenerate and Retry stay unavailable until one is chosen; under the
  chosen template such summaries count as made with another type. Deleting
  a template cancels its queued and running summaries after confirmation.
- **Context.** A template that leaves no room for the recording at the selected
  context fails before any model work with "The template … is too large for the
  8K context"; within the budget this can only happen to a historical 4K job (`SummaryGenerationError.templateTooLarge`); the previous summary
  stays.
- **Library compatibility.** The first summary job with a custom template raises
  the library schema to 4; older builds then refuse the library. Libraries that
  never used one stay at 3.

## Complete-input chunking

`MeetingSummarizer` (`SummaryChunking.swift`) counts every chat-formatted request
with the job's own tokenizer and never clips input:

1. **Direct** when the input plus the summary reserve fits the selected context
   (Auto picks the smallest of 8K–64K; default 32K; 4K was removed on 2026-11-11, saved 4K preferences become 8K and old 4K jobs keep their budget).
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
