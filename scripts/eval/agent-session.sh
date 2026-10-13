#!/bin/bash
# Make the session of the agent eval E38 (docs/workflow/evals.md): Show.dirigible in the current
# folder, with two mono tracks of generated speech, host "Track 1" and guest "Track 2". The host
# starts with 6 s of silence (task T2). The session is about 90 s long, so minute 1 exists (T3).
# Usage: scripts/eval/agent-session.sh <dirigible binary>
# scripts/eval/agent-tasks.sh runs it inside scripts/probe.sh --no-audio: `say -o` writes a file
# and opens no audio device.
set -euo pipefail
bin="$1"
mkdir -p audio
host="[[slnc 6000]] Welcome to the show. Today we talk about home studios, microphones, and how to record a remote guest."
guest="Thanks for having me. I record in a small room with a dynamic microphone and a lot of blankets on the walls."
for i in $(seq 14); do
    host="$host Point $i. A good recording starts with a quiet room and a steady level. [[slnc 1500]]"
    guest="$guest Answer $i. I check the level before each take and I keep the gain low. [[slnc 1500]]"
done
say -v Samantha -o audio/host.aiff "$host"
say -v Daniel -o audio/guest.aiff "$guest"
"$bin" create Show.dirigible --sample-rate 48000
"$bin" track add Show.dirigible --name "Track 1" --layout mono --id host >/dev/null
"$bin" track add Show.dirigible --name "Track 2" --layout mono --id guest >/dev/null
"$bin" import Show.dirigible audio/host.aiff --track host --at 0 --no-level
"$bin" import Show.dirigible audio/guest.aiff --track guest --at 0 --no-level
