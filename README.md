# open-transcribe

A macOS daemon that notices you are in a meeting, asks in the notch whether to transcribe it,
and drops a speaker-attributed transcript into your wiki inbox. Everything runs on this Mac:
no cloud, no bot joining the call, no account.

## What it does

1. Watches which processes hold the microphone. When Zoom, Teams, Slack or a browser keeps it
   for 15 seconds, that counts as a meeting. Dictation apps are on an ignore list.
2. Asks in the notch: transcribe this? Audio buffers in memory from the first second, so saying
   yes still captures the start. Saying nothing discards the buffer and nothing ever hits the disk.
3. Records two separate tracks: your microphone, and the meeting app's own audio. Two tracks are
   what makes speaker attribution work — the microphone is you, by definition.
4. On stop, transcribes both tracks with Parakeet TDT v3 and diarizes the remote track with
   pyannote, both on the Neural Engine via [FluidAudio](https://github.com/FluidInference/FluidAudio).
5. Writes `~/work/hq-wiki/raw/YYYY-MM-DD-topic.md` with `Name: text` lines, then deletes the audio.

Summaries, action items and follow-ups are deliberately out of scope: the wiki's own ingest
pipeline already does that with the file this tool produces.

## Requirements

- macOS 15 or newer, Apple Silicon
- Swift 6.3 toolchain
- Optional: [OpenNotch](https://github.com/sebastian-zscherneck/open-notch) for the notch UI.
  Without it the daemon falls back to notifications and the `otcli` command.

## Install

```bash
./scripts/install.sh    # build, install into /Applications, start
otcli status            # see what the daemon thinks is going on
```

macOS will ask for microphone, audio capture and calendar access on first use. The app is
ad-hoc signed, so those prompts can reappear after a rebuild.

## Layout

| Path | What lives there |
|---|---|
| `Sources/OpenTranscribeCore/Contracts` | Shared types and protocols, the seam every module plugs into |
| `Sources/OpenTranscribeCore/Detection` | CoreAudio process watching and the meeting state machine |
| `Sources/OpenTranscribeCore/Capture` | Microphone tap, process tap, preroll ring buffer, WAV writing |
| `Sources/OpenTranscribeCore/Transcribe` | ASR, diarization, track merging |
| `Sources/OpenTranscribeCore/Speakers` | Voice profiles that survive between meetings |
| `Sources/OpenTranscribeCore/Output` | Title generation, markdown rendering, atomic wiki writes |
| `Sources/OpenTranscribeCore/Daemon` | The coordinator that wires it all together |
| `Sources/opentranscribed` | The background app |
| `Sources/otcli` | Debug CLI over the same file IPC the UI uses |

## Debugging

```bash
otcli status                       # what the daemon thinks is going on
otcli processes                    # every audio process, who holds the mic, who is a trigger
otcli sessions                     # recordings still on disk
otcli miccheck 30                  # hold the microphone, to exercise detection for real
otcli capturecheck 10 com.spotify.client
                                   # runs both capture sources through the installed app (which
                                   # has mic/audio permission, unlike this CLI) and reports
                                   # sample count, peak and RMS per track
otcli transcribe mic.wav remote.wav /tmp/out [--learn "Speaker A=Alex"]
                                   # whole transcription pipeline on existing tracks
./scripts/make-fixture.sh /tmp/ot-fixture   # two-track German test audio, three voices
./scripts/test.sh                  # unit and integration tests
```

Browsers and Electron apps hold the microphone in a helper process, so triggers match a bundle id
and everything beneath it: `com.google.Chrome.helper` counts as Chrome. To drive detection without
a real meeting, add your terminal to `triggerBundleIDs` in `~/.opentranscribe/settings.json` and run
`otcli miccheck`.

## Talking to the daemon

State and commands are plain files under `~/.opentranscribe/`, which is also how OpenNotch
talks to it. No XPC, no entitlements, and you can watch the whole conversation with `cat`.

```
state.json              current phase, session, live preview lines, pending question
commands/<uuid>.json    start | discard | pause | resume | stop | assignSpeaker | finalize
recordings/<session>/   mic.wav, remote.wav, meta.json — deleted after a successful transcript
profiles/               voice embeddings of people you have named once
```

## Recording other people

Recording a conversation without telling the other side is illegal in Germany
(§201 StGB). The daemon shows a visible recording indicator and never starts on its own —
it always asks. Say that you are recording.

## Design

[docs/superpowers/specs/2026-08-16-open-transcribe-design.md](docs/superpowers/specs/2026-08-16-open-transcribe-design.md)

## License

MIT
