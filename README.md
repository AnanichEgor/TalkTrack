# TalkTrack

TalkTrack is a native macOS menu-bar app that records meetings and processes them
entirely on your Mac. It captures other apps' audio (Zoom, Meet, Teams, a browser…)
and your microphone as separate tracks, transcribes them with timestamps and speaker
labels, and writes summaries and translations with a local language model. Nothing
is sent to a server: the only network access is downloading the models once from
Hugging Face and checking GitHub for a new TalkTrack version. If you choose, summaries
and translations can instead use your own model through an OpenAI-compatible API.

**Platform:** macOS 15 or later on Apple Silicon (M1 or newer). Intel Macs are not
supported.

**[⬇ Download TalkTrack.dmg](https://github.com/AnanichEgor/TalkTrack/releases/latest/download/TalkTrack.dmg)**
(latest release, no build needed) — then follow [Installation](#installation).

## Features

**Recording**
- System audio (via a Core Audio process tap that leaves out TalkTrack's own playback)
  and the microphone are recorded at the same
  time as two separate tracks, compact AAC (48 kHz mono, 64 kbit/s, about 60 MB per
  hour for both tracks).
- A meeting can hold several recordings made at different times or on different
  days; files are kept separately, never joined.
- Record, Pause/Resume and Stop from the meeting or from the menu bar. Closing the
  window keeps recording; Quit asks to stop and saves.
- Recordings survive an app crash or a full disk: audio is written in short
  committed chunks and recovered at the next launch. Microphone device changes are handled without
  stopping the recording.

**Transcription**
- Optional live transcript while recording (lightweight model, provisional).
- After Stop, the whole recording is transcribed again with a stronger model, word
  timings are aligned, and the result replaces the live text. Optional spelling
  correction with the text model.
- Speakers are separated (diarization): other participants appear as `Voice1`,
  `Voice2`, …; microphone speech is always `You`. A phrase too short, or too mixed
  with another speaker, to match to a voice is shown as `Unidentified`.
- Layout: centered date separators (`------------ [date] ------------`, plus
  `resumption` when a meeting continues on another day), `[time]: Speaker - text`
  blocks; the same speaker continues one block across pauses of up to two seconds.
- Languages: English and Russian (Auto, English or Russian per meeting).

**Speakers**
- Rename a voice for the meeting day, or name a single reply or fragment.
- Select `Unidentified` to say who said that phrase: choose a voice of the day or
  enter a name; only that reply changes.
- Saved voices: names you confirm can be remembered and recognized automatically in
  later meetings. Recognition calibrates itself from your own confirmations; manual
  names always win. Saved voices are managed in Settings ▸ Speakers.

**Dictation**
- Type with your voice in any app: hold Right Option (configurable), speak and
  release, and the text appears at the cursor. Press to Toggle is available; Escape
  cancels.
- Recognized on the Mac with the same Qwen3-ASR models as transcription (0.6B by
  default, 1.7B selectable), in Auto, English or Russian. The model loads when you
  press the shortcut and is unloaded after an idle period.
- A dictionary of names and terms guides spelling; replacement rules fix recurring
  mistakes. Optional spoken formatting commands ("comma", "new line", "запятая",
  "новая строка") and removal of hesitation sounds.
- The text is pasted only into the window and field that had focus when you pressed
  the shortcut; otherwise it stays on the clipboard to paste yourself.
- A running summary, translation or transcription pauses for a dictation and then
  continues. Dictation is unavailable while a meeting is recording.
- Dictation audio and text are never saved: recent dictations are kept in the menu
  bar (Copy Last Transcript) only until TalkTrack quits.

**Workspace**
- Meetings in the sidebar, newest first, with search. New Meeting takes a title and
  description; meetings can be renamed and deleted.
- Tabs: **Transcript**, **Notes**, **Summary**, **Translation**.
- Notes are saved automatically and support titles, headings, bold, italic,
  bulleted lists and checklists.
- Summaries per recording with six templates: Auto, One-to-One, Customer Discovery,
  Hiring Interview, Standup, Weekly Review. Long meetings are split and merged
  without truncation; progress, cancel, retry and an Outdated mark when the
  transcript or settings change.
- Translation of the final transcript to English or Russian, laid out like the
  transcript; dates, names and timestamps come from the original.
- Player under the transcript: all recordings of a meeting play as one continuous
  timeline with a scrubber and speeds 1×, 1.5×, 2×, 2.5×, 3×. By default (Auto) it
  plays the system track and adds the microphone only during your own replies (`You`)
  of the final transcript, so speaker echo stays out; the track menu also offers
  System Only, both tracks and Microphone Only. The block being
  played is highlighted, and clicking `[time]:` plays from there. Missing or damaged
  audio is reported and marked on the timeline.

**Settings**
- General: permissions (status, Grant… or Check Again, Open System Settings), library location
  (Move Library… with a verified, crash-safe copy), the models folder and update checks.
- Audio: microphone, live transcription, default meeting language, spelling
  correction.
- Models: download, resume, cancel and remove each model; choose the text model
  (Automatic, 9B or 4B), and a text server (see below).
- Text: summary language and translation language (independent), context size.
- Speakers: saved voices and automatic recognition.
- Dictation: shortcut and mode, language and model, dictionary and replacements,
  formatting, feedback (waveform, sounds, muting other audio), clipboard and history.

## Stack

- Swift 6, SwiftUI and AppKit; Swift Concurrency with strict checking.
- [MLX Swift](https://github.com/ml-explore/mlx-swift) 0.31.6 and MLX Swift LM 3.31.4
  for all model inference on the GPU of Apple Silicon.
- Core Audio process taps (system audio), Core Audio / AVFoundation (microphone, AAC,
  playback), SQLite (meeting library), XcodeGen (project generation).
- Models (downloaded at pinned revisions and verified by SHA-256):

| Purpose | Model | Download |
|---|---|---|
| Live transcription | Qwen3-ASR 0.6B (4-bit) | 0.7 GB |
| Final transcription | Qwen3-ASR 1.7B (8-bit) | 2.3 GB |
| Word alignment | Qwen3-ForcedAligner 0.6B (8-bit) | 1.2 GB |
| Speaker segmentation | pyannote segmentation 3.0 (MLX) | 10 MB |
| Speaker embeddings | WeSpeaker ResNet34-LM (MLX) | 20 MB |
| Summaries, translation, correction | Qwen3.5 9B OptiQ (4-bit) **or** Qwen3.5 4B OptiQ (4-bit) | 6.6 GB / 3.1 GB |

Source and model licenses and attribution are in [ThirdParty/](ThirdParty/README.md).

## Requirements and limitations

- **Apple Silicon and macOS 15+ only.** The app is built for arm64. Development and
  testing were done on macOS 27; earlier versions are supported by the build target
  but were not tested.
- **Memory.** The text model is chosen by RAM: 32 GB or more uses Qwen3.5 9B, less
  uses 4B. You can choose 9B on a smaller Mac in Settings ▸ Models; TalkTrack warns
  that summaries and translations may then be much slower or stop with a memory
  error. 16 GB is the practical minimum for summaries and translation; requests that
  do not fit in RAM at all (for example 9B on 8 GB) are refused. Recording and
  transcription are not affected.
- **Disk.** About 4.2 GB for the speech models plus 3.1 GB (4B) or 6.6 GB (9B) for the
  text model, stored in `~/Library/Application Support/TalkTrack/Models`.
- **Internet** is needed only to download models and to check for updates;
  everything else works offline (unless you use a text server).
- **Languages:** speech recognition, summaries and translation support English and
  Russian. The interface is in English.
- **Permissions:** Microphone and **System Audio Recording Only** (in System Settings ▸
  Privacy & Security ▸ Screen & System Audio Recording). TalkTrack never asks for screen
  access. macOS shows no prompt for system audio: switch TalkTrack on in that list
  yourself; Record and Settings ▸ General ▸ Permissions check it with an inaudible tone.
  Dictation additionally needs Accessibility (to check the focused field and paste) and
  Input Monitoring (to notice the shortcut in other apps). macOS relaunches TalkTrack
  when System Audio Recording Only changes; other changes take effect after relaunching.
- **Speed:** final transcription and summaries run after recording and can take
  several minutes for a long meeting. Recording is never blocked by processing.
- **Speaker separation** works best with a few clearly different voices; with many
  people on one loudspeaker voices can be merged or split and may need renaming.
- **Not notarized.** Release builds are ad-hoc signed, so macOS blocks the first
  launch until you allow it (see [Opening the unsigned app](#opening-the-unsigned-app)),
  and may ask for the permissions again after each update.

## Installation

1. Download **[TalkTrack.dmg](https://github.com/AnanichEgor/TalkTrack/releases/latest/download/TalkTrack.dmg)**
   from the latest release (earlier versions are on the
   [Releases](https://github.com/AnanichEgor/TalkTrack/releases) page). To check the
   download, compare `shasum -a 256 TalkTrack.dmg` with
   [TalkTrack.dmg.sha256](https://github.com/AnanichEgor/TalkTrack/releases/latest/download/TalkTrack.dmg.sha256).
2. Open the DMG and drag **TalkTrack** to **Applications**.
3. Open TalkTrack. The app is not signed with an Apple Developer ID, so macOS blocks
   the first launch; allow it once as described in
   [Opening the unsigned app](#opening-the-unsigned-app).
4. TalkTrack lives in the menu bar (no Dock icon). Open its main window from the
   menu bar icon.
5. Open **Settings ▸ Models** and download the models (about 7–11 GB).
6. Open **System Settings ▸ Privacy & Security ▸ Screen & System Audio Recording** and
   switch TalkTrack on under **System Audio Recording Only** (Settings ▸ General ▸
   Permissions has a button that opens it). Create a meeting and press **Record**;
   macOS asks for Microphone access on the first recording.

### Opening the unsigned app

TalkTrack is ad-hoc signed and not notarized by Apple (that requires a paid Apple
Developer account). macOS therefore cannot confirm who made it and, on the first
launch, shows *"Apple could not verify “TalkTrack” is free of malware…"* with only
**Done** and **Move to Trash**. The app is fine to run; you just have to allow it
once. Use either method.

**Method 1: System Settings**

1. Open TalkTrack from Applications. When the warning appears, click **Done**
   (not Move to Trash).
2. Open the Apple menu ▸ **System Settings ▸ Privacy & Security**.
3. Scroll down to **Security**. You will see *"“TalkTrack” was blocked to protect
   your Mac."* Click **Open Anyway**. The button is shown for about an hour after
   the blocked launch; if it is missing, open TalkTrack again and come back.
4. Enter your Mac password or use Touch ID, then click **Open Anyway** in the
   dialog that follows.

**Method 2: Terminal**

macOS blocks the app because the browser marked the download as coming from the
internet. Removing that mark lets it open normally:

```sh
xattr -dr com.apple.quarantine /Applications/TalkTrack.app
```

Then open TalkTrack as usual. Run the command after copying the app to
Applications.

### Your own text model (OpenAI-compatible API)

Summaries and translations can run on any server with the OpenAI chat completions
API instead of the local model: OpenAI, OpenRouter, or a model on your own machine
with LM Studio, Ollama or vLLM. In Settings ▸ Models ▸ Text Server:

1. Enter the **Server URL**, for example `https://api.openai.com/v1`,
   `http://localhost:1234/v1` (LM Studio) or `http://localhost:11434/v1` (Ollama).
2. Enter the **API key** (local servers usually need none) and the **Model** name.
   **Check Connection** lists the server's models and sends a short test request.
3. After the check succeeds, turn on **Use for summaries** and/or **Use for translations**.
   They cannot be turned on before, and changing the URL, key or model turns them off
   until the connection is checked again.
4. With **Use for summaries** on, the **Model** menu beside **Generate Summaries** offers
   the server and selects it by default; otherwise it selects the local text model chosen
   in Settings ▸ Models (Automatic: by your Mac's memory).

TalkTrack sets no context or response limit for a server: the whole meeting is sent in
one request and the server's own limits apply (the context in Settings ▸ Text is for the
local model only). If the server answers that a meeting is too large for its model, the
summary is made again from parts. The meeting title, description
and transcript of each summary or translation are sent to that server, so use only one
you trust. The key is stored in your Keychain (macOS may ask to allow access after an
update) and is sent only to the address it was entered for. Recording and
transcription always stay on your Mac. Existing results are not regenerated when you
switch.

### Updates

TalkTrack checks GitHub for a new release at launch and once a day (Settings ▸
General ▸ Updates, where automatic checks can be turned off and **Check Now** checks
immediately). When a newer version exists, TalkTrack shows it once in an alert and
keeps **Update Available** in the menu bar menu. Download the new `TalkTrack.dmg` and
drag TalkTrack to Applications to replace the old copy; meetings, models and settings
are kept. Only the release version and links are read; nothing about you is sent.

**After an update** (a new `TalkTrack.dmg` replacing the app) repeat one of the
methods. Because the signature changes with every build, macOS may also ask again
for Microphone access, and dictation for Accessibility and Input Monitoring; if recording or
Settings ▸ General ▸ Permissions reports that access is missing, open **System Settings ▸
Privacy & Security**, remove TalkTrack from those lists with **–**, reopen TalkTrack and allow
access again. TalkTrack now records system audio with **System Audio Recording
Only** instead of Screen & System Audio Recording: switch it on there once, and you can remove
TalkTrack from the Screen & System Audio Recording list.

### Where data is stored

| Data | Location |
|---|---|
| Meetings, audio, transcripts, notes, summaries | `~/Documents/TalkTrack/.talktrack-library` (movable in Settings ▸ General) |
| Models | `~/Library/Application Support/TalkTrack/Models` |
| Saved voices | `~/Library/Application Support/TalkTrack/Speakers.sqlite3` |
| Preferences, including the dictation dictionary and replacement rules | `defaults` domain `local.talktrack.app` |
| Dictation audio and text | Not stored (memory only) |

### Uninstall

Quit TalkTrack from the menu bar, delete `TalkTrack.app` from Applications, and, if
you also want to remove your data and models, delete the folders above and run
`defaults delete local.talktrack.app`.

## Building from source

Requirements: Apple Silicon Mac, full Xcode with Swift 6.3 or later and the Metal
toolchain, [XcodeGen](https://github.com/yonaskolb/XcodeGen) 2.44+
(`brew install xcodegen`).

```sh
git clone https://github.com/AnanichEgor/TalkTrack.git
cd TalkTrack
./scripts/build.sh      # Debug build, signed with Apple Development
./scripts/launch.sh
./scripts/test.sh       # package unit tests, no models needed
```

- The first build stops at Xcode's plugin trust check for MLX's `CudaBuild` plugin
  (it does nothing on macOS). Open `TalkTrack.xcodeproj` in Xcode, build once and
  choose **Trust & Enable**, then rerun the script.
- Debug builds sign with an Apple Development certificate so privacy permissions
  survive rebuilds. Set `DEVELOPMENT_TEAM` in `project.yml` to your own team and run
  `./scripts/build.sh -allowProvisioningUpdates` once.

### Making a release DMG

```sh
./scripts/package.sh
```

builds a Release app for arm64, signs it ad-hoc and writes `.build/dist/TalkTrack.dmg`
with a `.sha256` file. The version comes from `CFBundleShortVersionString` in
`project.yml` and appears in the disk name and the app. Raise it (and
`CFBundleVersion`) for every release: the app's update check compares it with the
latest release tag, so the tag must be `v` plus the same version.

To publish, push the commit and create a GitHub release with a tag matching the
version, attaching both files under exactly these names (the download links in this
README always point to the latest release):

```sh
gh release create v0.2.0 .build/dist/TalkTrack.dmg .build/dist/TalkTrack.dmg.sha256 \
  --title "TalkTrack 0.2.0" --notes "What changed in this version"
``` The app icon is drawn by `swift scripts/make-app-icon.swift`.

With a paid Apple Developer Program membership the same script produces a
Developer ID signed, notarized DMG that opens without warnings:

```sh
xcrun notarytool store-credentials talktrack-notary   # once
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" TEAM_ID=TEAMID \
NOTARY_PROFILE=talktrack-notary ./scripts/package.sh
```

More developer documentation: [docs/development.md](docs/development.md),
[docs/inference.md](docs/inference.md), [docs/storage.md](docs/storage.md),
[docs/transcription.md](docs/transcription.md), [docs/summaries.md](docs/summaries.md).
