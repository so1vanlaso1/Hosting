<#
  1-setup.ps1
  Downloads the prebuilt llama.cpp Windows CUDA binaries + the matching CUDA
  runtime DLLs, and extracts both into .\llama.cpp\ so that llama-server.exe
  runs without a full CUDA Toolkit install.

  Target GPU: NVIDIA RTX 5060 Ti 16GB (Blackwell, sm_120) -> CUDA 13.3 build.
  Blackwell / RTX 50-series REQUIRE CUDA 12.8+, so the 13.3 build is mandatory
  (the 12.4 build will fail with "no kernel image" on these cards). The 13.3
  build still supports Turing/Ampere/Ada too -- only drop to $CudaVer = '12.4'
  for an older GPU whose driver predates CUDA 13.
  Run from this folder:  powershell -ExecutionPolicy Bypass -File .\1-setup.ps1
#>

$ErrorActionPreference = 'Stop'
$ProgressPreference     = 'SilentlyContinue'   # massively speeds up Invoke-WebRequest

# --- config -----------------------------------------------------------------
$Release   = 'b9811'
$CudaVer   = '13.3'   # 13.3 = REQUIRED for Blackwell / RTX 50-series (sm_120). Use '12.4'
                      # only on an older GPU whose driver predates CUDA 13.
$BaseUrl   = "https://github.com/ggml-org/llama.cpp/releases/download/$Release"
$Assets    = @(
    "llama-$Release-bin-win-cuda-$CudaVer-x64.zip",   # binaries (llama-server.exe, ggml-cuda DLLs)
    "cudart-llama-bin-win-cuda-$CudaVer-x64.zip"      # CUDA runtime DLLs (cudart, cublas)
)

$Root      = $PSScriptRoot
$DestDir   = Join-Path $Root 'llama.cpp'
$TmpDir    = Join-Path $Root '.dl'

# --- prep -------------------------------------------------------------------
New-Item -ItemType Directory -Force -Path $DestDir | Out-Null
New-Item -ItemType Directory -Force -Path $TmpDir  | Out-Null

foreach ($asset in $Assets) {
    $url = "$BaseUrl/$asset"
    $zip = Join-Path $TmpDir $asset

    if (Test-Path $zip) {
        Write-Host "[skip] already downloaded: $asset"
    } else {
        Write-Host "[down] $url"
        Invoke-WebRequest -Uri $url -OutFile $zip
    }

    Write-Host "[unzip] $asset -> llama.cpp\"
    # Both zips extract their contents flat; -Force overwrites so cudart DLLs
    # land beside llama-server.exe.
    Expand-Archive -Path $zip -DestinationPath $DestDir -Force
}

# --- locate llama-server.exe (some builds nest it in a subfolder) -----------
$serverExe = Get-ChildItem -Path $DestDir -Recurse -Filter 'llama-server.exe' |
             Select-Object -First 1

if (-not $serverExe) {
    throw "llama-server.exe not found under $DestDir after extraction."
}

# If it was nested, flatten everything up to $DestDir so all DLLs sit together.
if ($serverExe.DirectoryName -ne $DestDir) {
    Write-Host "[flatten] moving binaries from $($serverExe.DirectoryName) -> $DestDir"
    Get-ChildItem -Path $serverExe.DirectoryName -File |
        Move-Item -Destination $DestDir -Force
}

Remove-Item -Recurse -Force $TmpDir

Write-Host ""
Write-Host "[ok] llama.cpp ready at: $DestDir"
Write-Host "     server: $(Join-Path $DestDir 'llama-server.exe')"
Write-Host ""
Write-Host "Next: run .\2-download-model.ps1"
