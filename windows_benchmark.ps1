param(
    [string]$Model = ".\gguf\DeepSeek-V4-Flash-IQ2XXS-w2Q2K-AProjQ8-SExpQ8-OutQ8-chat-v2-imatrix.gguf",
    [string]$PromptFile = ".\speed-bench\promessi_sposi.txt",
    [int]$CtxStart = 2048,
    [int]$CtxMax = 65536,
    [int]$StepIncr = 2048,
    [int]$GenTokens = 128,
    [string]$OutDir = ".\benchmark-results",
    [string]$Name = "windows_rtx_pro_6000_blackwell_cuda_full"
)

$ErrorActionPreference = "Stop"

if (!(Test-Path ".\ds4-bench.exe")) {
    throw "ds4-bench.exe was not found. Build it first with .\windows_build.ps1 -Target cuda."
}
if (!(Test-Path $Model)) {
    throw "Model file was not found: $Model"
}
if (!(Test-Path $PromptFile)) {
    throw "Prompt file was not found: $PromptFile"
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$csvPath = Join-Path $OutDir "$Name`_$stamp.csv"
$metaPath = Join-Path $OutDir "$Name`_$stamp.meta.txt"
$reportPath = Join-Path $OutDir "$Name`_$stamp.report.md"

$gpuBefore = (& nvidia-smi --query-gpu=name,driver_version,memory.total,memory.used,memory.free --format=csv,noheader,nounits) -join "`n"
$modelInfo = (& ".\ds4.exe" --cuda --inspect -m $Model) -join "`n"

$metadata = @(
    "name=$Name",
    "date=$(Get-Date -Format o)",
    "model=$Model",
    "prompt_file=$PromptFile",
    "ctx_start=$CtxStart",
    "ctx_max=$CtxMax",
    "step_incr=$StepIncr",
    "gen_tokens=$GenTokens",
    "mode=full_cuda_residency",
    "",
    "[gpu_before]",
    $gpuBefore,
    "",
    "[model_inspect]",
    $modelInfo
)
$metadata | Set-Content -LiteralPath $metaPath -Encoding ASCII

& ".\ds4-bench.exe" `
    --cuda `
    -m $Model `
    --prompt-file $PromptFile `
    --ctx-start $CtxStart `
    --ctx-max $CtxMax `
    --step-incr $StepIncr `
    --gen-tokens $GenTokens `
    --csv $csvPath
if ($LASTEXITCODE -ne 0) {
    throw "ds4-bench.exe failed with exit code $LASTEXITCODE"
}

$gpuAfter = (& nvidia-smi --query-gpu=name,driver_version,memory.total,memory.used,memory.free --format=csv,noheader,nounits) -join "`n"
Add-Content -LiteralPath $metaPath -Encoding ASCII -Value @("", "[gpu_after]", $gpuAfter)

$current = Import-Csv -LiteralPath $csvPath
$comparisonFiles = Get-ChildItem -LiteralPath ".\speed-bench" -Filter "*.csv" -File |
    Where-Object { $_.Name -ne ".gitignore" }

$rows = @()
foreach ($file in $comparisonFiles) {
    $data = Import-Csv -LiteralPath $file.FullName
    if (!$data) { continue }
    $avgPrefill = ($data | Measure-Object -Property prefill_tps -Average).Average
    $avgGen = ($data | Measure-Object -Property gen_tps -Average).Average
    $row32768 = $data | Where-Object { [int]$_.ctx_tokens -eq 32768 } | Select-Object -First 1
    $last = $data | Select-Object -Last 1
    $rows += [pscustomobject]@{
        name = [IO.Path]::GetFileNameWithoutExtension($file.Name)
        rows = $data.Count
        avg_prefill_tps = [math]::Round($avgPrefill, 2)
        avg_gen_tps = [math]::Round($avgGen, 2)
        gen_tps_32768 = if ($row32768) { [math]::Round([double]$row32768.gen_tps, 2) } else { $null }
        max_ctx = [int]$last.ctx_tokens
        gen_tps_max_ctx = [math]::Round([double]$last.gen_tps, 2)
    }
}

$avgCurrentPrefill = ($current | Measure-Object -Property prefill_tps -Average).Average
$avgCurrentGen = ($current | Measure-Object -Property gen_tps -Average).Average
$current32768 = $current | Where-Object { [int]$_.ctx_tokens -eq 32768 } | Select-Object -First 1
$currentLast = $current | Select-Object -Last 1
$rows += [pscustomobject]@{
    name = $Name
    rows = $current.Count
    avg_prefill_tps = [math]::Round($avgCurrentPrefill, 2)
    avg_gen_tps = [math]::Round($avgCurrentGen, 2)
    gen_tps_32768 = if ($current32768) { [math]::Round([double]$current32768.gen_tps, 2) } else { $null }
    max_ctx = [int]$currentLast.ctx_tokens
    gen_tps_max_ctx = [math]::Round([double]$currentLast.gen_tps, 2)
}

$ranked = $rows | Sort-Object -Property avg_gen_tps -Descending
$report = @()
$report += "# DS4 Windows CUDA Full-Residency Benchmark"
$report += ""
$report += "- CSV: ``$csvPath``"
$report += "- Metadata: ``$metaPath``"
$report += "- Benchmark: repo ``speed-bench`` suite using ``promessi_sposi.txt``"
$report += "- Mode: full CUDA residency, no SSD streaming"
$report += "- Context sweep: $CtxStart..$CtxMax, step $StepIncr"
$report += "- Generation probe: $GenTokens greedy tokens per frontier"
$report += ""
$report += "## Comparison"
$report += ""
$report += "| Entry | Rows | Avg prefill t/s | Avg gen t/s | Gen t/s @ 32768 | Max ctx | Gen t/s @ max ctx |"
$report += "|---|---:|---:|---:|---:|---:|---:|"
foreach ($row in $ranked) {
    $g32768 = if ($null -ne $row.gen_tps_32768) { $row.gen_tps_32768 } else { "" }
    $report += "| $($row.name) | $($row.rows) | $($row.avg_prefill_tps) | $($row.avg_gen_tps) | $g32768 | $($row.max_ctx) | $($row.gen_tps_max_ctx) |"
}
$report += ""
$report += "## GPU Snapshot"
$report += ""
$report += "Before: ``$gpuBefore``"
$report += ""
$report += "After: ``$gpuAfter``"

$report | Set-Content -LiteralPath $reportPath -Encoding ASCII

Write-Host "CSV: $csvPath"
Write-Host "Metadata: $metaPath"
Write-Host "Report: $reportPath"
