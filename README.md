# Jotter

A Mac menu-bar app for meetings and dictation. It records your meetings, transcribes them on your Mac, writes notes with decisions, goals and actions, and files them in a folder of your choice. Holding one key dictates into any app.

## Install

Needs a Mac with Apple silicon and macOS 26 or later. In Terminal:

```
curl -fsSL https://raw.githubusercontent.com/jamiejefferson/jotter/main/install.sh | bash
```

Jotter appears as an icon in the menu bar. It checks for new versions every few hours: a Mac notification and a card in the panel say when one is ready, and "Update now" installs it and reopens Jotter. It waits if a meeting is recording or its notes are being written.

## First run

1. **Permissions.** The first dictation asks for Accessibility (to hear the key and paste for you) and the microphone. The first meeting asks for Screen & System Audio Recording, which Jotter uses for call audio only.
2. **Settings** (from the menu-bar panel):
   - **You:** your name and the names people call you, so actions given to you are marked as yours.
   - **Notes folder:** where notes are filed. The default is `~/Documents/Jotter`. An Obsidian vault works well.
   - **Connection:** paste an OpenRouter key from [openrouter.ai/keys](https://openrouter.ai/keys). Meeting notes and dictation tidying use it, billed to your OpenRouter account. Recording, transcripts and basic tidying work without one.

## Use

- **Dictate:** hold right ⌘, speak, let go. The words are pasted where you were typing. Hold Shift too to say a correction, such as "change Thursday to Friday" or "scratch that".
- **Meeting:** double-tap right ⌘ to start and stop (or ⌃⌥⌘J). A small bar shows the time, a project menu, Pause (⌃⌥⌘P) and Stop. When you stop, the bar shows progress and then "Notes ready" with a View button.
- **Voice note:** ⌃⌥⌘N records your mic only.
- **Call prompt:** when Teams, Zoom, FaceTime or a browser call has used the microphone for 15 seconds and Jotter isn't recording, a notification asks "Jot notes for this meeting?". Click it (or Record) to start. If you're recording and the call app lets go of the microphone for 45 seconds, a second notification offers to stop and write the notes. Dictation apps, Voice Memos and Granola don't trigger it. Turn it off in Settings › General.
- **Meetings window:** every meeting with its notes and transcript. "Filed in" moves a note to another project folder, or makes a new one.
- The key can be changed in Settings (right ⌘, right ⌥, right ⌃ or Fn).

Notes go to `<notes folder>/Projects/<project>/Meetings/`, or `<notes folder>/Meetings/Needs filing/` when the project is unclear, with the transcript beside them. Each note keeps a "My notes" section that survives rewrites.

## Privacy

- Audio and transcripts stay on your Mac. Transcription uses Apple's on-device speech engine.
- Transcripts are sent to a model through OpenRouter to write notes, and dictated text is sent to tidy it (Tidy setting only). Jotter asks OpenRouter to use only providers that neither store nor train on what is sent.
- Recordings are in `~/Library/Application Support/Jotter/Recordings/`. Your OpenRouter key is in `~/Library/Application Support/Jotter/Keys/`, readable only by your Mac user.
- `keys.log` in the same folder records what the dictation key did (pressed, released, listening, or why a press was ignored) so a missed press can be traced. It never records which other keys you type.
- Feedback sends only what you type, with Jotter's and macOS's version numbers, and your name if you tick the box.

## Feedback

Use **Feedback** in the menu-bar panel. It goes to the people building Jotter.

## Build from source

```
./build.sh                 # builds and installs ~/Applications/Jotter.app
./release.sh               # builds dist.nosync/Jotter.zip and publishes a GitHub release
```

The build signs with the "IDEalize Local Signing" certificate when it is present, so macOS keeps permissions across updates; otherwise it signs ad hoc. Never rebuild while a recording is running: a `.caf` file in the Recordings folder means one is.

### How audio is stored

Each track is written as it arrives to a 32-bit float `.caf`, which survives a crash or power loss. On stop it is compressed to AAC `.m4a`, and the `.caf` is deleted once the `.m4a` is checked to be the full length. A `.caf` left by a crash is compressed on the next launch.

### Development checks

```
B=~/Applications/Jotter.app/Contents/MacOS/Jotter
$B --selftest-mic 5 /tmp/jt-mic      # records the built-in mic for 5 s
$B --selftest-call 5 /tmp/jt-call    # records system audio for 5 s
$B --selftest-recover                # compresses unfinished recordings
$B --selftest-dictate <audio file>   # streams a file through dictation and times it
$B --selftest-tidy "<text>"          # Light and Tidy versions of some text
$B --selftest-correct "<text>" "<instruction>"
$B --selftest-notes <recording>      # writes and files notes for a recording
$B --transcribe <recording>          # transcribes a recording on the Mac
$B --render-check <folder>           # renders the wordmark and controls to PNGs
$B --mic-users [pid]                 # apps using the microphone now, or the app that owns a process
$B --show-meetings | --show-settings | --show-feedback
```

### Code

| File | Role |
|---|---|
| `Capture.swift` | Built-in mic and call audio through Core Audio (a process tap for call audio). |
| `TrackWriter.swift` | Mono mixdown, crash-safe writing, compression. |
| `Recorder.swift` | Start, stop, pause, levels, shortcuts, saving and recovery. |
| `Transcribe.swift` | On-device transcription of both tracks into one timeline. |
| `MeetingNotes.swift` | Notes prompt, model call, filing and new projects. |
| `Dictation.swift` | Hold-to-dictate, tidying, spoken corrections, name fixes. |
| `Updater.swift` | Checks GitHub releases, notifies, and installs updates in place. |
| `CallWatcher.swift` | Notices a call app using the microphone and offers to start or stop a recording; owns all Jotter notifications and their buttons. |
| `ModelAccess.swift` | OpenRouter (or KeyBus) connection and key files. |
| `Profile.swift` | Per-person settings: name, notes folder, calendar. |
| `WorkCalendar.swift` | Optional match to a calendar invite through the Composio CLI. |
| `JotterApp.swift`, `RecordingHUD.swift`, `MeetingsWindow.swift`, `SettingsWindow.swift`, `ConnectionView.swift`, `Theme.swift` | Interface, in the Canon and Indy visual language. |
| `SelfTest.swift` | Command-line checks. |
