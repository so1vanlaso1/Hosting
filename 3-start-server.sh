#!/usr/bin/env bash
#
# 3-start-server.sh - Linux equivalent of 3-start-server.ps1.
# Launches llama-server with the Gemma 4 E4B model + MTP, bound to all
# interfaces so the OpenAI-compatible API is reachable remotely.
#
#   <host>:8080/                     browser chat UI
#   <host>:8080/health               health check
#   <host>:8080/v1/chat/completions  OpenAI-compatible chat
#
# Override any tunable inline, e.g.:  PORT=9000 CTX=16000 bash ./3-start-server.sh
#
# Run:  bash ./3-start-server.sh
#
set -euo pipefail
cd "$(dirname "$0")"

# --- tunables (env-overridable) ---------------------------------------------
PORT="${PORT:-8080}"
HOSTBIND="${HOSTBIND:-0.0.0.0}"   # 0.0.0.0 = reachable from outside; 127.0.0.1 = local only
NGL="${NGL:-99}"                  # GPU layers (all). Lower (e.g. 30) only if you hit VRAM OOM.
CTX="${CTX:-131072}"              # full 128k context; fits in 16 GB with flash-attention on
FA="${FA:-on}"                    # flash-attention: on for Blackwell/Ampere+ (RTX 5060 Ti).
                                  # Set FA=off only for a Turing card (GTX 16/20-series).
KV="${KV:-q8_0}"                  # KV cache type. q8_0 ~halves KV VRAM (requires FA=on);
                                  # use KV=f16 for max quality (16 GB has room).
ALIAS="gemma-4-E4B-it"
SERVER="${SERVER:-llama.cpp/build/bin/llama-server}"
MODEL="models/gemma-4-E4B-it-qat-UD-Q4_K_XL.gguf"
MTP="models/mtp-gemma-4-E4B-it.gguf"

[ -x "$SERVER" ] || { echo "Missing $SERVER. Run ./1-setup.sh first."; exit 1; }
[ -f "$MODEL"  ] || { echo "Missing $MODEL. Run ./2-download-model.sh first."; exit 1; }
[ -f "$MTP"    ] || { echo "Missing $MTP (MTP drafter). Run ./2-download-model.sh first."; exit 1; }

echo
echo "  Starting llama-server"
echo "  ---------------------------------------------------------------"
echo "  Local : http://localhost:$PORT"
echo "  API   : http://<this-host>:$PORT/v1/chat/completions"
echo "  Model : $ALIAS"
echo "  Auth  : (none - OPEN access; gate it before exposing publicly)"
echo "  ---------------------------------------------------------------"
echo

# Tuned for the RTX 5060 Ti (Blackwell): flash-attention ON runs MTP + FA +
# quantized KV + full 128k context all together. On a Turing card: FA=off KV=f16.
exec "$SERVER" \
  -m "$MODEL" \
  --host "$HOSTBIND" --port "$PORT" \
  -ngl "$NGL" -c "$CTX" \
  -fa "$FA" -ctk "$KV" -ctv "$KV" \
  -np 1 -ctxcp 8 \
  -md "$MTP" --spec-type draft-mtp --spec-draft-n-max 4 --spec-draft-ngl 99 \
  --jinja --alias "$ALIAS" \
  --reasoning on --reasoning-format deepseek --reasoning-budget -1
