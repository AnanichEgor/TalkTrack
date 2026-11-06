# Remembered voices

Select a final system speaker to open **Rename Speaker**. The name always applies
to that speaker in the displayed meeting and frozen recording day. Microphone
speech remains `You`; provisional speakers cannot open this dialog.

**Remember voice** is off every time the dialog opens. Leave it off for an ordinary
day rename. Turn it on to create a profile using the entered name, or choose an
existing **Voice profile** to add explicitly confirmed evidence to that person.
Selecting an existing profile does not rename that profile or rewrite historical
meeting names. A day name can differ from the saved profile's display name.

Save commits the day name and closes the sheet at once; the voice is learned in
the background (background-voice-learning, 2026-11-06). The notice says
`Learning the voice of <name> in the background.` and keeps **Undo**. An error,
too little speech or a changed name leaves the committed day name and transcript
intact; a saved name alone never means a voice was saved. See **Background
learning** below.

## Evidence and storage

Enrollment reads committed AAC in bounded ten-second windows through the same
reader and shared MLX runtime as transcription. It intersects the final speaker's
source intervals with exclusive segmentation activity, excluding other system
speakers and overlapping voices. Window ownership prevents duplicate evidence.
Each sample has a 50 ms guard at each end and at least one second of valid audio.
Silence, nonfinite values, out-of-range samples and heavily clipped signals are
excluded. Basic energy/clipping checks are not a calibrated noise-quality score.

The initial enrollment policy requires at least ten seconds across two or more
non-overlapping samples, retaining at most eight normalized 256-dimensional
vectors per revision. Samples come from the whole of the speaker's speech
(2026-10-14): its speech time is divided into eight equal stretches. How clips are
read and chosen within them is described under **Background learning**. Remembering from a named fragment uses only that person's
named fragments of the meeting day, and the revision's speaker key is that person
and day, so a later confirmation supersedes it in calibration. Adjacent different voice slots keep separate
transition guards. Short or mixed speech produces an explanation instead of
manufacturing evidence by padding, repeating, or joining unrelated audio. These
duration/signal gates do not establish an identity-matching confidence threshold.

Production profiles live at:

```text
~/Library/Application Support/TalkTrack/Speakers.sqlite3
```

The profile database is independent of the selected session root and Models.
An absent registry is not created by listing profiles or ordinary renaming.
Only successful evidence preparation proceeds to profile persistence. SQLite
schema 5 uses a separate application ID; unsupported future schemas and unsafe
paths are refused. Profile revision, current head and confirmation replay guard
commit in one transaction. A failed update preserves the previous head and
immutable evidence. Session schema remains version 2.

Every immutable profile revision records its profile UUID, parent revision,
creation time, library/meeting/day-speaker/manual-assignment UUIDs, source
recording/transcript/day IDs, exact sample intervals, vectors, segmentation and
embedding snapshots, preprocessing version and enrollment policy version. It
stores no PCM or transcript strings. The library UUID keeps references meaningful
if the owned session folder moves. Deleting a meeting leaves saved voice evidence
in its independent database.

Only a typed confirmation created by a manual save can authorize enrollment.
The service validates the current assignment, recordings and final heads before
and after asynchronous model work. Automatic assignments cannot train. Replaying
the same confirmation cannot create another profile or append another revision;
concurrent profile updates require selecting the latest revision again.

## Saved Speakers settings

Settings → **Saved Speakers** lists local voice profiles, offers **Rename…** and
**Delete…**, and persists **Recognize saved voices** independently of text/audio
preferences. Recognition reads this choice before model work and checks again
before publishing a new name. Switching it off leaves committed names intact.
Below the switch, Settings shows whether recognition is still learning from the
user's names (N of 3 meetings) or active, with its threshold.

Rename changes the profile display name used by future matches, without changing
its voice vectors or names already saved in meetings. Delete asks for confirmation
and removes the profile and **all** its embedding revisions. Historical manual
and automatic day names, matching proofs, transcripts and audio remain readable.
Another profile is unaffected. Stale selections and write failures retain the
existing data and offer refresh/retry.

