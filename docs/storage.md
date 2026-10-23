# Session storage

The implemented domain/services layer is independent of the current menu-bar
shell. Native editor, capture, and shutdown wiring remain in later tasks.

## Ownership and layout

The default selected root is `~/Documents/TalkTrack`. Only its marked child
`.talktrack-library` belongs to the application. The source repository and all
other siblings remain untouched. A selected custom folder uses the same child.
Models stay in `~/Library/Application Support/TalkTrack/Models`; opt-in reusable
voices use `~/Library/Application Support/TalkTrack/Speakers.sqlite3`.
The separate schema-2 profile database retains immutable model/preprocessing and
confirmed sample revisions. Ordinary names stay in the session library; enrollment
failure does not roll them back. Profiles survive meeting deletion and stay outside
session-folder migration. See [voice storage and enrollment](voice-profiles.md).
Automatic voice names and their immutable matching proofs live in the session
records table, committing with the assignment head in one transaction. Proofs
retain exact profile/calibration references, scores and source/embedding hashes,
without copying reusable profile vectors. Historical day names/proofs therefore
survive removal of a reusable profile.
Saved-speaker deletion removes the profile and every reusable revision using
SQLite secure deletion with DELETE journaling. Non-vector library/assignment
receipts preserve enrollment replay protection after deletion. The schema-1 to
schema-2 upgrade makes a temporary standalone backup, commits the receipts and
version atomically, then validates and removes its backup; cleanup is retried on
open before a deletion can succeed.

```text
<selected root>/
  <unrelated files, never moved or deleted>
  .talktrack-library/
    manifest.json                     # application, formatVersion, UUID, date
    Library.sqlite3                   # structured records and visible revisions
    Library.sqlite3-wal / -shm        # SQLite-managed active journal files
    Library.sqlite3.before-v2-<UUID>.backup
    Meetings/<meeting UUID>/
      Recovery/notes.json             # pending text, independent of SQLite
      Recordings/<recording UUID>/
        manifest.json                # recording metadata and completed receipts
        .writer.lock                 # advisory writer/recovery exclusion
        system/<chunk UUID>.m4a      # finalized AAC-LC <= ten seconds
        system/<chunk UUID>.json     # durable timing/codec/integrity receipt
        microphone/<chunk UUID>.*    # independently encoded second source
        <track>/.pending-<UUID>.m4a   # current uncommitted chunk only
```

`OwnedLibrary` stages initialization in a unique sibling directory, syncs its
manifest, and publishes it with an exclusive rename. Existing unmarked data is
never adopted. Reopening validates the manifest and configured library UUID.
Security-scoped bookmarks retain the selected root; unavailable or stale access
returns a recovery error, without creating a replacement default library.
Descriptor-relative operations reject user symlinks. The immutable macOS root
aliases `/var`, `/tmp`, and `/etc` are expanded to their `/private` counterparts.

The standalone audio writer and recovery service passed actual AAC codec and
SIGKILL fixtures on 2026-10-08.
It preserves separate sources and publishes durable receipts before the overall
manifest. Native capture-to-writer wiring, SQLite recording publication and
Stop-to-job integration are still separate pending tasks. Recovery must run
after the live writer stops or at relaunch; an exclusive recording lock enforces
that boundary. Standard decoded frames already omit AAC priming/padding.

The recording manifest now durably retains shared capture timing checkpoints
and explicit source gaps. Publish timing before committing audio at a new active
position; Pause flushes both sources, while a route gap flushes only its affected
encoder. Recovery preserves the common duration, frozen day IDs and wall/host
anchors, including ranges where one source has no committed audio. The virtual
timeline keeps those gaps in place.

`RecordingAudioWindowReader` consumes immutable committed recording snapshots
on its worker, verifies each selected receipt and AAC file through the same
descriptor, and returns at most thirty seconds of resampled audio per call.
It combines contiguous file ranges without joining files, resets overlap at
capture/day/gap boundaries, and retains separate active/wall/source provenance.
Errors or cancellation leave its cursor unchanged for retry. Missing timing
metadata fails explicitly; unavailable source ranges remain gap events. Live uncommitted PCM
delivery and transcript pipeline wiring remain separate tasks.

Day speakers now retain one canonical capture-day ID plus explicit same-day
capture UUID aliases, allowing a stable voice reference across separate recordings.
Older serialized speakers default to their canonical day. The formatter checks
alias date/zone/calendar provenance. Speaker clustering exposes a versioned
checkpoint value with compatible model/policy snapshots and source cursors;
future stage-file persistence must bind it to the durable job's source snapshot.
No global profile is enrolled by clustering.

