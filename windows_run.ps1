param(
    [string]$Model = ".\gguf\DeepSeek-V4-Flash-IQ2XXS-w2Q2K-AProjQ8-SExpQ8-OutQ8-chat-v2-imatrix.gguf",
    [int]$Ctx = 8192,
    [int]$Tokens = 128,
    [string]$Cache = "8GB",
    [string]$RamCache = "",
    [switch]$RamCachePreload,
    [string]$Prompt = "Say hello in one sentence.",
    [switch]$Cold,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ExtraArgs
)

$ErrorActionPreference = "Stop"

if (!(Test-Path ".\ds4.exe")) {
    throw "ds4.exe was not found. Build it first with .\windows_build.ps1 -Target cuda."
}
if (!(Test-Path $Model)) {
    throw "Model file was not found: $Model"
}

$runArgs = @(
    "--cuda",
    "--ssd-streaming",
    "--ssd-streaming-cache-experts", $Cache,
    "-m", $Model,
    "--ctx", "$Ctx",
    "--nothink",
    "--temp", "0",
    "-n", "$Tokens",
    "-p", $Prompt
)
if ($Cold) {
    $runArgs = @("--cuda", "--ssd-streaming", "--ssd-streaming-cold") + $runArgs[2..($runArgs.Count - 1)]
}
if (-not [string]::IsNullOrWhiteSpace($RamCache)) {
    $runArgs += @("--ram-streaming-cache-experts", $RamCache)
}
if ($RamCachePreload) {
    $runArgs += "--ram-streaming-cache-preload"
}
if ($ExtraArgs) {
    $runArgs += $ExtraArgs
}

& ".\ds4.exe" @runArgs
exit $LASTEXITCODE