Profiles whose models, preprocessing, enrollment policy or usable evidence are
incompatible show **Needs new confirmed speech** and **How to Update…**. Open a
finalized transcript using the current speaker models, select the person's system
speaker, confirm the name in Rename Speaker, turn on Remember voice and choose
that profile. Explicitly select **Replace incompatible voice evidence**, then
Save. The current revision is replaced only after sufficient fresh manually
confirmed evidence succeeds. The saved profile name and historical meeting names
stay unchanged; failure leaves the previous profile available. Incompatible old
revisions remain historical and are never compared as current evidence. Delete
removes those revisions too. Microphone speech cannot authorize this workflow.

Schema 2 adds non-vector enrollment receipts keyed only by library and manual
assignment UUID. They survive profile deletion so an old confirmation cannot
silently recreate a deleted voice. Schema 1 upgrades transactionally after a
standalone `Speakers.v1-backup.sqlite3` backup. A successful upgraded open checks
integrity and removes that temporary backup before allowing deletion; interrupted
upgrade/cleanup can retry. Unsupported, foreign or unsafe files are refused.
Deletion uses SQLite secure deletion and DELETE journaling to clear freed cells
and avoid retaining vectors in an application WAL. This concerns the active app
registry and its migration backup, not copies made by OS backups or filesystem
snapshots. The session schema remains 2.

Schema 3 adds `withdrawals(library_id, recording_id, start_us, end_us,
withdrawn_at)`: time ranges of removed reply names, never vectors. Schema 2
upgrades the same way as schema 1 (temporary backup in the same
`Speakers.v1-backup.sqlite3` file, `CREATE TABLE`, `user_version = 3`, backup
removed); a schema 1 file upgrades through 2 to 3 in one open. Older builds
refuse a schema 3 file as a newer schema.

Schema 4 adds `exclusions(profile_id, revision_id, recording_id, start_us,
end_us, excluded_at)`: samples the user removed from one voice in Settings, as
time ranges, never vectors. Schema 3 upgrades the same way (temporary backup,
`CREATE TABLE`, `user_version = 4`, backup removed); older files upgrade through
every step in one open. Builds before this one refuse a schema 4 file. Deleting
a voice deletes its exclusions too.


## Recognition and manual correction

Task 6.3 adds `VoiceProfileRecognition` for use after final transcript publication.
It reads the current final speakers and applies the same clean-speech reader as
enrollment. Only compatible segmentation/embedding snapshots, preprocessing and
enrollment-policy versions participate. Microphone speech is excluded. At least
ten seconds in two non-overlapping samples is required on both sides; up to eight
vectors represent each side. The score is the minimum cosine similarity across
every query/profile pair, rather than the strongest isolated sample. A name needs
both the calibrated similarity threshold and the calibrated margin over the next
compatible profile. Ties and uncertain results retain `VoiceN`. A corrupt compatible
competitor refuses comparison instead of artificially increasing the margin.

Recognition evaluates speakers together. Distinct speakers with overlapping source
intervals cannot claim the same profile; both new proposals are refused. Existing
automatic assignments reserve their profile, and confidently matched manual
speakers participate in the conflict check without changing their names. Distinct
coactive speakers may receive different compatible profiles. Speaker UUIDs and
utterance text are never merged or rewritten by recognition.

Automatic names show **Automatic** beside the speaker. Select the name to review
the explanation or save a correction. Save creates a manual assignment, which
takes precedence even if recognition was already running. **Remember voice** stays
off: an automatic match does not authorize training. A fresh explicit manual Save
with remembering enabled is required to prepare any new profile evidence.

The session database commits assignment, immutable matching proof and assignment
head together. The proof snapshots the profile name/UUID/revision, a hash of that
revision, complete calibration parameters/report digest, ranked profile scores,
and source recording/transcript/day/sample intervals with embedding hashes. It
stores no reusable vectors, PCM or utterance text. Manual corrections and later
profile changes do not rewrite this history. A short registry write lock validates
all current profile heads and holds them stable through the session commit;
recognition does not modify the registry. Source replacement, cancellation,
meeting deletion, profile updates and storage errors refuse stale/partial names.

