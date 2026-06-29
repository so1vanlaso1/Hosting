#!/usr/bin/env bash
#
# 4-start-tunnel.sh - Linux equivalent of 4-start-tunnel.ps1.
# Exposes the local server to the public internet over HTTPS via ngrok.
#
# Authtoken resolution (first wins):
#   ./4-start-tunnel.sh <token>      argument
#   $NGROK_AUTHTOKEN                 environment variable
#   ngrok-authtoken.txt              file in this folder
# Saved to ngrok-authtoken.txt on first run (git-ignored).
# Get a free token: https://dashboard.ngrok.com/get-started/your-authtoken
#
# Run:  bash ./4-start-tunnel.sh <token>
#
set -euo pipefail
cd "$(dirname "$0")"

PORT="${PORT:-8080}"
TOKEN="${1:-${NGROK_AUTHTOKEN:-}}"
TOKEN_FILE="ngrok-authtoken.txt"
NGROK_DIR="ngrok"
NGROK="$NGROK_DIR/ngrok"
NGROK_URL="https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-linux-amd64.tgz"

# --- resolve token ----------------------------------------------------------
if [ -z "$TOKEN" ] && [ -f "$TOKEN_FILE" ]; then
  TOKEN="$(tr -d '[:space:]' < "$TOKEN_FILE")"
fi
if [ -z "$TOKEN" ]; then
  echo "No ngrok authtoken. Provide one of:"
  echo "  ./4-start-tunnel.sh <token>"
  echo "  export NGROK_AUTHTOKEN=<token>"
  echo "  echo <token> > $TOKEN_FILE"
  echo "Get one free: https://dashboard.ngrok.com/get-started/your-authtoken"
  exit 1
fi
if [ ! -f "$TOKEN_FILE" ]; then
  printf '%s' "$TOKEN" > "$TOKEN_FILE"
  echo "[token] saved -> $TOKEN_FILE (git-ignored)"
fi

# --- download ngrok on first run --------------------------------------------
if [ ! -x "$NGROK" ]; then
  echo "[ngrok] downloading..."
  mkdir -p "$NGROK_DIR"
  curl -sSL "$NGROK_URL" | tar -xz -C "$NGROK_DIR"
  [ -x "$NGROK" ] || { echo "ERROR: ngrok not found after extraction"; exit 1; }
fi

# --- warn if the API is open (ngrok publishes it to the whole internet) ------
if curl -fsS "http://127.0.0.1:$PORT/v1/models" >/dev/null 2>&1; then
  echo
  echo "  *** SECURITY WARNING ***"
  echo "  The API accepts requests with NO API KEY and ngrok will publish it"
  echo "  to the public internet. Gate it before relying on the tunnel:"
  echo "    - add an --api-key to 3-start-server.sh, or"
  echo "    - run ngrok with basic auth (see below)."
fi

"$NGROK" config add-authtoken "$TOKEN" >/dev/null
echo
echo "[tunnel] starting. Your public https URL appears in the ngrok screen below."
echo "         Inspector / public URL (headless): curl http://127.0.0.1:4040/api/tunnels"
echo "         Add basic auth instead with:  $NGROK http $PORT --basic-auth user:pass"
echo
exec "$NGROK" http "$PORT"
