# Hosting gemma-4-E4B-it (QAT 4-bit + MTP) with llama.cpp

Self-contained setup that serves
[`unsloth/gemma-4-E4B-it-qat-GGUF`](https://huggingface.co/unsloth/gemma-4-E4B-it-qat-GGUF)
(`gemma-4-E4B-it-qat-UD-Q4_K_XL.gguf`, ~4.22 GB) via `llama-server` and exposes
an **OpenAI-compatible HTTP API** that other machines on your LAN can call.

It runs with **MTP** (multi-token prediction self-speculative decoding) and a
single-stream, low-RAM configuration — see
[Performance / long context](#performance--long-context).

- **GPU**: NVIDIA GTX 1660 SUPER (6 GB), all layers on the GPU.
- **Server**: prebuilt llama.cpp CUDA binaries (release `b9811`, supports MTP).
- **Access**: LAN only, protected by a generated API key.

> **Hardware note (important).** On this GPU (a Turing card) MTP and
> flash-attention cannot run together — so this setup uses MTP with
> flash-attention **off**, **f16** KV cache (no compression), and a context
> ceiling around **64k**. See [Performance / long context](#performance--long-context)
> for the full explanation and the no-MTP alternative (full 128k + compression).

---

## Quick start

Run these from a PowerShell prompt **in this folder** (`D:\Hosting llm`):

```powershell
# 1. Download llama.cpp (CUDA binaries + CUDA runtime DLLs)
powershell -ExecutionPolicy Bypass -File .\1-setup.ps1

# 2. Download the model + MTP drafter (~4.28 GB total) into .\models\
powershell -ExecutionPolicy Bypass -File .\2-download-model.ps1

# 3. Start the API server (generates api-key.txt on first run)
powershell -ExecutionPolicy Bypass -File .\3-start-server.ps1
```

When the server is up you'll see:
```
server is listening on http://0.0.0.0:8080
```
and the startup banner prints your **LAN IP**, **API URL**, and **API key**.

Leave that window open — it runs the server. Stop it with `Ctrl+C`.

---

## Enable LAN access (one-time)

Open an **elevated** (Administrator) PowerShell and add a firewall rule for port 8080:

```powershell
New-NetFirewallRule -DisplayName "llama.cpp server (8080)" -Direction Inbound `
  -Action Allow -Protocol TCP -LocalPort 8080 -Profile Private
```

Find this PC's LAN IP so remote callers know the address:

```powershell
Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike '127.*' }
```

Remote callers then use `http://<that-ip>:8080`.

> Note: `-Profile Private` assumes your network is set to **Private**. If it's
> **Public**, either switch the network to Private or add `Public` to the profile
> list (less safe). Don't expose this to the open internet without a tunnel/VPN.

---

## Remote access over the internet (ngrok)

To call the API from **outside your LAN** (a phone on cellular, another network,
a cloud box), tunnel it with ngrok. No port-forwarding or firewall rule needed —
ngrok opens an outbound connection and gives you a public **HTTPS** URL.

1. Get a free authtoken: <https://dashboard.ngrok.com/get-started/your-authtoken>
2. Start the server in one window, then the tunnel in another:

```powershell
# window 1 - the model server (downloads ngrok on first run)
powershell -ExecutionPolicy Bypass -File .\3-start-server.ps1

# window 2 - the public tunnel
powershell -ExecutionPolicy Bypass -File .\4-start-tunnel.ps1 -AuthToken <your-token>
```

The token is saved to `ngrok-authtoken.txt` (git-ignored) on first run, so later
you can just run `.\4-start-tunnel.ps1`. You can also supply it via
`$env:NGROK_AUTHTOKEN`.

It prints your public URL, e.g.:

```
  Tunnel is LIVE
  Public  : https://abcd-1234.ngrok-free.app
  API     : https://abcd-1234.ngrok-free.app/v1/chat/completions
```

Use that URL as the base for any client (`<public-url>/v1/...`), e.g.
`.\test-client.ps1 -ServerUrl https://abcd-1234.ngrok-free.app`. Leave the
window open; `Ctrl+C` closes the tunnel (or run `.\stop.ps1`).

> ⚠️ **Secure it before tunneling.** This publishes your endpoint to the entire
> internet. The default server config is **open (no API key)** — fine on a
> trusted LAN, not on a public URL. Either:
> - set `$RequireApiKey = $true` in `3-start-server.ps1` and restart (clients
>   then need `Authorization: Bearer <key>`), **or**
> - add ngrok-level auth: `.\4-start-tunnel.ps1 -BasicAuth 'user:pass'`.
>
> The tunnel script detects an open API and warns you. Inspect live requests at
> <http://127.0.0.1:4040>.

**Options** for `4-start-tunnel.ps1`:

| Parameter     | Default | Notes                                                        |
|---------------|---------|-------------------------------------------------------------|
| `-AuthToken`  | —       | ngrok token. Falls back to `$env:NGROK_AUTHTOKEN`, then `ngrok-authtoken.txt`. |
| `-Port`       | `8080`  | Local port to expose (match `$Port` in `3-start-server.ps1`).|
| `-BasicAuth`  | —       | `"user:pass"` → ngrok requires HTTP basic auth on the tunnel.|
| `-Domain`     | —       | Reserved/static ngrok domain (paid), e.g. `myllm.ngrok.app`. |

---

## The API endpoint

Base URL: `http://<this-pc-ip>:8080`

| Method & path                  | Purpose                          |
|--------------------------------|----------------------------------|
| `GET  /health`                 | Health check                     |
| `POST /v1/chat/completions`    | OpenAI-compatible chat           |
| `POST /v1/completions`         | OpenAI-compatible text completion|
| `POST /completion`             | llama.cpp native completion      |
| `GET  /` (browser)             | Built-in chat web UI             |

**Auth**: every request must include `Authorization: Bearer <api-key>`
(the key in `api-key.txt`). Model name is `gemma-4-E4B-it`.

### Example: curl

```bash
curl http://<this-pc-ip>:8080/v1/chat/completions \
  -H "Authorization: Bearer <api-key>" \
  -H "Content-Type: application/json" \
  -d '{
        "model": "gemma-4-E4B-it",
        "messages": [{"role":"user","content":"Hello!"}]
      }'
```

### Example: Python (OpenAI SDK)

```bash
pip install openai
python test_client.py --base-url http://<this-pc-ip>:8080/v1 --api-key <api-key>
```

```python
from openai import OpenAI
client = OpenAI(base_url="http://<this-pc-ip>:8080/v1", api_key="<api-key>")
resp = client.chat.completions.create(
    model="gemma-4-E4B-it",
    messages=[{"role": "user", "content": "Hello!"}],
)
print(resp.choices[0].message.content)
```

### Test from this machine

```powershell
.\test-client.ps1
# or against the LAN address:
.\test-client.ps1 -ServerUrl http://<this-pc-ip>:8080
```

---

## Configuration

Edit the tunables at the top of `3-start-server.ps1`:

| Variable          | Default    | Notes                                              |
|-------------------|------------|----------------------------------------------------|
| `$Port`           | `8080`     | Listening port.                                    |
| `$BindHost`       | `0.0.0.0`  | `0.0.0.0` = LAN reachable; `127.0.0.1` = local only.|
| `$GpuLayers`      | `99`       | GPU layers. At ~64k context this is near the 6 GB ceiling **with MTP** — **lower this (~30)** if you hit a CUDA/VRAM OOM. |
| `$Context`        | `65536`    | Context window (64K). MTP forces flash-attention off, which is VRAM-heavier, so ~64k is the practical max here. Lower if you OOM. |
| `$CacheTypeK/V`   | `f16`      | **Must stay `f16` while MTP is on** — KV quantization needs flash-attention, which MTP can't use on this GPU. |
| `$CtxCheckpoints` | `2`        | Max context checkpoints per slot (llama.cpp default ~32). Lower = less RAM (less prompt-cache reuse). |
| `$Thinking`       | `$true`    | `$true` = model reasons first; `$false` = direct answers. |

The API key lives in `api-key.txt`. Delete it to rotate (a new one is generated
on next start).

---

## Performance / long context

`3-start-server.ps1` is configured around **MTP** plus a low-RAM, single-stream
setup:

| Goal | Flags | Effect |
|------|-------|--------|
| **MTP generation** | `-md models\mtp-gemma-4-E4B-it.gguf --spec-type draft-mtp --spec-draft-n-max 4 --spec-draft-ngl 99` | MTP self-speculative decoding. The drafter (~60 MB) is the model's own MTP head; it loads/stops with the server. |
| **MTP needs FA off** | `-fa off` | On this GPU, MTP + flash-attention crashes the CUDA kernel, so FA is off. |
| **Single stream** | `-np 1` | One server slot → one KV cache instead of several → less RAM. |
| **Fewer checkpoints** | `-ctxcp 2` (`$CtxCheckpoints`) | Context checkpoints down from the ~32 default → less RAM. |

### Hardware limitation on this GPU (read this)

The GTX 1660 SUPER is a **Turing** card. In llama.cpp build `b9811`, **MTP +
flash-attention abort with a fatal `fattn.cu` CUDA error**, so MTP only runs with
`-fa off`. That has two knock-on effects:

- **No KV-cache compression with MTP.** `q8_0`/`q4_0` KV requires flash-attention,
  which is off — so the cache stays `f16`.
- **~64k context ceiling.** Without FA the attention buffers are larger; ~64k is
  the most that fits in 6 GB with MTP (it fails to load at ≥98k).

Measured here (8k context, fresh): **no-MTP + FA + q8 ≈ 47 tok/s** vs
**MTP + FA-off ≈ 38 tok/s** — i.e. on *this* card MTP is a bit *slower*, because
losing flash-attention costs more than MTP gains. MTP's published ~1.4–2.2×
speedups assume an FA-capable GPU (RTX 30-series / Ampere+).

### If you'd rather have full 128k + compression (no MTP)

Edit `3-start-server.ps1`: remove the `-md / --spec-type / --spec-draft-*` args,
set `-fa on`, `$CacheTypeK/V = 'q8_0'`, and `$Context = 131072`. That config runs
the full 128k context with a compressed KV cache and is the fastest option on
this GPU. To get MTP *and* FA *and* compression together you'd need an
Ampere-or-newer GPU (or a future llama.cpp build that fixes MTP+FA on Turing).

### Tuning order when something doesn't fit
1. **CUDA / VRAM OOM** → lower `$GpuLayers` (e.g. `99 → 30`), then `$Context`.
2. **MTP not helping** (acceptance ~0 in the per-request log) → swap the drafter
   for `MTP\gemma-4-E4B-it-Q8_0-MTP.gguf` (download it the same way, then point
   `$MtpDraft` at it).

---

## Reasoning / thinking

Thinking is **enabled by default** (`$Thinking = $true` in `3-start-server.ps1`).
The model reasons before answering, and the server splits the response into two
fields:

- `message.reasoning_content` — the chain of thought
- `message.content` — the final answer

```python
resp = client.chat.completions.create(
    model="gemma-4-E4B-it",
    messages=[{"role": "user", "content": "What is 17 * 24?"}],
    max_tokens=1024,
)
print("Thinking:", resp.choices[0].message.reasoning_content)
print("Answer  :", resp.choices[0].message.content)
```

> **Important — give it room.** Thinking consumes tokens. If `max_tokens` is too
> small, the whole budget is spent reasoning and `content` comes back **empty**.
> Use `max_tokens` of ~1024+ when thinking is on.

**Per-request override** (no restart needed): pass `chat_template_kwargs` to turn
thinking on/off for a single call —
`"chat_template_kwargs": {"enable_thinking": false}` in the request body.

To turn it off globally, set `$Thinking = $false` and restart.

### Seeing the thinking in the browser UI

The thoughts are sent in the separate `reasoning_content` field (deepseek format),
**not** inline in the answer. In the web UI at `http://localhost:8080` they appear
in a collapsible **"Thinking" / "Thought for Ns"** panel just above the answer —
click it to expand. If you don't see it at all, hard-refresh the page
(`Ctrl+Shift+R`) to clear a cached older UI. API clients read the field directly
(`message.reasoning_content`), as shown above.

---

## Troubleshooting

- **CUDA out of memory (VRAM)** — lower `$Context` (e.g. `65536 → 32768`), then
  `$GpuLayers` (e.g. `99 → 30`). See [Performance / long context](#performance--long-context).
- **`fattn.cu` fatal error on start** — MTP + flash-attention on a Turing GPU.
  Ensure `-fa off` (it is by default); don't set `$CacheTypeK/V` to a quantized
  type while MTP is on (quantized KV would force FA back on).
- **System RAM too high** — lower `$Context` or set `$CtxCheckpoints` to `1`.
- **CUDA DLL fails to load / no GPU used** — update your NVIDIA driver
  (`winget upgrade --id Nvidia.GeForceExperience` or download from nvidia.com).
  As an alternative, re-run setup pointing at the `cuda-13.3` asset variant.
- **Remote machine can't connect** — confirm the firewall rule exists, the
  network profile is **Private**, both machines are on the same subnet, and the
  server log shows `listening on http://0.0.0.0:8080` (not `127.0.0.1`).
- **401 Unauthorized** — missing/wrong `Authorization: Bearer <key>` header.
- **Slow first response** — the model loads into VRAM on first request; warm-up
  is normal.

---

## Optional: add vision (image input)

This model is multimodal. To enable image input later, download the projector
and pass it to the server:

```powershell
hf download unsloth/gemma-4-E4B-it-qat-GGUF mmproj-F16.gguf --local-dir .\models
# then add to the llama-server args in 3-start-server.ps1:
#   --mmproj .\models\mmproj-F16.gguf
```
Note this uses ~944 MB additional VRAM.
