<#
  3-start-server.ps1
  Launches llama-server with the Gemma 4 E4B model, bound to all interfaces so
  the OpenAI-compatible API is reachable from other machines on the LAN.

  Endpoints once running:
    http://<this-pc-ip>:8080/                     browser chat UI
    http://<this-pc-ip>:8080/health               health check
    http://<this-pc-ip>:8080/v1/chat/completions  OpenAI-compatible chat
    http://<this-pc-ip>:8080/v1/completions        OpenAI-compatible completion

  Every request must send:  Authorization: Bearer <api-key>

  Run:  powershell -ExecutionPolicy Bypass -File .\3-start-server.ps1
#>

$ErrorActionPreference = 'Stop'

# --- tunables ---------------------------------------------------------------
$Port        = 8080
$BindHost    = '0.0.0.0'   # 0.0.0.0 = reachable from the LAN; 127.0.0.1 = local only
$GpuLayers   = 99          # offload all layers to GPU. At $Context ≈ 64k this sits near the
                           # 6 GB VRAM ceiling WITH MTP -- lower (e.g. ~30) if you hit OOM.
$Context     = 32000      # 64K. MTP forces flash-attention OFF on this GPU (Turing
                           # limitation in this build), which is VRAM-heavier, so ~64k is the
                           # practical ceiling. (Drop MTP and you could run the full 131072 --
                           # see the MTP note in README.md.)
$CacheTypeK  = 'f16'       # MUST stay f16 while MTP is on: KV quantization (q8_0/q4_0)
$CacheTypeV  = 'f16'       # requires flash-attention, which MTP can't use here. See README.
$CtxCheckpoints = 2        # max context checkpoints per slot (default ~32). Lower = less RAM
                           # (less prompt-cache reuse).
$Alias       = 'gemma-4-E4B-it'
$Thinking    = $true       # $true = model reasons before answering (reasoning_content);
                           # $false = direct answers only
$Logging     = $true       # $true = log every model call (input/output/settings)
                           # to .\logs\ via a proxy; $false = no logging.
$RequireApiKey = $false    # $true = clients must send 'Authorization: Bearer <key>';
                           # $false = OPEN access, no key required (anyone who can reach
                           # the host:port can call it). Only safe on a trusted network.
$BackendPort = 8081        # internal llama-server port when $Logging is on

$Root        = $PSScriptRoot
$ServerExe   = Join-Path $Root 'llama.cpp\llama-server.exe'
$Model       = Join-Path $Root 'models\gemma-4-E4B-it-qat-UD-Q4_K_XL.gguf'
$MtpDraft    = Join-Path $Root 'models\mtp-gemma-4-E4B-it.gguf'   # MTP speculative drafter
$KeyFile     = Join-Path $Root 'api-key.txt'
$ProxyScript = Join-Path $Root 'proxy-logger.py'
$LogDir      = Join-Path $Root 'logs'

# --- sanity checks ----------------------------------------------------------
if (-not (Test-Path $ServerExe)) { throw "Missing $ServerExe. Run .\1-setup.ps1 first." }
if (-not (Test-Path $Model))     { throw "Missing $Model. Run .\2-download-model.ps1 first." }
if (-not (Test-Path $MtpDraft))  { throw "Missing $MtpDraft (MTP drafter). Run .\2-download-model.ps1 first." }

# --- api key: load from api-key.txt, generate one on first run --------------
# Only used when $RequireApiKey is $true. When $false the endpoint is open.
if ($RequireApiKey) {
    if (Test-Path $KeyFile) {
        $ApiKey = (Get-Content $KeyFile -Raw).Trim()
    } else {
        $ApiKey = [Guid]::NewGuid().ToString('N') + [Guid]::NewGuid().ToString('N')
        Set-Content -Path $KeyFile -Value $ApiKey -NoNewline -Encoding ascii
        Write-Host "[key] generated new API key -> $KeyFile"
    }
} else {
    $ApiKey = ''
}

# --- show how clients should connect ----------------------------------------
$lanIp = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
          Where-Object {
              $_.IPAddress -notlike '127.*' -and
              $_.IPAddress -notlike '169.254.*' -and
              # skip virtual adapters (WSL / Hyper-V) so we report the real LAN IP
              $_.InterfaceAlias -notmatch 'vEthernet|WSL|Loopback|Default Switch|VirtualBox|VMware'
          } |
          Select-Object -First 1 -ExpandProperty IPAddress)
if (-not $lanIp) { $lanIp = '<this-pc-ip>' }

Write-Host ""
Write-Host "  Starting llama-server" -ForegroundColor Cyan
Write-Host "  ---------------------------------------------------------------"
Write-Host "  Local  : http://localhost:$Port"
Write-Host "  LAN    : http://${lanIp}:$Port"
Write-Host "  API    : http://${lanIp}:$Port/v1/chat/completions"
Write-Host "  Model  : $Alias"
Write-Host "  Key    : $(if ($RequireApiKey) { $ApiKey } else { '(none - OPEN access, no key required)' })"
Write-Host "  ---------------------------------------------------------------"
Write-Host "  (LAN callers also need the firewall rule -- see README.md)"
Write-Host ""

