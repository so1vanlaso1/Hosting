<#
  stop.ps1 - stops the LLM (llama-server) and the logging proxy.
  Run:  powershell -ExecutionPolicy Bypass -File .\stop.ps1
#>

$stopped = $false

# 1) llama-server.exe
Get-Process llama-server -ErrorAction SilentlyContinue | ForEach-Object {
    Write-Host "stopping llama-server (pid $($_.Id))"
    Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
    $stopped = $true
}

# 2) the logging proxy (python running proxy-logger.py)
Get-CimInstance Win32_Process -Filter "Name='python.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*proxy-logger.py*' } |
    ForEach-Object {
        Write-Host "stopping proxy-logger (pid $($_.ProcessId))"
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        $stopped = $true
    }

if (-not $stopped) { Write-Host "nothing was running" } else { Write-Host "stopped." }
