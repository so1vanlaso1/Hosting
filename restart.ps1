<#
  restart.ps1 - stops then starts the LLM.
  Run:  powershell -ExecutionPolicy Bypass -File .\restart.ps1
#>

& (Join-Path $PSScriptRoot 'stop.ps1')
Start-Sleep -Seconds 2
& (Join-Path $PSScriptRoot '3-start-server.ps1')
