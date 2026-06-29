<#
  4-start-tunnel.ps1
  Exposes the locally running llama-server API to the public internet through an
  ngrok tunnel, so you can call it remotely (from outside your LAN) over HTTPS.

  Flow:
    1. Start the server in one window:   .\3-start-server.ps1   (listens on :8080)
    2. Start the tunnel in another:      .\4-start-tunnel.ps1 -AuthToken <token>

  The authtoken is resolved in this order (first one wins):
    -AuthToken <token>  parameter
    $env:NGROK_AUTHTOKEN  environment variable
    ngrok-authtoken.txt   file in this folder
  On first use the token is saved to ngrok-authtoken.txt so later runs need no args.
  Get a free token at: https://dashboard.ngrok.com/get-started/your-authtoken

  ngrok itself is downloaded into .\ngrok\ on first run (no install needed).

  Once up, the script prints your public https URL, e.g.
    https://abcd-1234.ngrok-free.app
  Callers use that base URL exactly like the LAN one:
    <public-url>/v1/chat/completions

  Run:  powershell -ExecutionPolicy Bypass -File .\4-start-tunnel.ps1 -AuthToken <token>
#>

param(
    [string]$AuthToken,                 # ngrok authtoken (see resolution order above)
    [int]   $Port      = 8080,          # local port the server listens on (matches $Port in 3-start-server.ps1)
    [string]$BasicAuth,                 # optional "user:pass" -> ngrok adds HTTP basic auth in front of the API
    [string]$Domain                    # optional reserved/static ngrok domain (paid feature), e.g. myllm.ngrok.app
)

$ErrorActionPreference = 'Stop'
$ProgressPreference     = 'SilentlyContinue'   # speeds up Invoke-WebRequest

# --- paths ------------------------------------------------------------------
$Root        = $PSScriptRoot
$NgrokDir    = Join-Path $Root 'ngrok'
$NgrokExe    = Join-Path $NgrokDir 'ngrok.exe'
$TokenFile   = Join-Path $Root 'ngrok-authtoken.txt'
$LogDir      = Join-Path $Root 'logs'
$NgrokLog    = Join-Path $LogDir 'ngrok.log'
# Official stable ngrok v3 build for Windows x64 (zip contains ngrok.exe at root).
$NgrokZipUrl = 'https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-windows-amd64.zip'
$ApiUrl      = 'http://127.0.0.1:4040/api/tunnels'   # ngrok's local agent API / inspector

