# Remembered voices

Select a final system speaker to open **Rename Speaker**. The name always applies
to that speaker in the displayed meeting and frozen recording day. Microphone
speech remains `You`; provisional speakers cannot open this dialog.

**Remember voice** is off every time the dialog opens. Leave it off for an ordinary
day rename. Turn it on to create a profile using the entered name, or choose an
existing **Voice profile** to add explicitly confirmed evidence to that person.
Selecting an existing profile does not rename that profile or rewrite historical
meeting names. A day name can differ from the saved profile's display name.

Save commits the day name first. The application then checks saved system audio
and stores a representation only if enough suitable speech is available. An
error, insufficient speech, or **Cancel Remembering** leaves the committed day
name and transcript intact. The result message says whether remembering finished;
a saved name alone never means a profile was saved. To retry, select the speaker,
turn remembering on again and save a fresh confirmation.

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
(2026-10-14): its speech time is divided into eight equal stretches and each keeps
its longest clean clip (a second one fills a stretch without clean speech); only
kept clips are embedded. Remembering from a named fragment uses only that person's
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
schema 2 uses a separate application ID; unsupported future schemas and unsafe
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