## Calibration and current availability

Calibration comes from the user's own confirmations (task 6.7, user decision
2026-10-13; it replaces the separate corpus planned in task 6.4). Each saved
voice's bank combines all its compatible confirmations; a day speaker confirmed
again under another name counts only under the latest one. The
`exclusive-median-best-cosine-v2` scorer and the leave-one-meeting-out
calibrator derive the threshold and margin from them. Until the
names span three meetings with one person named in two, recognition returns
`uncalibrated` before decoding audio or loading a model. Automatic names never
become calibration or profile data. The synthetic test calibration still exists
only in tests.

The signed Debug fixture hosts the production transcript/dialog components using
synthetic model results and private session/profile roots. Native workspace and
post-publication job wiring remain under task 9 and native integration; saved
speaker Settings are implemented in 6.5. Recognition mechanics are not a claim of measured
identity accuracy.

## Names and split voices

Voices given one name are one person, different names different people.
Apply Names rebuilds a meeting's
voices from its kept processing results with those links; pairs of named voices
calibrate a merge threshold used for new meetings, shown in Settings → Speakers
as "Joining split voices".

## Naming sheet, Undo and removed reply names

The naming sheet opens with an empty name field; the selected speech's current
name is shown as **Current speaker** and as the field's placeholder. **Saved
voices (N)** lists every saved voice in a list about six rows tall that scrolls:
the voice named like the current name first, marked Current, then the rest
alphabetically. Typing filters it (names starting with the text, then names
containing it); picking a voice fills the field and keeps the whole list.
**Voices of this day** scrolls the same way. Saved voices are read each time the
sheet opens, so a voice saved by one naming is listed in the next.

After a Save a tinted banner above the transcript offers **Undo**; Edit ▸ Undo Naming (⌘Z) does the same while the banner shows. In a text field or the notes editor ⌘Z stays the ordinary text Undo. Before the Save the presentation
reads the meeting's naming heads (`SessionStore.namingHeads`); the token
(`NamingUndo`) keeps them, the generation the Save produced, and the saved voice
the Save created or extended. Undo runs two separate steps, because the session
library and `Speakers.sqlite3` share no transaction:

0. A learning task the Save queued that has not finished is cancelled
   (`VoiceProfileEnrollment.undoLearning`); nothing is added afterwards and the
   notice says `Learning the voice was stopped.` A learned task continues below.
1. `VoiceProfileStore.undoEnrollment(created:previous:)` moves the voice back to
   its previous revision, or deletes a voice the Save created, and deletes the
   created revision under `secure_delete`. The enrollment receipt stays, so that
   confirmation cannot train again. It is refused when the voice changed after
   the Save (another confirmation, a rename in Settings) or while a recognition
   result is being committed.
2. `SessionStore.undoNaming(_:generation:)` restores the recorded heads in one
   transaction while the meeting is still at that generation and advances it.
   The undone name records stay as history.

The voice step runs first and is recorded as done, so after a failure of the
names step **Retry Undo** only restores the names; the message says the voice
already has only its earlier samples. Undo is withdrawn by the next naming
action, Apply Names, Clear Speaker Names, Remove Reply Name, Reprocess (a new
transcript), switching meetings, or any refresh that sees another generation.
When names or the voice changed, nothing is undone and the message points to
renaming the reply or voice, or Remove Reply Name. Clear Speaker Names still
leaves saved voices unchanged.