# --- resolve the authtoken --------------------------------------------------
if (-not $AuthToken) { $AuthToken = $env:NGROK_AUTHTOKEN }
if (-not $AuthToken -and (Test-Path $TokenFile)) {
    $AuthToken = (Get-Content $TokenFile -Raw).Trim()
}
if (-not $AuthToken) {
    throw @"
No ngrok authtoken found. Provide one of:
  -AuthToken <token>                 (command-line argument)
  `$env:NGROK_AUTHTOKEN = '<token>'  (environment variable)
  ngrok-authtoken.txt                (a file in this folder containing the token)
Get a free token at https://dashboard.ngrok.com/get-started/your-authtoken
"@
}

# Persist the token so future runs need no argument (only if not already saved).
if (-not (Test-Path $TokenFile)) {
    Set-Content -Path $TokenFile -Value $AuthToken -NoNewline -Encoding ascii
    Write-Host "[token] saved -> ngrok-authtoken.txt (git-ignored)"
}

# --- download ngrok on first run --------------------------------------------
if (-not (Test-Path $NgrokExe)) {
    Write-Host "[ngrok] not found - downloading..." -ForegroundColor Cyan
    New-Item -ItemType Directory -Force -Path $NgrokDir | Out-Null
    $zip = Join-Path $NgrokDir 'ngrok.zip'
    Invoke-WebRequest -Uri $NgrokZipUrl -OutFile $zip
    Expand-Archive -Path $zip -DestinationPath $NgrokDir -Force
    Remove-Item $zip -Force
    if (-not (Test-Path $NgrokExe)) { throw "ngrok.exe not found after extraction in $NgrokDir" }
    Write-Host "[ngrok] installed -> $NgrokExe"
}

# --- register the authtoken (writes ngrok's own config; idempotent) ---------
& $NgrokExe config add-authtoken $AuthToken | Out-Null

# --- check the local server is actually up ----------------------------------
# A tunnel to a dead port just returns 502s, so warn early if nothing answers.
$serverUp = $false
try {
    $h = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/health" -TimeoutSec 3 -ErrorAction Stop
    if ($h.status -eq 'ok') { $serverUp = $true }
} catch { }
if (-not $serverUp) {
    Write-Host ""
    Write-Host "  WARNING: no healthy server answered on http://127.0.0.1:$Port" -ForegroundColor Yellow
    Write-Host "           Start it first with .\3-start-server.ps1 (the tunnel will still" -ForegroundColor Yellow
    Write-Host "           come up, but calls return 502 until the server is running)." -ForegroundColor Yellow
}

# --- security probe: is the API open (no key) right now? ---------------------
# ngrok puts this on the PUBLIC internet, so an open endpoint = anyone with the
# URL can use your GPU. Detect it and nudge toward auth.
$apiOpen = $false
try {
    Invoke-RestMethod -Uri "http://127.0.0.1:$Port/v1/models" -TimeoutSec 3 -ErrorAction Stop | Out-Null
    $apiOpen = $true   # answered 200 without an Authorization header
} catch {
    if ($_.Exception.Response.StatusCode.value__ -eq 401) { $apiOpen = $false }
}
if ($apiOpen -and -not $BasicAuth) {
    Write-Host ""
    Write-Host "  *** SECURITY WARNING ***" -ForegroundColor Red
    Write-Host "  The API currently accepts requests with NO API KEY, and ngrok will" -ForegroundColor Red
    Write-Host "  publish it to the whole internet. Protect it by either:" -ForegroundColor Red
    Write-Host "    - set `$RequireApiKey = `$true in 3-start-server.ps1 and restart, or" -ForegroundColor Red
    Write-Host "    - re-run this with  -BasicAuth 'user:pass'  (ngrok-level auth)." -ForegroundColor Red
}

# --- stop any previous ngrok ------------------------------------------------
Get-Process ngrok -ErrorAction SilentlyContinue | ForEach-Object {
    Write-Host "  (stopping old ngrok pid $($_.Id))"
    Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
}
Start-Sleep -Milliseconds 500

# --- build ngrok arg list ---------------------------------------------------
$ngrokArgs = @('http', "$Port", '--log=stdout', '--log-format=logfmt')
if ($BasicAuth) { $ngrokArgs += @('--basic-auth', $BasicAuth) }
if ($Domain)    { $ngrokArgs += @("--domain=$Domain") }

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

# --- launch ngrok in the background, then read its public URL ---------------
$ng = Start-Process -FilePath $NgrokExe -ArgumentList $ngrokArgs `
        -RedirectStandardOutput $NgrokLog -RedirectStandardError "$NgrokLog.err" `
        -NoNewWindow -PassThru

try {
    Write-Host ""
    Write-Host "  Connecting tunnel..." -ForegroundColor Cyan
    $publicUrl = $null
    for ($i = 0; $i -lt 30; $i++) {
        if ($ng.HasExited) { throw "ngrok exited early -- see $NgrokLog.err" }
        try {
            $t = Invoke-RestMethod -Uri $ApiUrl -TimeoutSec 2 -ErrorAction Stop
            $publicUrl = ($t.tunnels | Where-Object { $_.public_url -like 'https://*' } |
                          Select-Object -First 1 -ExpandProperty public_url)
            if ($publicUrl) { break }
        } catch { }
        Start-Sleep -Milliseconds 700
    }
    if (-not $publicUrl) { throw "Tunnel did not report a public URL in time -- see $NgrokLog" }

    # --- banner -------------------------------------------------------------
    Write-Host ""
    Write-Host "  Tunnel is LIVE" -ForegroundColor Green
    Write-Host "  ---------------------------------------------------------------"
    Write-Host "  Public  : $publicUrl"
    Write-Host "  API     : $publicUrl/v1/chat/completions"
    Write-Host "  Health  : $publicUrl/health"
    Write-Host "  Inspect : http://127.0.0.1:4040   (ngrok request inspector)"
    if ($BasicAuth) { Write-Host "  Auth    : HTTP basic ($($BasicAuth.Split(':')[0]):********)" }
    Write-Host "  ---------------------------------------------------------------"
    Write-Host ""
    Write-Host "  Call it remotely:" -ForegroundColor Cyan
    Write-Host "    curl $publicUrl/v1/chat/completions \"
    Write-Host "      -H `"Authorization: Bearer <api-key>`" \"
    Write-Host "      -H `"Content-Type: application/json`" \"
    Write-Host "      -d '{\""model\"":\""gemma-4-E4B-it\"",\""messages\"":[{\""role\"":\""user\"",\""content\"":\""Hello!\""}]}'"
    Write-Host ""
    Write-Host "    .\test-client.ps1 -ServerUrl $publicUrl"
    Write-Host ""
    Write-Host "  Leave this window open. Press Ctrl+C to close the tunnel." -ForegroundColor DarkGray
    Write-Host ""

    Wait-Process -Id $ng.Id
}
finally {
    Write-Host ""
    Write-Host "  Closing tunnel (ngrok pid $($ng.Id))..."
    if (-not $ng.HasExited) { Stop-Process -Id $ng.Id -Force -ErrorAction SilentlyContinue }
}
