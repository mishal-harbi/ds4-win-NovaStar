$ErrorActionPreference = "Stop"

function Assert-Contains {
    param(
        [string]$Path,
        [string]$Needle,
        [string]$Message
    )
    $text = Get-Content -Raw -LiteralPath $Path
    if (-not $text.Contains($Needle)) {
        throw $Message
    }
}

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )
    if (-not $Condition) {
        throw $Message
    }
}

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")

Assert-Contains (Join-Path $repoRoot "ds4.h") "ram_streaming_cache_experts" "engine options must expose RAM expert cache count"
Assert-Contains (Join-Path $repoRoot "ds4_cli.c") "--ram-streaming-cache-experts" "ds4 CLI must parse RAM expert cache flag"
Assert-Contains (Join-Path $repoRoot "ds4_bench.c") "--ram-streaming-cache-experts" "ds4-bench must parse RAM expert cache flag"
Assert-Contains (Join-Path $repoRoot "ds4_help.c") "--ram-streaming-cache-experts N|NGB" "help output must document RAM expert cache flag"
Assert-Contains (Join-Path $repoRoot "ds4_gpu.h") "ds4_gpu_set_streaming_host_expert_cache_budget" "GPU API must expose host expert cache budget"
Assert-Contains (Join-Path $repoRoot "ds4_cuda.cu") "cuda_stream_host_expert_cache" "CUDA backend must implement a host expert cache"
Assert-Contains (Join-Path $repoRoot "ds4_cuda.cu") "DS4_CUDA_STREAMING_HOST_CACHE_VERBOSE" "CUDA backend must expose host cache verbose logging"

$scriptPath = Join-Path $repoRoot "windows_observable_benchmark.ps1"
$outDir = Join-Path $env:TEMP ("ds4 ram expert cache test " + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $outDir | Out-Null

try {
    powershell -ExecutionPolicy Bypass -File $scriptPath `
        -Model ".\gguf\model.gguf" `
        -PromptFile ".\prompt.txt" `
        -CtxStart 500000 `
        -CtxMax 500000 `
        -CtxAlloc 500017 `
        -StepIncr 2048 `
        -GenTokens 16 `
        -PrefillChunk 512 `
        -SsdStreaming `
        -RamStreamingCacheExperts "80GB" `
        -RamStreamingCachePreload `
        -OutDir $outDir `
        -Label "ram-cache-dry-run" `
        -DryRun | Out-Null

    $runDir = Join-Path $outDir "ram-cache-dry-run"
    $command = Get-Content -Raw -LiteralPath (Join-Path $runDir "command.txt")
    $manifest = Get-Content -Raw -LiteralPath (Join-Path $runDir "manifest.json") | ConvertFrom-Json

    Assert-True ($command.Contains("--ram-streaming-cache-experts 80GB")) "observable command must include RAM cache budget"
    Assert-True ($command.Contains("--ram-streaming-cache-preload")) "observable command must include RAM cache preload"
    Assert-True ($manifest.ram_streaming_cache_experts -eq "80GB") "manifest must record RAM cache budget"
    Assert-True ($manifest.ram_streaming_cache_preload -eq $true) "manifest must record RAM cache preload"

    Write-Host "windows_ram_expert_cache_tests.ps1: PASS"
} finally {
    Remove-Item -LiteralPath $outDir -Recurse -Force -ErrorAction SilentlyContinue
}
