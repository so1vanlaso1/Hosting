#!/usr/bin/env bash
#
# 1-setup.sh - Linux equivalent of 1-setup.ps1.
#
# llama.cpp ships NO prebuilt Linux CUDA binaries, so this BUILDS llama-server
# from source with CUDA. Result binary: ./llama.cpp/build/bin/llama-server
#
# Target GPU: RTX 5060 Ti (Blackwell, sm_120) -> needs CUDA toolkit 12.8+ (13.x best).
#
# Run:  bash ./1-setup.sh
#
set -euo pipefail
cd "$(dirname "$0")"

RELEASE="${LLAMA_RELEASE:-b9811}"   # pin to match the Windows setup; set to "" for latest master
CUDA_ARCH="${CUDA_ARCH:-native}"    # 'native' = build for THIS GPU. Set CUDA_ARCH=120 to force
                                    # Blackwell when the GPU isn't visible at build time.
SRC="llama.cpp"

# --- build deps (Debian/Ubuntu). Comment out if you manage packages yourself ---
if command -v apt-get >/dev/null 2>&1; then
  echo "[deps] installing build tools..."
  ${SUDO:-} apt-get update -y
  ${SUDO:-} apt-get install -y build-essential cmake git libcurl4-openssl-dev
fi

# --- need the CUDA compiler (nvcc), and it must be new enough for Blackwell ---
if ! command -v nvcc >/dev/null 2>&1; then
  echo "[warn] nvcc not on PATH. CUDA build needs it; on most GPU cloud images it's"
  echo "       at /usr/local/cuda/bin -> try:  export PATH=/usr/local/cuda/bin:\$PATH"
else
  cuda_ver="$(nvcc --version | grep -oE 'release [0-9]+\.[0-9]+' | grep -oE '[0-9]+\.[0-9]+' | head -1)"
  echo "[cuda] toolkit ${cuda_ver:-unknown}"
  if [ -n "$cuda_ver" ]; then
    major="${cuda_ver%%.*}"; minor="${cuda_ver#*.}"
    # Blackwell / RTX 50-series (sm_120) requires CUDA 12.8+.
    if [ "$major" -lt 12 ] || { [ "$major" -eq 12 ] && [ "$minor" -lt 8 ]; }; then
      echo "[warn] CUDA $cuda_ver is older than 12.8 -- too old for an RTX 50-series (Blackwell)"
      echo "       GPU. Install CUDA 12.8+ (13.x recommended), or the build will produce a binary"
      echo "       that fails at runtime with 'no kernel image is available' on the 5060 Ti."
    fi
  fi
fi

# --- get source at the pinned release ---
if [ ! -d "$SRC/.git" ]; then
  echo "[src] cloning llama.cpp..."
  git clone https://github.com/ggml-org/llama.cpp "$SRC"
fi
if [ -n "$RELEASE" ] && [ "$RELEASE" != "master" ]; then
  git -C "$SRC" fetch --tags --quiet
  git -C "$SRC" checkout "$RELEASE"
fi

# --- build (only the server target; -j uses all cores) ---
# CMAKE_CUDA_ARCHITECTURES=native builds just for THIS GPU (fast). If the GPU is
# not visible at build time and cmake errors, drop that flag to build all archs.
echo "[build] compiling llama-server with CUDA (arch=$CUDA_ARCH; takes a few minutes)..."
cmake -S "$SRC" -B "$SRC/build" \
      -DGGML_CUDA=ON -DLLAMA_CURL=ON \
      -DCMAKE_BUILD_TYPE=Release -DCMAKE_CUDA_ARCHITECTURES="$CUDA_ARCH"
cmake --build "$SRC/build" --config Release -j"$(nproc)" --target llama-server

echo
echo "[ok] built: $SRC/build/bin/llama-server"
echo "Next: bash ./2-download-model.sh"
