<#
  test-client.ps1
  Smoke test against the running llama-server. Hits /health then sends a chat
  completion. Reads the API key from api-key.txt.

  Usage:
    .\test-client.ps1                       # tests http://localhost:8080
    .\test-client.ps1 -ServerUrl http://192.168.1.50:8080
#>

param(
    [string]$ServerUrl = 'http://localhost:8080',
    [string]$Prompt    = 'In one sentence, what is llama.cpp?'
)

$ErrorActionPreference = 'Stop'

$KeyFile = Join-Path $PSScriptRoot 'api-key.txt'
if (-not (Test-Path $KeyFile)) { throw "api-key.txt not found. Start the server once (3-start-server.ps1) to generate it." }
$ApiKey  = (Get-Content $KeyFile -Raw).Trim()

$headers = @{ Authorization = "Bearer $ApiKey" }

Write-Host "[health] GET $ServerUrl/health"
$health = Invoke-RestMethod -Uri "$ServerUrl/health" -Headers $headers
Write-Host "         -> $($health | ConvertTo-Json -Compress)"

$body = @{
    model    = 'gemma-4-E4B-it'
    messages = @(
        @{ role = 'user'; content = $Prompt }
    )
    stream      = $false
    max_tokens  = 256
} | ConvertTo-Json -Depth 5

Write-Host "[chat]   POST $ServerUrl/v1/chat/completions"
Write-Host "         prompt: $Prompt"
$resp = Invoke-RestMethod -Uri "$ServerUrl/v1/chat/completions" `
            -Method Post -Headers $headers `
            -ContentType 'application/json' -Body $body

Write-Host ""
Write-Host "Assistant:" -ForegroundColor Green
Write-Host $resp.choices[0].message.content
