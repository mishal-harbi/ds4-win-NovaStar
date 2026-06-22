param(
    [ValidateSet("cuda", "cpu")]
    [string]$Target = "cuda"
)

$ErrorActionPreference = "Stop"

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (!(Test-Path $vswhere)) {
    throw "vswhere.exe was not found. Install Visual Studio Build Tools with the C++ workload."
}

$vsPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (!$vsPath) {
    throw "Visual Studio C++ Build Tools were not found."
}

$vsDevCmd = Join-Path $vsPath "Common7\Tools\VsDevCmd.bat"
if (!(Test-Path $vsDevCmd)) {
    throw "VsDevCmd.bat was not found at $vsDevCmd"
}

$defines = @(
    "/D_CRT_SECURE_NO_WARNINGS",
    "/D_CRT_NONSTDC_NO_DEPRECATE",
    "/DWIN32_LEAN_AND_MEAN",
    "/DNOMINMAX"
)
if ($Target -eq "cpu") {
    $defines += "/DDS4_NO_GPU"
}

$coreSources = @(
    "ds4.c",
    "ds4_help.c",
    "ds4_ssd.c",
    "ds4_win32.c",
    "ds4_distributed_win32.c"
)

$cliSources = @(
    "ds4_cli.c",
    "linenoise_win32.c"
)

$benchSources = @(
    "ds4_bench.c"
)

$serverSources = @(
    "ds4_server.c",
    "ds4_kvstore.c",
    "rax.c"
)

$agentSources = @(
    "ds4_agent.c",
    "ds4_web.c",
    "ds4_kvstore.c",
    "linenoise_win32.c"
)

$sources = $coreSources + $cliSources + $benchSources + $serverSources + $agentSources
$sources = $sources | Select-Object -Unique
$common = @("/nologo", "/std:c11", "/O2", "/Zi", "/W3", "/wd4244", "/wd4267", "/wd4996") + $defines
$compile = "cl " + (($common + "/c" + $sources) -join " ")
$coreObjects = $coreSources | ForEach-Object { [IO.Path]::ChangeExtension($_, ".obj") }
$cliObjects = $cliSources | ForEach-Object { [IO.Path]::ChangeExtension($_, ".obj") }
$benchObjects = $benchSources | ForEach-Object { [IO.Path]::ChangeExtension($_, ".obj") }
$serverObjects = $serverSources | ForEach-Object { [IO.Path]::ChangeExtension($_, ".obj") }
$agentObjects = $agentSources | ForEach-Object { [IO.Path]::ChangeExtension($_, ".obj") }
$backendObjects = @()
$win32Link = " ws2_32.lib"

$cudaCommand = ""
$cudaLink = ""
if ($Target -eq "cuda") {
    $cudaPath = $env:CUDA_PATH
    if (!$cudaPath) {
        $nvccCmd = Get-Command nvcc.exe -ErrorAction SilentlyContinue
        if ($nvccCmd) {
            $cudaPath = Split-Path -Parent (Split-Path -Parent $nvccCmd.Source)
        }
    }
    if (!$cudaPath -or !(Test-Path (Join-Path $cudaPath "bin\nvcc.exe"))) {
        throw "CUDA Toolkit was not found. Set CUDA_PATH or build with -Target cpu."
    }
    $nvcc = Join-Path $cudaPath "bin\nvcc.exe"
    $cudaLib = Join-Path $cudaPath "lib\x64"
    if (!(Test-Path $cudaLib)) {
        throw "CUDA library directory was not found: $cudaLib"
    }
    $nvccDefines = @(
        "-D_CRT_SECURE_NO_WARNINGS",
        "-D_CRT_NONSTDC_NO_DEPRECATE",
        "-DWIN32_LEAN_AND_MEAN",
        "-DNOMINMAX"
    )
    $cudaCommand = "`"$nvcc`" -std=c++17 -Xcompiler /Zc:preprocessor " + (($nvccDefines + "-c" + "-o" + "ds4_cuda.obj" + "ds4_cuda.cu") -join " ")
    $backendObjects += "ds4_cuda.obj"
    $cudaLink = " /LIBPATH:`"$cudaLib`" cudart.lib cublas.lib"
}

$cliLinkObjects = @($cliObjects) + @($coreObjects) + @($backendObjects)
$benchLinkObjects = @($benchObjects) + @($coreObjects) + @($backendObjects)
$serverLinkObjects = @($serverObjects) + @($coreObjects) + @($backendObjects)
$agentLinkObjects = @($agentObjects) + @($coreObjects) + @($backendObjects)
$linkCli = "link /nologo /out:ds4.exe " + ($cliLinkObjects -join " ") + $cudaLink + $win32Link
$linkBench = "link /nologo /out:ds4-bench.exe " + ($benchLinkObjects -join " ") + $cudaLink + $win32Link
$linkServer = "link /nologo /out:ds4-server.exe " + ($serverLinkObjects -join " ") + $cudaLink + $win32Link
$linkAgent = "link /nologo /out:ds4-agent.exe " + ($agentLinkObjects -join " ") + $cudaLink + $win32Link

$cmd = @"
@echo on
call "$vsDevCmd" -arch=x64
if errorlevel 1 exit /b %errorlevel%
$compile
if errorlevel 1 exit /b %errorlevel%
$cudaCommand
if errorlevel 1 exit /b %errorlevel%
$linkCli
if errorlevel 1 exit /b %errorlevel%
$linkBench
if errorlevel 1 exit /b %errorlevel%
$linkServer
if errorlevel 1 exit /b %errorlevel%
$linkAgent
"@

$cmdPath = Join-Path $env:TEMP "ds4-windows-build-$PID.cmd"
Set-Content -LiteralPath $cmdPath -Encoding ASCII -Value $cmd
try {
    & cmd /d /s /c "`"$cmdPath`""
    exit $LASTEXITCODE
} finally {
    Remove-Item -LiteralPath $cmdPath -Force -ErrorAction SilentlyContinue
}
