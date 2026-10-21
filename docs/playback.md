# Playback: timeline mapping and recovery

A meeting's recordings play as one continuous timeline. Files are never joined
or rewritten for playback.

## Mapping

- **Timeline.** `MeetingTimeline` places finished recordings back to back by
  their active (captured, non-paused) duration, in start order. Time between
  recordings, including days, takes no timeline space; the scrubber marks each
  boundary and a new day.
- **Boundaries.** Intervals are half-open: an exact boundary belongs to the next
  recording, and the total duration is the ended state (Play restarts at zero).
- **Inside a recording.** Each track maps active time to committed AAC chunks,
  excluding persisted encoder trims. Explicit missing-source gaps (for example a
  late microphone start) are silence of the same length.
- **Tracks.** The player plays Auto (default), System Only, System and Microphone,
  or Microphone Only (`PlaybackTracks`, preference `playbackTracks`). Auto adds the
  microphone only during the final transcript's `You` replies (padded 200 ms, 30 ms
  fades); publication already dropped microphone words quieter than the system track
  and replies the system track also said, so echo stays muted. Without a final
  transcript Auto plays the system track only. System Only is the
  default because a meeting played through speakers reaches the microphone as a
  delayed room copy, which echoes in the mix. Chosen samples of the same frames are
  mixed before scheduling, so they cannot drift; changing the choice while playing
  restarts at the same position. Speeds 1×–3× apply to the mix; positions are
  always source time.
- **Transcript.** `TranscriptPlaybackIndex` maps speech blocks onto the same
  timeline, so the highlight and `[time]:` seeks match what is heard.
- **Not on the timeline.** A recording still being captured joins the timeline
  when it stops. While anything records, playback is unavailable.

## States without audio

The player shows why nothing can play (`PlaybackUnavailability`):

| State | Shown |
| --- | --- |
| Meeting never recorded | "No recorded audio yet. Press Record to capture this meeting." |
| First recording still being captured | "This recording can be played after you stop it." |
| Recordings without audio (interrupted at once) | "The recordings of this meeting contain no audio." |
| Any meeting recording | "Playback is unavailable while TalkTrack is recording" (Play tooltip) |

## Missing or unreadable audio

- **Check after loading.** When a meeting is shown, every chunk's receipt, byte
  count and SHA-256 are verified off the main actor, without decoding. Damaged
  stretches are listed under the player by recording ("Recording 2 of 3 ·
  date"), track and timeline range, and marked red on the scrubber.
- **During playback.** Every decoded chunk is verified again. Audio before the
  damage plays out; playback then pauses exactly at the damaged position with an
  error that names the recording, the track and the time.
- **Nothing is hidden.** The duration is not shortened, no other recording or
  track is substituted, and the transcript stays readable and seekable.
- **Recovery is explicit.**
  - *Try Again* plays from the same position. It re-checks the files, so
    restoring the original chunk files is enough; no restart is needed.
  - *Skip to m:ss* continues after the damaged stretch (or, before the check
    has located it, at the next recording). It is offered only when readable
    audio follows.
  - Seeking or a transcript timestamp outside the damage also continues.
- **Storage is not changed.** Playback never deletes, repairs or re-encodes
  audio. Rebuilding recordings from receipts is relaunch recovery
  (`MeetingRecorder.recoverAfterRelaunch`), not a playback action.
