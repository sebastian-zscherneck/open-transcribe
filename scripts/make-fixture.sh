#!/bin/bash
# Builds a two-track meeting fixture from macOS speech synthesis: one microphone track with a
# single voice, one remote track alternating between two other voices with silence in between,
# so diarization has something real to separate. Everything runs offline.
set -euo pipefail

OUT="${1:-/tmp/ot-fixture}"
mkdir -p "$OUT"
WORK="$OUT/work"
mkdir -p "$WORK"

say_track() {   # voice, text, outfile
    say -v "$1" -o "$3" --file-format=WAVE --data-format=LEI16@16000 "$2"
}

silence() {     # seconds, outfile
    /usr/bin/python3 - "$1" "$2" <<'PY'
import struct, sys, wave
seconds, path = float(sys.argv[1]), sys.argv[2]
with wave.open(path, "w") as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000)
    w.writeframes(struct.pack("<%dh" % int(16000 * seconds), *([0] * int(16000 * seconds))))
PY
}

# Microphone: Sebastian's side of the conversation.
say_track "Markus" "Moin Alex, danke dass du dir kurz Zeit nimmst. Ich wollte den Stand beim Amazon Dashboard durchgehen. Die Zahlen aus sellerboard laufen jetzt jede Nacht automatisch rein." "$WORK/mic.wav"

# Remote: two different voices, so the diarizer has two clusters to find.
say_track "Anna" "Klar, sehr gerne. Bei uns ist die Frage vor allem, ob die Lagerbestände richtig gezogen werden." "$WORK/remote_a_raw.wav"
say_track "Rocko" "Ich würde noch ergänzen, dass wir die Werbekosten pro Produkt getrennt sehen wollen." "$WORK/remote_b_raw.wav"

silence 1.5 "$WORK/gap.wav"

cp "$WORK/mic.wav" "$OUT/mic.wav"
cp "$WORK/remote_a_raw.wav" "$WORK/remote_a.wav"
cp "$WORK/remote_b_raw.wav" "$WORK/remote_b.wav"

/usr/bin/python3 - "$WORK" "$OUT/remote.wav" <<'PY'
import sys, wave
work, out = sys.argv[1], sys.argv[2]
parts = [f"{work}/gap.wav", f"{work}/remote_a.wav", f"{work}/gap.wav", f"{work}/remote_b.wav"]
with wave.open(out, "w") as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000)
    for part in parts:
        with wave.open(part) as r:
            w.writeframes(r.readframes(r.getnframes()))
PY

rm -rf "$WORK"
echo "fixture ready:"
ls -la "$OUT"
