$ErrorActionPreference = "Stop"

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
$scriptPath = Join-Path $repoRoot "windows_observable_benchmark.ps1"

Assert-True (Test-Path -LiteralPath $scriptPath) "windows_observable_benchmark.ps1 must exist"

$outDir = Join-Path $env:TEMP ("ds4 observable test " + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $outDir | Out-Null

try {
    powershell -ExecutionPolicy Bypass -File $scriptPath `
        -Model ".\gguf\model.gguf" `
        -PromptFile ".\prompt.txt" `
        -CtxStart 262144 `
        -CtxMax 262144 `
        -CtxAlloc 262161 `
        -StepIncr 2048 `
        -GenTokens 16 `
        -PrefillChunk 512 `
        -SsdStreaming `
        -SsdStreamingCacheExperts "64GB" `
        -OutDir $outDir `
        -Label "test-run" `
        -DryRun | Out-Null

    $runDir = Join-Path $outDir "test-run"
    Assert-True (Test-Path -LiteralPath $runDir) "dry run must create the labeled run directory"

    $commandPath = Join-Path $runDir "command.txt"
    $manifestPath = Join-Path $runDir "manifest.json"
    Assert-True (Test-Path -LiteralPath $commandPath) "dry run must write command.txt"
    Assert-True (Test-Path -LiteralPath $manifestPath) "dry run must write manifest.json"

    $command = Get-Content -Raw -LiteralPath $commandPath
    Assert-True ($command.Contains("--ctx-start 262144")) "command must include ctx-start"
    Assert-True ($command.Contains("--ctx-max 262144")) "command must include ctx-max"
    Assert-True ($command.Contains("--ctx-alloc 262161")) "command must include ctx-alloc"
    Assert-True ($command.Contains("--prefill-chunk 512")) "command must include prefill chunk"
    Assert-True ($command.Contains("--ssd-streaming")) "command must include SSD streaming flag"
    Assert-True ($command.Contains("--ssd-streaming-cache-experts 64GB")) "command must include SSD cache budget"
    Assert-True ($command.Contains("--csv")) "command must include CSV output"

    $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
    Assert-True ($manifest.dry_run -eq $true) "manifest must record dry_run=true"
    Assert-True ($manifest.status -eq "dry-run") "manifest must record dry-run status"
    Assert-True ($manifest.ctx_start -eq 262144) "manifest must record ctx_start"
    Assert-True ($manifest.ctx_max -eq 262144) "manifest must record ctx_max"
    Assert-True ($manifest.prefill_chunk -eq 512) "manifest must record prefill_chunk"
    Assert-True ($manifest.ssd_streaming -eq $true) "manifest must record ssd_streaming"
    Assert-True ($manifest.ssd_streaming_cache_experts -eq "64GB") "manifest must record SSD cache budget"
    Assert-True (-not [string]::IsNullOrWhiteSpace($manifest.argument_line)) "manifest must record the Start-Process argument line"
    Assert-True ($manifest.argument_line.Contains('--csv')) "argument line must include CSV flag"
    Assert-True ($manifest.argument_line.Contains('"')) "argument line must quote paths that contain spaces"

    Write-Host "windows_observable_benchmark_tests.ps1: PASS"
} finally {
    Remove-Item -LiteralPath $outDir -Recurse -Force -ErrorAction SilentlyContinue
}