**Remove Reply Name** first removes the name (`SessionStore.removeFragmentNames`,
which returns the removed named replies' time ranges), then records them with
`VoiceProfileStore.withdraw`. Bank reading (`recognitionProfiles`) drops a sample
when a withdrawal covers it under the same one-fifth overlap rule as corrections
and was made after the sample's revision. Recognition, calibration and Settings
status all read banks this way. Naming the reply again creates a newer revision,
which the earlier withdrawal does not affect. Writing a withdrawal again changes
nothing. If recording it fails, the name is still removed and the error row says
saved voices still use the speech; Retry records it.

Tests: `./scripts/test.sh --filter 'NamingUndoTests|SpeakerRenameTests|SavedSpeakersTests'`.

## Background learning

Every Save with Remember voice, Remember Voices… from a draft, a reply correction
and the incompatible-voice replacement store a learning task in `Speakers.sqlite3`
(schema 5, table `learning_tasks(id, library_id, meeting_id, state, created_at,
payload)`; schema 4 upgrades with a temporary backup, older builds refuse it). The
payload is the confirmation's identity (library, meeting, speaker, manual
assignment, recordings, final revisions, named fragments) and the voice choice; it
is rebuilt and validated against the library before reading audio and again in
the commit (`SessionStore.voiceConfirmation(for:)`), so a renamed speaker ends
`superseded` and adds nothing.

`VoiceProfileEnrollment` runs tasks one at a time at utility priority, only for
the open library. Record cancels the running task, which is queued again and
restarts after Stop; Quit and a library move stop it and leave it queued
(`shutDown`); launch turns tasks left `running` back to `queued` (`start`). The
commit checks the task is still running or awaiting review in the same transaction,
so a task cancelled during the commit adds nothing and replay cannot add twice.
States: `queued`, `running`, `awaitingReview`, `learned`, `insufficientSpeech`,
`failed`, `cancelled`, `superseded`. Finished tasks the user dismissed are
removed after seven days.

**Reading.** Candidates come from the transcript without a model: the person's
speech minus 0.5 s around other speakers, cut into pieces of at most 8 s, ranked
by length within each of the eight stretches. The first pass segments only the
windows of the best two candidates per stretch; only when that gives less than the
policy minimum, or leaves a stretch with candidates but no clean clip, are the
remaining windows read in time order until it is enough. Each stretch keeps its
three longest clean clips; at most 16 clips are embedded (the best of each
stretch, then the longest spares).

