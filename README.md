# Hosting gemma-4-E4B-it (QAT 4-bit + MTP) with llama.cpp

Self-contained setup that serves
[`unsloth/gemma-4-E4B-it-qat-GGUF`](https://huggingface.co/unsloth/gemma-4-E4B-it-qat-GGUF)
(`gemma-4-E4B-it-qat-UD-Q4_K_XL.gguf`, ~4.22 GB) via `llama-server` and exposes
an **OpenAI-compatible HTTP API** that other machines on your LAN can call.

It runs with **MTP** (multi-token prediction self-speculative decoding) and a
single-stream, low-RAM configuration — see
[Performance / long context](#performance--long-context).

- **GPU**: NVIDIA RTX 5060 Ti 16 GB (Blackwell, sm_120), all layers on the GPU.
- **Server**: prebuilt llama.cpp CUDA **13.3** binaries (release `b9811`, supports MTP).
- **Access**: LAN, or the whole internet via the [ngrok tunnel](#remote-access-over-the-internet-ngrok). Auth is opt-in.

> **Hardware note (important).** Blackwell / RTX 50-series GPUs **require CUDA
> 12.8+**, so `1-setup.ps1` pulls the **cuda-13.3** build (the 12.4 build crashes
> with "no kernel image" on these cards). And because Blackwell runs **MTP and
> flash-attention together** (Turing could not), this setup enables
> **flash-attention on**, a **q8_0** KV cache, and the **full 128k** context — all
> at once. Running on an older Turing card instead? See
> [Older / smaller GPUs](#older--smaller-gpus).

---

## Quick start

Run these from a PowerShell prompt **in this folder** (`D:\Hosting llm`):

```powershell
# 1. Download llama.cpp (CUDA binaries + CUDA runtime DLLs)
powershell -ExecutionPolicy Bypass -File .\1-setup.ps1

# 2. Download the model + MTP drafter (~4.28 GB total) into .\models\
powershell -ExecutionPolicy Bypass -File .\2-download-model.ps1

# 3. Start the API server (listens on :8080; open access by default)
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
| `$GpuLayers`      | `99`       | GPU layers (all). Comfortable on 16 GB even at full context — lower (~30) only if you OOM. |
| `$Context`        | `131072`   | Full 128k. With flash-attention on the buffers stay small, so it fits in 16 GB. Lower on a smaller card. |
| `$CacheTypeK/V`   | `q8_0`     | Quantized KV (~half the VRAM); requires `-fa on`. Use `f16` for max quality — 16 GB has room. |
| `$CtxCheckpoints` | `2`        | Max context checkpoints per slot (llama.cpp default ~32). Lower = less RAM (less prompt-cache reuse). |
| `$Thinking`       | `$true`    | `$true` = model reasons first; `$false` = direct answers. |

The API key lives in `api-key.txt`. Delete it to rotate (a new one is generated
on next start).

---

## Performance / long context

`3-start-server.ps1` is tuned for the RTX 5060 Ti (Blackwell) with
flash-attention **on** — which lets MTP, KV compression, and the full 128k
context all run together:

| Goal | Flags | Effect |
|------|-------|--------|
| **MTP generation** | `-md models\mtp-gemma-4-E4B-it.gguf --spec-type draft-mtp --spec-draft-n-max 4 --spec-draft-ngl 99` | MTP self-speculative decoding. The drafter (~60 MB) is the model's own MTP head; loads/stops with the server. On an FA-capable GPU this gives the published ~1.4–2.2× speedup. |
| **Flash-attention** | `-fa on` | Smaller attention buffers (more context per GB) and faster decode. Blackwell runs it together with MTP. |
| **KV compression** | `-ctk q8_0 -ctv q8_0` | ~Half the KV-cache VRAM at negligible quality cost. Requires `-fa on`; switch to `f16` for max quality. |
| **Full context** | `-c 131072` | The model's full 128k window; fits comfortably in 16 GB with the above. |
| **Single stream** | `-np 1` | One slot → lowest latency. With 16 GB you can raise this for concurrent requests. |

### Older / smaller GPUs

The original tuning targeted a **GTX 1660 SUPER (Turing, 6 GB)**, where MTP +
flash-attention **abort with a fatal `fattn.cu` error** — so FA had to be off,
which in turn forced `f16` KV (no compression) and a ~64k context ceiling. To run
on a Turing card:

- **Windows** — in `1-setup.ps1` set `$CudaVer = '12.4'` (only if your driver
  predates CUDA 13); in `3-start-server.ps1` set `-fa off`, `$CacheTypeK/V = 'f16'`,
  and lower `$Context` (~32k–64k).
- **Linux** — `FA=off KV=f16 CTX=32000 bash ./3-start-server.sh`.

On Turing, MTP can even be slightly *slower* than plain FA decoding (losing FA
costs more than MTP gains); the published speedups assume an Ampere-or-newer GPU.

### Tuning order when something doesn't fit
1. **CUDA / VRAM OOM** → lower `$Context` (e.g. `131072 → 65536`), then
   `$GpuLayers` (e.g. `99 → 30`).
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

- **CUDA out of memory (VRAM)** — lower `$Context` (e.g. `131072 → 65536`), then
  `$GpuLayers` (e.g. `99 → 30`). See [Performance / long context](#performance--long-context).
- **`no kernel image is available` / instant crash on a 50-series card** — you're
  on the CUDA 12.4 build. Blackwell needs 12.8+: keep `$CudaVer = '13.3'` in
  `1-setup.ps1` (the default) and update your NVIDIA driver to a CUDA-13-capable one.
- **`fattn.cu` fatal error on start** — MTP + flash-attention on a **Turing** GPU.
  On Turing set `-fa off` and `$CacheTypeK/V = 'f16'` (see
  [Older / smaller GPUs](#older--smaller-gpus)). Not applicable to Blackwell.
- **System RAM too high** — lower `$Context` or set `$CtxCheckpoints` to `1`.
- **CUDA DLL fails to load / no GPU used** — update your NVIDIA driver (download
  from nvidia.com). For an older GPU on an old driver, set `$CudaVer = '12.4'` in
  `1-setup.ps1` and re-run setup.
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
