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
- Saved voices: `~/Library/Application Support/TalkTrack/Speakers.sqlite3`.

## Design notes

- [Inference](inference.md): runtime, models, scheduling and memory admission.
- [Storage](storage.md): library layout, recovery and library migration.
- [Transcription](transcription.md): live and final transcripts, states and retry.
- [Playback](playback.md): continuous timeline and missing audio.
- [Voice profiles](voice-profiles.md): saved voices and recognition.
- [Summaries](summaries.md): templates, chunking and translation.
