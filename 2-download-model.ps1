<#
  2-download-model.ps1
  Downloads the QAT 4-bit model + its MTP drafter from
  unsloth/gemma-4-E4B-it-qat-GGUF into .\models\ using the HuggingFace `hf` CLI
  (falls back to curl). Two files (~4.28 GB total):
    - gemma-4-E4B-it-qat-UD-Q4_K_XL.gguf   (~4.22 GB)  main model
    - mtp-gemma-4-E4B-it.gguf              (~60 MB)    MTP drafter (Q4_0)

  Run:  powershell -ExecutionPolicy Bypass -File .\2-download-model.ps1
#>

$ErrorActionPreference = 'Stop'

$Repo      = 'unsloth/gemma-4-E4B-it-qat-GGUF'
$Files     = @(
    'gemma-4-E4B-it-qat-UD-Q4_K_XL.gguf',   # main QAT 4-bit model
    'mtp-gemma-4-E4B-it.gguf'               # MTP drafter for speculative decoding
)
$ModelsDir = Join-Path $PSScriptRoot 'models'

New-Item -ItemType Directory -Force -Path $ModelsDir | Out-Null

# hf CLI is preferred (pulls only the single file); curl is the fallback.
$hf = Get-Command hf -ErrorAction SilentlyContinue

function Get-ModelFile {
    param([string]$File)

    $target = Join-Path $ModelsDir $File
    if (Test-Path $target) {
        $mb = [math]::Round((Get-Item $target).Length / 1MB)
        Write-Host "[skip] already present: $File ($mb MB)"
        return
    }

    if ($hf) {
        Write-Host "[down] hf download $Repo $File -> models\"
        & hf download $Repo $File --local-dir $ModelsDir
    } else {
        Write-Host "[warn] 'hf' CLI not found; falling back to curl"
        $url = "https://huggingface.co/$Repo/resolve/main/$File"
        Write-Host "[down] $url"
        & curl.exe -L --fail -o $target $url
    }

    if (-not (Test-Path $target)) {
        throw "Download finished but file not found at $target"
    }
    $mb = [math]::Round((Get-Item $target).Length / 1MB)
    Write-Host "[ok]   $File ($mb MB)"
}

foreach ($f in $Files) { Get-ModelFile -File $f }

Write-Host ""
Write-Host "[ok] all files ready in $ModelsDir"
Write-Host "Next: run .\3-start-server.ps1"
