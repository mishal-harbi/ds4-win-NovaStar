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

function Assert-NotContains {
    param(
        [string]$Path,
        [string]$Needle,
        [string]$Message
    )
    $text = Get-Content -Raw -LiteralPath $Path
    if ($text.Contains($Needle)) {
        throw $Message
    }
}

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$ds4c = Join-Path $repoRoot "ds4.c"
$cuda = Join-Path $repoRoot "ds4_cuda.cu"

Assert-Contains $ds4c "defined(_WIN32)" "Windows/CUDA builds must enable FP16 attention-compressed KV storage"
Assert-Contains $ds4c "DS4_CUDA_ATTN_COMP_CACHE" "Windows/CUDA builds must expose runtime compressed-KV format selection"
Assert-Contains $cuda "cuda_comp_kv_to_f32_tensor" "CUDA backend must materialize compressed KV fallback formats for dense attention kernels"
Assert-Contains $cuda "f32_rows_to_q8_kv_kernel" "CUDA backend must store Q8 compressed KV rows from F32 staging"
Assert-Contains $cuda "COMP_FORMAT == DS4_GPU_COMP_KV_FORMAT_Q8" "CUDA compressed-KV loaders must implement Q8 row decoding"
Assert-Contains $cuda "cuda_comp_kv_load4<COMP_FORMAT>" "CUDA indexed attention kernels must use the format-specialized compressed-KV loader"
Assert-Contains $cuda "attention_indexed_mixed_heads8_online_kernel<8, 16, DS4_GPU_COMP_KV_FORMAT_F16>" "CUDA indexed online attention must launch a direct FP16 compressed-KV kernel"
Assert-Contains $cuda "attention_indexed_mixed_heads8_online_kernel<8, 16, DS4_GPU_COMP_KV_FORMAT_Q8>" "CUDA indexed online attention must launch a direct Q8 compressed-KV kernel"
Assert-NotContains $cuda "if (comp_kv_f16) return 0;" "CUDA attention wrappers must not reject FP16 compressed KV"

Write-Host "windows_kv_precision_tests.ps1: PASS"
