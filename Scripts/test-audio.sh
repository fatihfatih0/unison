#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p build
python3 - <<'PY'
import wave, math, struct
with wave.open('/tmp/unison-test-tone.wav', 'wb') as f:
    f.setnchannels(2)
    f.setsampwidth(2)
    f.setframerate(48000)
    f.writeframes(b''.join(struct.pack('<hh', v, v)
        for i in range(48000 * 12)
        for v in [int(1600 * math.sin(2 * math.pi * 440 * i / 48000))]))
PY
report="$PWD/build/audio-regression.txt"
rm -f "$report"
open -n build/Products.noindex/Unison.app --args --audio-smoke --selection-smoke --smoke-report "$report"
for attempt in {1..120}; do
    if [[ -f "$report" ]]; then
        cat "$report"
        if rg -q '^ERROR=' "$report" || ! rg -q '^previous_route_restored=true$' "$report"; then exit 1; fi
        exit 0
    fi
    sleep 0.25
done
echo "Ses testi zamanında tamamlanmadı; macOS izin penceresini kontrol edin."
exit 1
