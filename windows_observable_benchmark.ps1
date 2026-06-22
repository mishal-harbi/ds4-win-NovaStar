param(
    [string]$Model = ".\gguf\DeepSeek-V4-Flash-IQ2XXS-w2Q2K-AProjQ8-SExpQ8-OutQ8-chat-v2-imatrix.gguf",
    [string]$PromptFile = ".\speed-bench\promessi_sposi.txt",
    [int]$CtxStart = 2048,
    [int]$CtxMax = 65536,
    [int]$CtxAlloc = 0,
    [int]$StepIncr = 2048,
    [int]$GenTokens = 128,
    [int]$PrefillChunk = 0,
    [string]$OutDir = ".\benchmark-results\observable",
    [string]$Label = "",
    [switch]$SsdStreaming,
    [string]$SsdStreamingCacheExperts = "",
    [string]$RamStreamingCacheExperts = "",
    [switch]$RamStreamingCachePreload,
    [int]$MonitorIntervalSeconds = 30,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

function Quote-Arg {
    param([string]$Value)

    if ($Value -match '^[A-Za-z0-9_./:\\=-]+$') {
        return $Value
    }

    return '"' + ($Value -replace '"', '\"') + '"'
}

function Write-TextFile {
    param(
        [string]$Path,
        [string]$Value
    )

    $Value | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Get-RelevantEnvironment {
    $envRows = Get-ChildItem Env: |
        Where-Object {
            $_.Name -like 'DS4_*' -or
            $_.Name -like 'CUDA_*' -or
            $_.Name -eq 'NVIDIA_VISIBLE_DEVICES'
        } |
        Sort-Object Name

    $result = [ordered]@{}
    foreach ($row in $envRows) {
        $result[$row.Name] = $row.Value
    }
    return $result
}

function Try-Run {
    param(
        [string]$Command,
        [string[]]$Arguments,
        [string]$OutputPath
    )

    try {
        & $Command @Arguments | Out-File -LiteralPath $OutputPath -Encoding UTF8
    } catch {
        "failed: $($_.Exception.Message)" | Out-File -LiteralPath $OutputPath -Encoding UTF8
    }
}

function Append-ProcessSample {
    param(
        [System.Diagnostics.Process]$Process,
        [string]$Path
    )

    $timestamp = Get-Date -Format o
    try {
        $Process.Refresh()
        $line = "{0},{1},{2},{3},{4},{5},{6}" -f `
            $timestamp, `
            $Process.Id, `
            $Process.HasExited, `
            [int64]$Process.WorkingSet64, `
            [int64]$Process.PrivateMemorySize64, `
            [int64]$Process.VirtualMemorySize64, `
            $Process.TotalProcessorTime.TotalSeconds.ToString("F3")
        Add-Content -LiteralPath $Path -Value $line
    } catch {
        Add-Content -LiteralPath $Path -Value "$timestamp,$($Process.Id),sample_failed,$($_.Exception.Message)"
    }
}

function Append-GpuSample {
    param([string]$Path)

    $timestamp = Get-Date -Format o
    try {
        $rows = & nvidia-smi --query-gpu=timestamp,index,name,memory.total,memory.used,memory.free,utilization.gpu,power.draw --format=csv,noheader,nounits
        foreach ($row in $rows) {
            Add-Content -LiteralPath $Path -Value "$timestamp,$row"
        }
    } catch {
        Add-Content -LiteralPath $Path -Value "$timestamp,gpu_sample_failed,$($_.Exception.Message)"
    }
}

function Append-DiskSample {
    param([string]$Path)

    $timestamp = Get-Date -Format o
    try {
        $counters = Get-Counter '\PhysicalDisk(_Total)\Disk Read Bytes/sec','\PhysicalDisk(_Total)\Disk Write Bytes/sec'
        $read = $counters.CounterSamples | Where-Object { $_.Path -like '*disk read bytes/sec' } | Select-Object -First 1
        $write = $counters.CounterSamples | Where-Object { $_.Path -like '*disk write bytes/sec' } | Select-Object -First 1
        $readValue = if ($read) { [double]$read.CookedValue } else { 0.0 }
        $writeValue = if ($write) { [double]$write.CookedValue } else { 0.0 }
        Add-Content -LiteralPath $Path -Value ("{0},{1:F0},{2:F0}" -f $timestamp, $readValue, $writeValue)
    } catch {
        Add-Content -LiteralPath $Path -Value "$timestamp,disk_sample_failed,$($_.Exception.Message)"
    }
}

if ($MonitorIntervalSeconds -lt 1) {
    throw "MonitorIntervalSeconds must be at least 1"
}

$repoRoot = $PSScriptRoot
$exe = Join-Path $repoRoot "ds4-bench.exe"

if ([string]::IsNullOrWhiteSpace($Label)) {
    $Label = "observable_" + (Get-Date -Format "yyyyMMdd_HHmmss")
}

$runRoot = New-Item -ItemType Directory -Path $OutDir -Force
$runDir = Join-Path $runRoot.FullName $Label
if (Test-Path -LiteralPath $runDir) {
    throw "Run directory already exists: $runDir"
}
New-Item -ItemType Directory -Path $runDir | Out-Null

$csvPath = Join-Path $runDir "ds4_bench.csv"
$stdoutPath = Join-Path $runDir "stdout.txt"
$stderrPath = Join-Path $runDir "stderr.txt"
$commandPath = Join-Path $runDir "command.txt"
$manifestPath = Join-Path $runDir "manifest.json"
$statusPath = Join-Path $runDir "status.txt"
$processMonitorPath = Join-Path $runDir "process_monitor.csv"
$gpuMonitorPath = Join-Path $runDir "gpu_monitor.csv"
$diskMonitorPath = Join-Path $runDir "disk_monitor.csv"
$stderrTailPath = Join-Path $runDir "stderr_tail.txt"
$environmentPath = Join-Path $runDir "environment.json"

$argsList = @("--cuda")
if ($SsdStreaming) {
    $argsList += "--ssd-streaming"
    if (-not [string]::IsNullOrWhiteSpace($SsdStreamingCacheExperts)) {
        $argsList += @("--ssd-streaming-cache-experts", $SsdStreamingCacheExperts)
    }
    if (-not [string]::IsNullOrWhiteSpace($RamStreamingCacheExperts)) {
        $argsList += @("--ram-streaming-cache-experts", $RamStreamingCacheExperts)
    }
    if ($RamStreamingCachePreload) {
        $argsList += "--ram-streaming-cache-preload"
    }
}
$argsList += @("-m", $Model)
$argsList += @("--prompt-file", $PromptFile)
$argsList += @("--ctx-start", [string]$CtxStart)
$argsList += @("--ctx-max", [string]$CtxMax)
if ($CtxAlloc -gt 0) {
    $argsList += @("--ctx-alloc", [string]$CtxAlloc)
}
$argsList += @("--step-incr", [string]$StepIncr)
if ($PrefillChunk -gt 0) {
    $argsList += @("--prefill-chunk", [string]$PrefillChunk)
}
$argsList += @("--gen-tokens", [string]$GenTokens)
$argsList += @("--csv", $csvPath)

$argumentLine = ($argsList | ForEach-Object { Quote-Arg $_ }) -join " "
$commandLine = (Quote-Arg $exe) + " " + $argumentLine
$relevantEnvironment = Get-RelevantEnvironment
Write-TextFile -Path $commandPath -Value $commandLine
$relevantEnvironment | ConvertTo-Json -Depth 4 |
    Set-Content -LiteralPath $environmentPath -Encoding UTF8

$manifest = [ordered]@{
    created_at = Get-Date -Format o
    status = if ($DryRun) { "dry-run" } else { "created" }
    dry_run = [bool]$DryRun
    exe = $exe
    argument_line = $argumentLine
    command_line = $commandLine
    model = $Model
    prompt_file = $PromptFile
    ctx_start = $CtxStart
    ctx_max = $CtxMax
    ctx_alloc = $CtxAlloc
    step_incr = $StepIncr
    gen_tokens = $GenTokens
    prefill_chunk = $PrefillChunk
    ssd_streaming = [bool]$SsdStreaming
    ssd_streaming_cache_experts = $SsdStreamingCacheExperts
    ram_streaming_cache_experts = $RamStreamingCacheExperts
    ram_streaming_cache_preload = [bool]$RamStreamingCachePreload
    monitor_interval_seconds = $MonitorIntervalSeconds
    run_dir = $runDir
    csv = $csvPath
    stdout = $stdoutPath
    stderr = $stderrPath
    environment = $relevantEnvironment
    environment_file = $environmentPath
}
$manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

if ($DryRun) {
    Write-Host "Dry run wrote observable benchmark bundle: $runDir"
    exit 0
}

if (-not (Test-Path -LiteralPath $exe)) {
    throw "Missing benchmark executable: $exe"
}
if (-not (Test-Path -LiteralPath $Model)) {
    throw "Missing model file: $Model"
}
if (-not (Test-Path -LiteralPath $PromptFile)) {
    throw "Missing prompt file: $PromptFile"
}

Try-Run -Command "nvidia-smi" -Arguments @() -OutputPath (Join-Path $runDir "nvidia_smi_before.txt")
Get-ComputerInfo | Select-Object OsName,OsVersion,CsTotalPhysicalMemory,CsProcessors | Format-List |
    Out-File -LiteralPath (Join-Path $runDir "computer_info.txt") -Encoding UTF8

"timestamp,pid,has_exited,working_set_bytes,private_bytes,virtual_bytes,cpu_seconds" |
    Set-Content -LiteralPath $processMonitorPath -Encoding UTF8
"local_timestamp,gpu_timestamp,index,name,memory_total_mib,memory_used_mib,memory_free_mib,utilization_gpu_percent,power_draw_w" |
    Set-Content -LiteralPath $gpuMonitorPath -Encoding UTF8
"timestamp,disk_read_bytes_per_sec,disk_write_bytes_per_sec" |
    Set-Content -LiteralPath $diskMonitorPath -Encoding UTF8

$startTime = Get-Date
"start=$($startTime.ToString('o'))" | Set-Content -LiteralPath $statusPath -Encoding UTF8
$process = Start-Process -FilePath $exe -ArgumentList $argumentLine -WorkingDirectory $repoRoot `
    -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath `
    -WindowStyle Hidden -PassThru

Add-Content -LiteralPath $statusPath -Value "pid=$($process.Id)"

while (-not $process.HasExited) {
    Append-ProcessSample -Process $process -Path $processMonitorPath
    Append-GpuSample -Path $gpuMonitorPath
    Append-DiskSample -Path $diskMonitorPath
    if (Test-Path -LiteralPath $stderrPath) {
        Get-Content -Tail 80 -LiteralPath $stderrPath | Set-Content -LiteralPath $stderrTailPath -Encoding UTF8
    }
    Start-Sleep -Seconds $MonitorIntervalSeconds
}

$process.WaitForExit()
$process.Refresh()
$endTime = Get-Date
$exitCode = $null
try {
    $exitCode = $process.ExitCode
} catch {
    $exitCode = $null
}
if ($null -eq $exitCode -and (Test-Path -LiteralPath $stderrPath)) {
    $finishLine = Get-Content -Tail 200 -LiteralPath $stderrPath |
        Where-Object { $_ -match 'ds4-bench: .*run finish rc=(-?\d+)' } |
        Select-Object -Last 1
    if ($finishLine -match 'rc=(-?\d+)') {
        $exitCode = [int]$Matches[1]
    }
}
if ($null -eq $exitCode) {
    $exitCode = -1
}
Append-ProcessSample -Process $process -Path $processMonitorPath
Append-GpuSample -Path $gpuMonitorPath
Append-DiskSample -Path $diskMonitorPath
Try-Run -Command "nvidia-smi" -Arguments @() -OutputPath (Join-Path $runDir "nvidia_smi_after.txt")

if (Test-Path -LiteralPath $stderrPath) {
    Get-Content -Tail 120 -LiteralPath $stderrPath | Set-Content -LiteralPath $stderrTailPath -Encoding UTF8
}

Add-Content -LiteralPath $statusPath -Value "end=$($endTime.ToString('o'))"
Add-Content -LiteralPath $statusPath -Value "elapsed_seconds=$([math]::Round(($endTime - $startTime).TotalSeconds, 3))"
Add-Content -LiteralPath $statusPath -Value "exit_code=$exitCode"

$manifest.status = if ($exitCode -eq 0) { "completed" } else { "failed" }
$manifest.exit_code = $exitCode
$manifest.ended_at = $endTime.ToString("o")
$manifest.elapsed_seconds = [math]::Round(($endTime - $startTime).TotalSeconds, 3)
$manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

Write-Host "Observable benchmark bundle: $runDir"
exit $exitCode
