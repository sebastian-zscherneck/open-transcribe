# open-transcribe — Design

Stand: 2026-08-16

Lokaler Meeting-Transkriptions-Daemon für macOS. Erkennt Meetings an der Mikrofon-Nutzung,
fragt in der Notch nach, nimmt Mic und Systemaudio getrennt auf, transkribiert und diarisiert
vollständig on-device und legt ein sprecher-annotiertes Markdown-Transkript in
`~/work/hq-wiki/raw/` ab. Alles Weitere (Zusammenfassung, Reports, Linear-Issues) macht der
bestehende Raw-Ingest-Cron.

## Entscheidungen

| Thema | Entscheidung |
|---|---|
| Repo | Eigenes Repo `open-transcribe`, lauffähig ohne OpenNotch |
| Engine | FluidAudio (Parakeet TDT v3, Pyannote Community-1, WeSpeaker), 100% lokal |
| Erkennung | CoreAudio `kAudioProcessPropertyIsRunningInput` + Bundle-ID-Allowlist |
| Capture | CoreAudio Process Taps (Remote) + AVAudioEngine (Mic), zwei getrennte Spuren |
| Popup | Notch fragt, Default ist verwerfen, 90s RAM-Vorpuffer |
| Sprecher | Mic = Sebastian, Remote = Diarisierung + Kalender-Pool + Stimmprofile |
| Titel | `claude -p` headless auf den ersten ~3000 Zeichen |
| Output | Markdown mit Frontmatter nach `~/work/hq-wiki/raw/YYYY-MM-DD-{slug}.md` |
| Audio | Nach erfolgreichem Schreiben gelöscht |
| Kopplung | Datei-IPC über `~/.opentranscribe/`, OpenNotch liest und schreibt Kommandos |

## Fremdcode

- **FluidAudio** (Apache-2.0, SwiftPM): ASR, Diarisierung, Speaker-Embeddings, VAD.
- **insidegui/AudioCap** (BSD-2): Referenzmuster für CoreAudio Process Taps, abgeschrieben, keine Dependency.
- **leits/MeetingBar** (Apache-2.0): Referenz für Kalender-Event- und Meeting-Link-Parsing.
- **argmax-oss-swift / WhisperKit** (MIT): Reserve-Engine, falls Parakeet v3 bei DE/EN-Mix schwächelt.

## Architektur

Drei Produkte in einem SwiftPM-Paket:

- `OpenTranscribeCore` — Library, UI-frei, vollständig testbar.
- `opentranscribed` — Agent-App (`LSUIElement`), hält Permissions, läuft beim Login, Menubar nur als Notausgang.
- `otcli` — CLI zum Debuggen: `status`, `start`, `stop`, `finalize <session>`, `profiles`.

### Module in OpenTranscribeCore

| Modul | Aufgabe | Abhängigkeiten |
|---|---|---|
| `Detection` | Prozessliste beobachten, Trigger/Blacklist, Entprellung, Zustandsautomat | CoreAudio |
| `Capture` | Mic-Tap, Process-Tap auf die Meeting-App, RAM-Vorpuffer, WAV-Writer | CoreAudio, AVFoundation |
| `Transcribe` | Live-Chunks und Final-Pass, Diarisierung, Merge beider Spuren | FluidAudio |
| `Speakers` | Embedding-Store, Matching, Kalender-Kandidatenpool | FluidAudio, EventKit |
| `Output` | Titel via `claude -p`, Slug-Validierung, atomarer Markdown-Writer | Foundation |
| `State` | `state.json` schreiben, Kommandos lesen, Crash-Recovery | Foundation |

### Datei-IPC

```
~/.opentranscribe/
  state.json            Daemon schreibt atomar bei jedem Übergang
  commands/<uuid>.json  UI schreibt, Daemon konsumiert und löscht
  transcript.live.jsonl Live-Vorschau, pro Zeile ein Segment
  recordings/<session>/{mic.wav,remote.wav,meta.json}
  profiles/<person>.json  Stimm-Embeddings, gemittelt
  logs/
```

