#!/usr/bin/env bash
#
# 2-download-model.sh - Linux equivalent of 2-download-model.ps1.
# Downloads the QAT 4-bit model + MTP drafter (~4.28 GB) into ./models/.
# Prefers the HuggingFace CLI (hf / huggingface-cli); falls back to curl.
#
# Run:  bash ./2-download-model.sh
#
set -euo pipefail
cd "$(dirname "$0")"

REPO="unsloth/gemma-4-E4B-it-qat-GGUF"
FILES=( "gemma-4-E4B-it-qat-UD-Q4_K_XL.gguf" "mtp-gemma-4-E4B-it.gguf" )
mkdir -p models

get_file() {
  local f="$1" target="models/$1"
  if [ -f "$target" ]; then
    echo "[skip] already present: $f"
    return
  fi
  if command -v hf >/dev/null 2>&1; then
    echo "[down] hf download $REPO $f"
    hf download "$REPO" "$f" --local-dir models
  elif command -v huggingface-cli >/dev/null 2>&1; then
    echo "[down] huggingface-cli download $REPO $f"
    huggingface-cli download "$REPO" "$f" --local-dir models
  else
    echo "[warn] no hf CLI found; using curl"
    curl -L --fail -o "$target" "https://huggingface.co/$REPO/resolve/main/$f"
  fi
  [ -f "$target" ] || { echo "ERROR: download finished but $target missing"; exit 1; }
  echo "[ok]   $f"
}

for f in "${FILES[@]}"; do get_file "$f"; done

echo
echo "[ok] all files in ./models"
echo "Next: bash ./3-start-server.sh"
