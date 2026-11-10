# Development

## Requirements

- Apple Silicon Mac. The app is arm64 only; the deployment target is macOS 15.
- Full Xcode with Swift 6.3 or later and the Metal toolchain (`xcrun metal --version`).
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) 2.44 or later.

## Commands

Run from the repository root:

| Command | What it does |
|---|---|
| `./scripts/build.sh` | Regenerates `TalkTrack.xcodeproj` from `project.yml`, builds Debug into `.build/xcode` and verifies the signature. `./scripts/build.sh clean` rebuilds from scratch. |
| `./scripts/launch.sh` | Opens the Debug build. |
| `./scripts/test.sh` | Runs the package unit tests (`swift test`); no models needed. `--filter <Suite>` runs one suite. |
| `./scripts/package.sh` | Builds the Release DMG into `.build/dist` for a GitHub release (see the README). |
| `./scripts/resolve-dependencies.sh` | Resolves Swift packages explicitly after changing a pinned version. |
| `python3 scripts/generate-model-catalog.py --check` | Checks the bundled model catalog against the reviewed metadata, offline. |
| `python3 scripts/fetch-model-metadata.py` | Refreshes model metadata for the pinned revisions (network). |
| `python3 scripts/audit-inference.py <build log>` | Confirms the app links only the MLX inference targets. |

Normal builds use only the versions in `Package.resolved`
(`-onlyUsePackageVersionsFromResolvedFile`); dependency updates are explicit.

### First build on a new machine

- **MLX plugin trust.** mlx-swift 0.31.6 attaches its `CudaBuild` package plugin
  (it does nothing on macOS) and Xcode asks to trust it once. Open
  `TalkTrack.xcodeproj`, build, choose **Trust & Enable**, then rerun the script.
- **Signing.** Debug builds sign with an Apple Development certificate, so
  Microphone and System Audio Recording Only permissions survive rebuilds
  (ad-hoc builds lose them every time). Set `DEVELOPMENT_TEAM` in `project.yml`
  to your team, sign in to Xcode and run `./scripts/build.sh -allowProvisioningUpdates`
  once. Hardened runtime is on, so `App/TalkTrack.entitlements` grants audio input.

## Layout

| Path | Contents |
|---|---|
| `App/` | SwiftUI/AppKit application: menu bar, workspace, tabs, settings. |
| `Packages/TalkTrackKit` | `TalkTrackDomain` (values, transcript formatting, timeline), `TalkTrackAudio` (capture, AAC), `TalkTrackServices` (storage, jobs, models, presentation) and their tests. |
| `Packages/TalkTrackInference` | MLX runtime and adapted Qwen speech, speaker and text model code. |
| `ThirdParty/` | Licenses and provenance of adapted source, dependencies and models. |
| `Fixtures/Summary` | Transcript fixtures used by the unit tests. |
| `docs/` | Design notes, listed below. |

Domain values belong in `TalkTrackDomain`, actors and services in
`TalkTrackServices`, and AppKit/SwiftUI presentation in `App`. Audio, inference
and long file operations stay off the main actor.

A local `project.devtools.yml`, when present, adds maintainer-only debug screens
and model fixtures to the generated project; it is not part of the repository.

## Data locations

- Meetings: `~/Documents/TalkTrack/.talktrack-library` (or the same marked folder
  under a root chosen in Settings). TalkTrack only ever creates, migrates or deletes
  that folder, never its surroundings.
- Models: `~/Library/Application Support/TalkTrack/Models`, outside the app bundle.
  Every app launch removes what the bundled catalog does not list (see `docs/inference.md`),
  Debug launches with `--workspace-library` and the UI review scripts included; then only
  the fixture library's unfinished jobs keep a legacy model. Candidate models that a
  comparison fixture installs with `InferenceRuntime(catalog:)` are removed at the next app
  launch: run such comparisons before launching the app, or install them again.
- Saved voices: `~/Library/Application Support/TalkTrack/Speakers.sqlite3`.

## Logging

Capture diagnostics use the unified log, subsystem `local.talktrack.app`, through
`CaptureLog` (`TalkTrackAudio/CaptureLog.swift`): category `capture` for the
coordinator and drivers, `recorder` for recorder phases, Stop and Quit. Rules:

- Lifecycle events only (phases, source start/stop, restarts, timeouts, abandoned
  calls), never per audio packet. Timed operations log `begin` and `end`, `timeout`,
  `failed` or `cancelled` with milliseconds, so a hung call is a `begin` without an end.
- Public values: short recording/run identifiers, phases, sources, fixed operation keys
  (`mic.stop`, `tap.teardown`, `coordinator.shutdown`, …), durations, OSStatus codes.
- Free-text errors can name devices: log them only with `privacy: .private`.
- Never log meeting titles or descriptions, transcript, note or dictation text,
  speaker names or audio.
- Loudspeaker detection (`PlaybackEchoMonitor`) logs each classification change in
  category `capture`: `playback-echo <loudspeaker|headset|unknown> run=<id>
  activeS=<active seconds> peak=<median correlation> lagMs=<median delay>`. Numbers
  only; the audio it measures is never logged or saved.

The launch cleanup of the Models folder logs in category `models` (paths and counts only).

Collect with `log show --predicate 'subsystem == "local.talktrack.app"' --last 1h --info`.

## Design notes

- [Inference](inference.md): runtime, models, scheduling and memory admission.
- [Storage](storage.md): library layout, recovery and library migration.
- [Transcription](transcription.md): live and final transcripts, states and retry.
- [Playback](playback.md): continuous timeline and missing audio.
- [Voice profiles](voice-profiles.md): saved voices and recognition.
- [Summaries](summaries.md): templates, chunking and translation.
