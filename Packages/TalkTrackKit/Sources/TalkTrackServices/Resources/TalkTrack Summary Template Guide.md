# How to write a TalkTrack summary template

A template decides **which sections** a summary has and **what the model writes
in each of them**. TalkTrack adds everything else itself:

- write only what was said, never invent anything;
- keep names, numbers, dates and negations exactly as stated;
- write tasks as `- [ ] task — Owner: … — Due: … [time]`;
- put the time of the transcript line after every decision and task;
- translate into the summary language chosen in Settings;
- write "None noted." in a section with nothing for it.

So a template only describes the **structure and meaning** of its sections.

You can write a template by hand, or give this guide and `Example Template.md`
to your own AI assistant together with a description of your meetings and ask
it to write the template (see "For AI assistants" at the end). Then import the
file in TalkTrack: Settings ▸ Summaries ▸ Import Template….

## What the file looks like

A template is a plain text file with the extension `.md`. It has two parts:

```markdown
---
name: Sprint Retro
purpose: The team's retrospective at the end of a sprint
rules:
  - Attribute opinions to whoever stated them; if unclear, do not attribute.
---

## What Went Well
Concrete successes of the sprint: what worked and who pointed it out.

## What Got in the Way
Problems, delays and friction as participants described them, with their consequences when stated.

## Decisions

## Action Items
```

**The header** (between the two `---` lines):

| Field | Required | Meaning |
|---|---|---|
| `name` | yes | The name in the summary type list, up to 60 characters. A file with the name of an existing template replaces it. |
| `purpose` | no | One line: which meetings the template is for. |
| `rules` | no | Rules specific to this kind of meeting, one per line starting with `  - `. |
| `per_person` | no | The heading of a section grouped by person; see below. |

No other fields are allowed. Values fit on one line.

**Sections.** Each section starts with `## Heading`. The lines below the heading
explain what the model writes there.

## Built-in sections

These sections may have no explanation; they then work as in TalkTrack's own
summary types:

| Heading | What goes there |
|---|---|
| `## Decisions` | Only what was explicitly decided, one bullet each, with its time |
| `## Action Items` | Tasks with owner, deadline and time |
| `## Open Questions` | Unresolved questions, disagreements and proposals nobody agreed to |

With your own explanation under such a heading, yours replaces the built-in one.
The task and citation format stays the same.

## Writing headings

- **Short**: one to four words.
- **In the language you will read the summary in.** Headings appear in the
  summary exactly as written, whatever the summary language. If you want
  summaries in two languages, make two templates.
- No numbering, emoji, `**bold**` or `#` inside a heading.
- Each heading appears once.
- **Up to 8 sections** for good results; 12 at most. The more sections, the more
  often smaller models lose the structure.

## Writing explanations

The explanation is the most important part of a template. The model takes it
literally, so write it as you would explain the job to a new colleague taking
the minutes.

A good explanation answers three questions:

1. **What to include?** A specific kind of information.
2. **In what form?** Bullets, two or three sentences, grouped by person.
3. **What to leave out?** Important when a section is easy to confuse with
   another one.

| Weak | Better |
|---|---|
| Results | Two to four sentences: why the meeting was held and how it ended. |
| Risks | Risks and delays participants named, with the agreed mitigation if there was one. |
| What everyone does | One bullet group per participant who talked about their work: done, next, blocked. Leave out anyone who said nothing about their work. |
| Metrics | Numbers that were said, exactly as stated, with what they measure. Do not mix up a plan or target with a result. |
| Important | The topics that took the most time and what was concluded on each. Do not repeat decisions and tasks. |

Useful techniques:

- **Separate similar sections explicitly**: "do not repeat what is under Decisions".
- **Say whom to attribute to**: "with who said it", "only the customer's words, not our suggestions".
- **Limit the length**: "two to five bullets", "one sentence per topic".
- Explanations may be in English or Russian; the model understands both.