# --- stop any previous instance first (avoid duplicate/port-conflicting procs) ---
Get-Process llama-server -ErrorAction SilentlyContinue | ForEach-Object {
    Write-Host "  (stopping old llama-server pid $($_.Id))"
    Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
}
Get-CimInstance Win32_Process -Filter "Name='python.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*proxy-logger.py*' } |
    ForEach-Object {
        Write-Host "  (stopping old proxy pid $($_.ProcessId))"
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }
Start-Sleep -Seconds 1

# When logging is on, llama-server listens only on localhost:$BackendPort and the
# proxy faces clients on $BindHost:$Port. Otherwise llama-server faces clients.
if ($Logging) {
    $serverHost = '127.0.0.1'
    $serverPort = $BackendPort
} else {
    $serverHost = $BindHost
    $serverPort = $Port
}

# --- build llama-server argument list ---------------------------------------
$serverArgs = @(
    '-m', $Model,
    '--host', $serverHost, '--port', $serverPort,
    '-ngl', $GpuLayers,
    '-c', $Context,
    '-fa', 'off',                               # MTP crashes the flash-attn CUDA kernel on this
                                                # GPU (Turing) -> FA must be OFF when MTP is on
    '-ctk', $CacheTypeK, '-ctv', $CacheTypeV,   # f16 KV (quant needs FA, unavailable with MTP)
    '-np', '1',                                 # single server slot -> one KV cache -> less RAM
    '-ctxcp', $CtxCheckpoints,                  # fewer context checkpoints -> less RAM
    '-md', $MtpDraft,                           # --- MTP self-speculative decoding ---
    '--spec-type', 'draft-mtp',                 # use the model's MTP head as the drafter
    '--spec-draft-n-max', '4',                  # draft up to 4 tokens per step
    '--spec-draft-ngl', '99',                   # keep the tiny drafter on the GPU
    '--jinja',                 # use the model's built-in Gemma chat template
    '--alias', $Alias
)

# Only require an API key when asked. With $RequireApiKey = $false, no --api-key
# is passed, so llama-server accepts requests without any Authorization header.
if ($RequireApiKey) {
    $serverArgs += @('--api-key', $ApiKey)
}

if ($Thinking) {
    # Turn on reasoning. '--reasoning on' makes the Gemma 4 template emit
    # thinking tags; the server extracts them into message.reasoning_content
    # (deepseek format). -1 budget = unrestricted thinking length.
    $serverArgs += @(
        '--reasoning', 'on',
        '--reasoning-format', 'deepseek',
        '--reasoning-budget', '-1'
    )
    Write-Host "  Thinking: ENABLED (responses include 'reasoning_content')"
} else {
    # '--reasoning off' suppresses thinking for direct, faster answers.
    $serverArgs += @('--reasoning', 'off')
    Write-Host "  Thinking: disabled"
}

if ($Logging) {
    Write-Host "  Logging : ENABLED -> logs\model-calls.log (+ .jsonl)"
} else {
    Write-Host "  Logging : disabled"
}
Write-Host ""

# --- launch -----------------------------------------------------------------
if (-not $Logging) {
    # Simple path: just run llama-server in the foreground.
    & $ServerExe @serverArgs
    return
}

# Logging path: start llama-server in the background, wait until it's ready,
# then run the proxy in the foreground. Ctrl+C stops the proxy; the finally
# block then stops llama-server so nothing is left running.
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$serverLog = Join-Path $LogDir 'llama-server.log'

# Start-Process -ArgumentList does NOT quote array elements, so any value with a
# space (e.g. the "D:\Hosting llm\..." model path) would be split into separate
# args. Quote every element that contains whitespace.
$quotedArgs = $serverArgs | ForEach-Object {
    if ("$_" -match '\s') { '"' + $_ + '"' } else { "$_" }
}

$srv = Start-Process -FilePath $ServerExe -ArgumentList $quotedArgs `
        -RedirectStandardOutput $serverLog -RedirectStandardError "$serverLog.err" `
        -NoNewWindow -PassThru

try {
    Write-Host "  Waiting for llama-server (loading model into VRAM)..."
    $ready = $false
    for ($i = 0; $i -lt 120; $i++) {
        if ($srv.HasExited) { throw "llama-server exited early -- see $serverLog" }
        try {
            $h = Invoke-RestMethod -Uri "http://127.0.0.1:$BackendPort/health" `
                    -Headers @{ Authorization = "Bearer $ApiKey" } -TimeoutSec 2 -ErrorAction Stop
            if ($h.status -eq 'ok') { $ready = $true; break }
        } catch { }
        Start-Sleep -Seconds 2
    }
    if (-not $ready) { throw "llama-server did not become ready in time." }

    Write-Host "  llama-server ready. Starting logging proxy on ${BindHost}:$Port" -ForegroundColor Green
    Write-Host ""

    & python $ProxyScript `
        --listen-host $BindHost --listen-port $Port `
        --upstream-host '127.0.0.1' --upstream-port $BackendPort `
        --log-dir $LogDir
}
finally {
    Write-Host ""
    Write-Host "  Stopping llama-server (pid $($srv.Id))..."
    if (-not $srv.HasExited) { Stop-Process -Id $srv.Id -Force -ErrorAction SilentlyContinue }
}