**Selection.** Clips much less similar to the rest than the set is to itself
(median similarity more than 0.15 below the set's median) are dropped as someone
else. A new voice keeps one clip per stretch, then the longest spares. For an
existing voice, farthest-point selection runs against its current bank: each step
takes the clip least like the bank and the clips already chosen, and stops once
the closest remaining clip is within 0.08 of what is kept and the minimum is met.
A well-covered voice therefore gains two samples; a voice heard in new conditions
gains up to eight. Revisions record `selectionVersion` (`ranked-bank-aware-v1`);
the enrollment policy version is unchanged, so older revisions still match.

**Review.** Before adding to an existing voice with two or more samples, the
selected speech is scored with the recognition matcher against the bank. It is
held when the score is below the bank's own weakest leave-one-out score minus
0.05, capped at 0.5, or below an active calibration's threshold when that is lower.
The cap exists because a bank from one meeting is tighter than the same voice
across meetings (measured on real meetings: 2 of 6 repeat confirmations were held
without it, while wrong names scored at most 0.33). A held task
is `awaitingReview` with its clips (vectors and time ranges, no audio). The meeting
shows a tinted banner: **Play** (each held clip in the meeting's playback),
**Add to <name>** (an explicit confirmation), **Different Person…** (a new saved
voice under another name; the meeting's names stay) and **Don't Remember**.
Settings ▸ Speakers lists learning above the saved voices with Cancel, Retry,
Review… (opens the meeting) and Don't Remember. Held tasks are counted on the
sidebar's Settings row ("N voices to review") and in the menu bar's Settings… item,
both opening Settings ▸ Speakers (Settings toolbar tabs do not draw badges). A remembered line fades after five seconds; short speech and failures
stay until dismissed or retried.

Tests: `./scripts/test.sh --filter 'VoiceLearningTaskTests|VoiceLearningPresentationTests|VoiceLearningSettingsTests'`.
Measurements on copies of real meetings: `scripts/inference-fixture.sh voice-learning <library copy> <out.json> [<meeting id>…]`
(renames voices to their own names to obtain confirmations; copies only).

## Reviewing and removing samples

Each voice in Settings ▸ Speakers has **Samples (N)**. Opening it lists the
samples that voice currently counts: the same filters recognition applies
(latest name of each day speaker, withdrawals, exclusions, and the open
library's named fragments) on revisions compatible with the voice's head
(`VoiceProfileStore.samples(of:corrections:)`). Samples are grouped by the
meeting day where the person was named, newest first. A row shows the
transcript time where the sample starts, its length, the overlapping reply text
from the current transcript (read by `SessionStore.voiceSampleContexts`, shown
only, never stored) and **Used for recognition** when it is among the at most
24 samples recognition compares with.

- **Play** plays only the sample's system audio from its own recording
  (`VoiceSamplePreview`, its own audio engine), pauses meeting playback and is
  refused while TalkTrack records. Capture stops it first: the recorder gets a
  `CombinedPlaybackExclusion` of the meeting player and the preview.
- **Remove** and **Remove All…** (one meeting day, with a confirmation) record
  exclusions for this voice only (`VoiceProfileStore.exclude`). The sample stops
  counting for it in recognition, calibration and status; other voices, meeting
  names and recordings are unchanged. Exclusions are keyed by the revision that
  holds the sample, so naming the same speech for the person again counts again.
- **Undo** in the banner restores the latest removal exactly
  (`VoiceProfileStore.restore`) until a refresh, rename, delete or a change of
  the voice.
- Samples from a library that is not open, or whose meeting or recording was
  deleted, are listed without Play, with the reason; they can still be removed.

Tests: `./scripts/test.sh --filter 'VoiceSampleExclusionTests|SavedSpeakersTests'`.

## Names from the draft

While a meeting records, and after Stop until its final transcript is ready, the
draft rows (`[time]: Voice3 · Draft - …`) can be named (live-draft-naming):

- **Name This Reply…** names one draft row (`LiveName.kind == .reply`).
- **Name Voice…** names a live voice on a row with exactly one voice
  (`.voice`). All its single-voice rows show the name, including rows that
  arrive later. Rows with several voices (`Voice1 / Voice2`) offer only Name This
  Reply…. Microphone rows stay `You`.
- A reply name wins over its voice's name on that row and for that speech.
- Each naming is saved at once (`liveName` records, one head per row or live
  voice), survives quit and relaunch, and is undone like any naming (Undo banner,
  Edit ▸ Undo Naming). Remove Name takes a row's reply name, else its voice's
  name, away. The sheet suggests saved voices and names used in the meeting and
  has no Remember toggle.

**How names travel.** `SessionStore.namedSpeech` includes unpublished draft names
as speech the user named, in the recording's active media time, which live and
final share:

- A reply name covers its row's interval.
- A voice name covers its live voice's single-voice rows without a reply name,
  less any speech another person's reply covers.

Final publication then applies the usual rules (`SpeakerLinks`): a block is
named only when one person's named speech covers at least 0.5 of it and other
people's at most 0.2; replies of the same people may be recognized from the
named ones. Live voice numbers are never mapped onto final voices: live clusters
split and merge differently, and coverage fails safe. In the same transaction,
each final system block a draft person was given becomes a fragment name
(`FragmentAnchor`), the draft names and the draft are retired, and the
publication records a `DraftNamingSummary`. The transcript then shows `Named N
replies from the draft. Not placed: …`. Names from the draft are then ordinary
fragment names: they can be edited, removed and undone, and Reprocess uses them.

**Confirmation before learning.** Draft names never add samples to saved voices
or create them: draft timing is coarse (3–6 s windows) and would put other
speakers into a voice. After publication, **Remember Voices…** next to a
person in that row opens the naming sheet for the person's named replies with
remembering on. Saving runs the fragment confirmation
(`nameFragmentWithConfirmation`) and the usual checks: exclusive speech, enough
clean speech, and an existing or new saved voice.

Tests: `./scripts/test.sh --filter 'LiveNamingTests|LiveDraftStoreTests'`.