An explanation can take several lines. It may be up to 600 characters.

## Writing rules

Rules apply to the whole template. Write only what is **specific to this kind
of meeting**:

- Good: "Keep the customer's statements separate from our side's ideas."
- Good: "Assess only job-relevant skills; never comment on age, gender, health or family."
- Good: "Leave out small talk at the start of the call."
- Not needed: "Do not invent facts." TalkTrack always requires this.
- Not needed: "Write in English." The language comes from Settings.

One to three rules are enough; a long list dilutes the model's attention. Each
rule may be up to 400 characters, ten rules at most.

## A section grouped by person

For a section with one group of bullets per person (like Standup's updates),
name its heading in `per_person`:

```markdown
per_person: Updates by Person
```

TalkTrack then leaves out of that section anyone who said fewer than 20 words
in the recording, such as someone who only greeted the others. Other sections
are never filtered this way, so a short decision by a quiet participant stays.

## What not to do

A template controls **content**, not format. These requests break the format
check or give unstable results:

- asking for tables, JSON, your own numbering or another task format;
- putting `###` subheadings or examples with `##` inside an explanation;
- asking for a conclusion, rating or recommendation that was not given in the
  meeting ("rate whether the meeting went well");
- asking to guess who `Voice1` is;
- asking to compute times or durations (models get the arithmetic wrong).

TalkTrack warns about such requests when you import the file.

## Size

A template must fit the smallest context, 8K tokens, together with TalkTrack's
own instructions and part of the recording, and short templates work better. Its sections, explanations and rules
are limited to about 700 estimated tokens: roughly 2,100 characters of English
text or 1,050 of Russian. TalkTrack says how much a larger file is over.

## Checking a template

1. Import the file: Settings ▸ Summaries ▸ Import Template…. Problems are listed
   with their line numbers; nothing is saved until the file is correct.
2. Choose Show Prompt to see exactly what the model receives.
3. Generate a summary of a **short real recording** and check that:
   - every section is there, in order;
   - nothing appears in two sections;
   - "None noted." appears only where you expected it.
4. If something is wrong, change the **explanation** rather than the heading,
   import the file again (it replaces the template) and regenerate.
5. If you use the 4B model, check the template with it too: a small model needs
   shorter, more direct explanations.

## Starting points

- `Example Template.md`: a general template for any meeting.
- Any built-in type: Settings ▸ Summaries ▸ Export… saves it as a template file.

Change the name, remove sections you do not need, add your own and import the file.

## Checklist

- [ ] The header has a `name`
- [ ] 3–8 sections with short, unique headings
- [ ] Each of your own sections says what to include, in what form and what to leave out
- [ ] Similar sections are clearly separated
- [ ] 0–3 rules, only ones specific to this kind of meeting
- [ ] No requests for formats, tables, ratings or guessing people
- [ ] Tested on a short real recording

## For AI assistants

You are writing a TalkTrack summary template from the user's description of
their meetings. Follow this guide and use `Example Template.md` as the model.

- Output only the template file: no code fence around it, no explanation, no
  text before the first `---` or after the last section.
- Use only the header fields `name`, `purpose`, `rules` and `per_person`, each
  on one line; rules go one per line as `  - rule`.
- Write headings and explanations in the language of the user's description,
  unless the user asks for another language. Headings appear in the summaries
  exactly as you write them.
- Use 3–8 sections, each with a heading of one to four plain words and an
  explanation of what to include, in what form and what to leave out. Decisions,
  Action Items and Open Questions may be left without an explanation.
- Use `per_person` only for a section grouped by person, and give it exactly
  that section's heading.
- Do not ask for tables, JSON, numbering, subheadings, time calculations,
  ratings or guessing who an unidentified speaker is, and do not repeat rules
  TalkTrack always applies (accuracy, output language, time citations).
- Keep explanations under 600 characters, rules under 400 characters, and the
  whole template under about 2,100 characters of English or 1,050 of Russian.