Final publications now persist bounded clean voice banks and day speakers in
SQLite, with immutable manual assignments and separate current assignment heads.
These banks support conservative reconciliation of the same recording's reruns;
they are not reusable global profiles. Review records retain the earlier
assignment IDs, affected block IDs and previous revision reference.

## Transactions and revisions

`SessionStore` runs IO on its actor executor using system SQLite, foreign keys,
WAL, and `synchronous=FULL`. Mutations use `BEGIN IMMEDIATE`/commit/rollback.
The database application ID and library UUID must match before opening it for
writes. Meetings use stable UUIDs; equal dates have deterministic tie breaking.
Search folds Unicode case and diacritics, including Russian text.

Deletion commits a tombstone and removes dependent records before cleaning only
`Meetings/<deleted UUID>`. File cleanup can be retried with
`cleanupDeletedMeeting`; symlinks within that owned folder are removed without
following their targets. Late saves and job results cannot recreate the parent.

### Deleting one recording

`SessionStore.deleteRecording(meetingID:recordingID:)` permanently removes one
`complete` or `interrupted` recording (`RecordingDeletionError.capturing` otherwise)
in one transaction:

1. Inserts `recording_tombstones (id, meeting_id, deleted_at)`.
2. Trims the meeting translation head without a model: a new `GeneratedOutput`
   and `translationSource` under a new job snapshot that drops the recording's
   generation, revision, translated segments and removed voices. It is exactly as
   current or outdated as before. With no remaining text the head is removed.
3. Deletes the recording's jobs (`job`, `summarySource`, `translationSource`,
   `finalCheckpoint` rows by job id, and heads scoped to those job ids), its
   fragment anchors and their heads, and day speakers (with `assignment`,
   `automaticVoiceMatch` rows and heads) whose capture days no remaining recording
   has.
4. Deletes every record and head scoped to the recording id: the recording,
   transcript revisions, final publications, checkpoints and summaries.
5. Cancels unfinished translation jobs of the meeting (they cover the recording)
   and bumps `meeting.generation`; `cancellationGeneration` is unchanged, so other
   recordings' queued work continues.

After the commit `Meetings/<meeting>/Recordings/<recording>` is removed. A failure
there is not reported: opening the store removes folders of all tombstoned
recordings, `MeetingRecorder.recoverAfterRelaunch` skips them, and `saveRecording`
refuses a tombstoned id, so late writers cannot bring the recording back. Notes,
other recordings and saved global voices (`Speakers.sqlite3`) are not touched.
Deleting the meeting removes its tombstones with it. The workspace pauses the
player and cancels the recording's running work first.

Notes have immutable revisions and a separately stored visible head. Edits first
write a recovery file, then stage a database entry. A failed database write
retains the file; a failed filesystem write retains the editor's in-memory text
and exposes an error. Autosave debounces for 350 ms. Presentation code must await
`flushForNavigation` or `flushForQuit` and keep the editor open on failure.
Recovery returns pending text without overwriting the last saved revision.

Jobs retain immutable source/settings/model snapshots, stage and checkpoint.
Opening a library marks active unfinished stages interrupted. Retry preserves
the snapshot and requires unchanged source. Successful publication updates the
visible revision and completed job state in one transaction. A changed recording
rejects final-transcript publication. A summary using older notes may publish
with its original snapshot and is reported outdated. Cancelled/deleted jobs and
older competing outputs cannot replace a newer result. Processing never writes
editable notes. Source fingerprints use sorted, stable UUID dictionary keys.

Final processing uses `FinalTranscriptionPipeline.runAndPublish` and
`SessionStore.publishFinalTranscript`. The latter validates ready staging, reads
the latest confirmed names, and commits transcript/speaker provenance, the affected
head and job completion together. Old revisions and assignments remain readable;
unknown names awaiting review do not discard complete text. Successful publication
is idempotent. The existing low-level `publishTranscript` import API remains for
persistence fixtures; it is not the final-processing entry point. The generic
record table stores `finalCheckpoint`, `finalPublication` and `daySpeaker`
payloads without changing schema version 2.

## Schema upgrades and recovery

Manifest format and domain payload format are version 1. SQLite schema is
version 3: version 1 contains meetings, tombstones, revision records and heads;
version 2 adds pending notes and the meeting-record index; version 3 adds
`recording_tombstones`. An unsupported newer
manifest/database version is refused. For a closed WAL-mode database without sidecars, a bounded descriptor-relative
header check refuses newer versions before opening the normal connection;
SQLite then verifies schema/application/library identity before application
writes. Existing WAL/journal state is checked through SQLite's read-only probe.