Kommandos: `start`, `discard`, `pause`, `resume`, `stop`, `assignSpeaker`, `finalize`.

`state.json` (Auszug):

```json
{
  "phase": "recording",
  "session": "2026-08-16T14-03-11",
  "app": "us.zoom.xos",
  "appName": "Zoom",
  "startedAt": "2026-08-16T14:03:11Z",
  "calendarTitle": "Mühlenbäcker Weekly",
  "attendees": ["Alex Meyer"],
  "recentLines": [{"speaker": "Sebastian", "text": "..."}],
  "pendingQuestion": null,
  "error": null
}
```

Phasen: `idle`, `detected`, `recording`, `paused`, `finalizing`, `written`, `error`.

## Erkennung

- Listener auf `kAudioHardwarePropertyProcessObjectList`, pro Prozess `kAudioProcessPropertyIsRunningInput`
  und `kAudioProcessPropertyBundleID`.
- Allowlist (Settings): Zoom, Teams, Slack, Chrome, Arc, Safari, FaceTime, Discord.
- Blacklist: eigene Bundle-ID, Wisper Clone, Systemdiktat.
- Entprellung: 15s durchgehende Mic-Nutzung durch eine Trigger-App.
- Ende: Trigger-App gibt das Mic 20s frei.
- EventKit liest nur mit, liefert Titel und Teilnehmerpool, ist nie Trigger.

Popup: ab Erkennung läuft ein 90s-RAM-Vorpuffer. Zusage innerhalb der 90s rettet den Meeting-Anfang.
Keine Antwort heißt verwerfen, nichts geht auf Platte. Popup ist 60s prominent, danach ein
klickbarer Punkt, mit dem noch ohne Vorlauf gestartet werden kann.

## Capture

- Zwei Spuren, nie gemischt. Mic-Spur ist definitionsgemäß Sebastian.
- Mic: AVAudioEngine-Tap, 16 kHz mono, Voice-Processing gegen Echo, Default-Input wird nie umgeschaltet.
- Remote: CoreAudio Process Tap auf die Meeting-App, damit Spotify und Notifications draußen bleiben.
  Fallback: System-Mix-Tap ohne den eigenen Prozess.
- Ablage als WAV 16 kHz mono, rund 115 MB pro Stunde für beide Spuren zusammen.

## Transkription und Sprecher

Live, alle 20s, VAD-gated: beide Chunks durch Parakeet v3, Ergebnis als `Du`/`Andere` in
`transcript.live.jsonl`. Reine Panel-Vorschau, geht nie ins Wiki.

Final-Pass beim Stoppen:

1. Beide Spuren komplett durch Parakeet v3 mit Wort-Zeitstempeln.
2. Remote-Spur zusätzlich durch Pyannote Community-1 (Cluster mit Zeitbereichen).
3. Wörter der Remote-Spur per Zeitüberlappung dem Cluster zuordnen.
4. Pro Cluster ein WeSpeaker-Embedding, Abgleich gegen `profiles/`. Über Schwelle Name, sonst `Speaker B`.
5. Kandidatenpool aus dem laufenden Kalendertermin ans Panel.
6. Chronologischer Merge beider Spuren.

Nachträgliches Benennen schreibt die Datei atomar neu und mittelt das Embedding ins Profil.
Der Ingest-Cron läuft alle 4h, das Zeitfenster reicht.

## Output

Dateiname: `claude -p` auf die ersten ~3000 Zeichen, Slug gegen `^[a-z0-9-]{3,40}$` validiert,
Fallback `meeting-{app}-{HHMM}`, Kollision bekommt `-2`. Ziel
`~/work/hq-wiki/raw/YYYY-MM-DD-{slug}.md`, atomar über temporäre Datei plus Rename.

```
---
description: Meeting-Transkript Mühlenbäcker Weekly, 49 min
updated: 2026-08-16
teilnehmer: Sebastian, Alex, Speaker C
quelle: open-transcribe (Zoom, 14:03-14:52)
---

[00:00:12] Sebastian: Moin, danke dass du dir Zeit nimmst.
[00:00:19] Alex: Klar, gerne.
```

## Fehlerverhalten

- Jeder Zustandsübergang landet in `state.json`.
- Absturz im Meeting: `recordings/` überlebt, beim Start bietet der Daemon die Nachverschriftung an.
- Fehlende Permission, fehlendes Modell, volle Platte, fehlende `claude`-CLI: definierter Fallback plus
  sichtbarer Fehlerzustand in der Notch. Audio wird nie gelöscht, solange das Schreiben nicht glückte.
- Ohne Netz läuft alles außer dem LLM-Titel.

## Tests

- Unit: Zustandsautomat gegen gefälschte Prozessliste, Entprellung, Chunker, Zeit-Merge zweier Spuren,
  Slug-Validierung, Profil-Matching an der Schwelle, Writer inklusive Kollision und Atomarität.
- Integration: Fixture aus zwei kurzen WAV-Spuren mit bekanntem Inhalt und drei Sprechern, komplette
  Pipeline bis zur Datei.
- Live: echtes Meeting mit mindestens einer weiteren Person, Datei korrekt in `raw/`, Namen nach einer
  Bestätigung richtig. Erst das gilt als fertig.

## Milestones

1. **M1 Erkennung** — Daemon, Zustandsautomat, `state.json`, OpenNotch-Modul mit Popup und Stop, kein Audio.
2. **M2 Aufnahme und Transkript** — zwei Spuren, Final-Pass, Datei in `raw/` mit `Sebastian`/`Andere`.
3. **M3 Sprecher** — Diarisierung, Kalender-Pool, Profile, Benennen-UI.
4. **M4 Feinschliff** — Live-Text im Panel, Titel via `claude -p`, Retention, Fehlerzustände, Settings.

## Abweichungen aus der Umsetzung

- **Swift Testing fehlt im Toolchain.** Auf diesem Rechner ist kein volles Xcode installiert, die
  Command Line Tools liefern kein importierbares `Testing`-Modul. Beide Repos ziehen es deshalb als
  Package-Dependency (`swiftlang/swift-testing`, exakt 6.3.1), und `scripts/test.sh` setzt die
  Linker- und rpath-Flags auf `lib_TestingInterop.dylib` aus den Command Line Tools.
- **Sprecher-Namen im Final-Pass.** `FluidTranscriber` bekommt den `ProfileStore` injiziert und
  ersetzt ein Cluster-Label direkt durch den bekannten Namen, wenn das Stimm-Embedding über der
  Schwelle matcht. Das Embedding pro Cluster ist das dauergewichtete Mittel seiner Segmente.
  Für den umgekehrten Weg (Nutzer benennt, App merkt sich) gibt es das Protokoll `SpeakerLearning`.
- **Preroll bleibt im Ring.** Der 90s-Ringpuffer läuft auch während der Aufnahme weiter und ist die
  Quelle für `recentSamples`, aus der die Live-Vorschau ihre Chunks zieht.
- **`pause` stoppt nur das Schreiben**, nicht die Audioquellen. Pausiertes Audio landet im Ring und
  wird verworfen, statt Hardware neu zu initialisieren.
- **CoreAudio Process Taps statt ScreenCaptureKit** für die Remote-Spur, wie im Verlauf entschieden.
  Fallback ist ein globaler Tap mit Ausschluss des eigenen Prozesses.

## Nicht im Scope

- Zusammenfassungen, Action Items, Mail-Entwürfe (macht der Raw-Ingest).
- Cloud-Transkription, Bot der ins Meeting joint.
- Caption-Scraping per Browser-Extension (mögliche spätere Phase).
- Windows, iOS.