Before upgrading an existing version 1
database, the SQLite backup API produces a uniquely named snapshot. Backup
journal mode is DELETE and `quick_check` must pass, so it can be read as a
standalone file. Schema changes and `user_version` commit together; failures
roll back and preserve both original data and the backup.

Do not replace a database while the app is using it or copy only an active main
database file without its WAL. Stop writers and call `checkpoint`/`close` first,
or use SQLite's backup API. Restore a compatible backup only as an explicit
recovery operation, retaining the failed library and matching manifest UUID.

## Moving the library (`LibraryMigrator`)

Settings ▸ General ▸ **Move Library…** moves the owned `.talktrack-library` to
another root. Only that folder moves; models (`Models/`), saved voices
(`Speakers.sqlite3`) and preferences stay in Application Support, and the library
UUID is kept, so saved-voice evidence still refers to the same meetings.

Ownership example: the default root `~/Documents/TalkTrack` is also this
source repository.

```text
~/Documents/TalkTrack/            ~/Meetings/  (chosen destination)
  README.md, App/, Packages/ ...    notes.txt          <- never touched
  .talktrack-library/  ── move ──>  .talktrack-library/
```

After the move `~/Documents/TalkTrack` still holds the repository, byte for byte,
and `~/Meetings` holds `notes.txt` plus the library. The active root is recorded
in `Application Support/TalkTrack/LibraryLocation.json` (library UUID, security-
scoped bookmark, path). Without that file the default root is used.

**Refused before anything is written:** while recording; the same folder; a folder
inside the current root or containing it; a folder inside a library or a move's
staging folder; a folder inside Application Support/TalkTrack or Models; a folder
that already has a `.talktrack-library` (libraries are never merged or
overwritten); an unwritable or unavailable folder; less free space than the
library plus max(64 MB, 5 %); a symlink or other non-regular item inside the
library; a non-empty database WAL.

**Phases** (journal `Application Support/TalkTrack/Migrations/<id>.json`, which
names both roots and their volume UUIDs, the staging folder and every owned
item with size, modification time and SHA-256):

| Phase | Done | Authoritative | After a crash or relaunch |
|---|---|---|---|
| — | Stop processing (running job requeued), stop playback, save notes, `SessionStore.close()` (WAL checkpoint) | source | — |
| `copying` | Stream every item into `<destination>/.talktrack-move-<id>`, hashing and fsyncing each file | source | the staging folder is removed; the library stays |
| `verified` | Source unchanged (size, mtime); copied database `integrity_check` and library UUID; every file read back and hashed; nothing extra | source | staging removed; if it was already renamed, the switch is completed |
| (switch) | Exclusive rename of staging to `.talktrack-library`, then `LibraryLocation.json` | destination once the location is saved | the location decides: if it names the destination, cleanup continues |
| `committed` | Remove the old library's inventoried items deepest first, then its folder | destination | cleanup is retried at each launch |
| (done) | Journal deleted | destination | — |

Cancel works until the switch; cancelling or any error before it removes the
staging folder and reopens the old library. Recovery (`recover()`) runs at launch
before any library opens. A volume whose UUID differs from the journal's (an empty
mount point after a disconnect) counts as unavailable, never as an empty folder.

**What the user sees and can do**

- Progress with Cancel Move in the window and in Settings; processing resumes
  after the library reopens.
- A refusal or failure says the library stays in its old folder and why.
- "An interrupted library move was undone / completed" after a crash.
- A partial copy on a disconnected disk: the library stays put; reconnect the disk
  and relaunch to remove the copy. Another move is refused until then.
- Old library folder on a disconnected disk: the new library is used; the old
  files are removed after reconnecting and relaunching.
- Items in the old library folder that TalkTrack did not create are kept and
  reported; cleanup completes once they are removed.
- A recorded folder that was renamed or moved: its bookmark is renewed
  automatically when it still holds the same library UUID. A folder that cannot
  be found shows **Locate Library…**, which accepts only the same library; TalkTrack
  never creates a replacement library.

Implementation references checked on 2026-09-29:
[SQLite transactions](https://www.sqlite.org/lang_transaction.html),
[open flags](https://www.sqlite.org/c3ref/open.html),
[schema version pragma](https://www.sqlite.org/pragma.html#pragma_user_version),
[backup API](https://www.sqlite.org/backup.html),
[Apple bookmarks](https://developer.apple.com/documentation/foundation/url/bookmarkdata(options:includingresourcevaluesforkeys:relativeto:)).
Muesli's `DictationStore.swift` and `StorageModels.swift` at the recorded reference
revision were inspected; this implementation uses TalkTrack's own multi-recording
schema and actor, without copying cloud synchronization or other backend code.
