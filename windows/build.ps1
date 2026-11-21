#requires -Version 5.1
<#
.SYNOPSIS
    Builds, tests and packages AirMic Hub for Windows x64.

.EXAMPLE
    .\build.ps1
    .\build.ps1 -Configuration Debug -SkipTests
    .\build.ps1 -FrameworkDependent
#>
[CmdletBinding()]
param(
    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Release",

    [string]$Runtime = "win-x64",

    [switch]$SkipTests,

    [switch]$FrameworkDependent,

    [switch]$NoZip
)

$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
$version = "1.0.0"

function Invoke-Step {
    param(
        [string]$Name,
        [scriptblock]$Action
    )
    Write-Host ""
    Write-Host "== $Name ==" -ForegroundColor Cyan
    & $Action
    if ($LASTEXITCODE -ne 0 -and $null -ne $LASTEXITCODE) {
        throw "$Name 失败（exit $LASTEXITCODE）"
    }
}

Push-Location $root
try {
    $dotnet = (Get-Command dotnet -ErrorAction Stop).Source
    Write-Host "AirMic Hub $version build" -ForegroundColor Green
    Write-Host "dotnet      : $dotnet"
    Write-Host "configuration: $Configuration"
    Write-Host "runtime     : $Runtime"

    Invoke-Step "还原 NuGet 包" {
        & $dotnet restore AirMicHub.sln
    }

    Invoke-Step "编译解决方案" {
        & $dotnet build AirMicHub.sln -c $Configuration --no-restore
    }

    if (-not $SkipTests) {
        Invoke-Step "运行单元与集成测试" {
            & $dotnet test "tests\AirMicHub.Tests\AirMicHub.Tests.csproj" -c $Configuration --no-build
        }
    }
    else {
        Write-Host "已跳过测试（-SkipTests）" -ForegroundColor Yellow
    }

    $publishDir = Join-Path $root "dist\AirMicHub"
    if (Test-Path $publishDir) {
        Remove-Item $publishDir -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $publishDir | Out-Null

    if ($FrameworkDependent) {
        $selfContained = "false"
    }
    else {
        $selfContained = "true"
    }

    Invoke-Step "发布 win-x64 单文件版本" {
        & $dotnet publish "src\AirMicHub.App\AirMicHub.App.csproj" `
            -c $Configuration `
            -r $Runtime `
            --self-contained $selfContained `
            -o $publishDir `
            -p:PublishSingleFile=true `
            -p:IncludeNativeLibrariesForSelfExtract=true `
            -p:EnableCompressionInSingleFile=true `
            -p:DebugType=None `
            -p:DebugSymbols=false
    }

    Copy-Item -LiteralPath (Join-Path $root "README.md") -Destination $publishDir -Force
    Copy-Item -LiteralPath (Join-Path $root "TEST_REPORT.md") -Destination $publishDir -Force
    Copy-Item -LiteralPath (Join-Path $root "LICENSE") -Destination $publishDir -Force
    Copy-Item -LiteralPath (Join-Path $root "THIRD_PARTY_NOTICES.md") -Destination $publishDir -Force

    $docsSource = Join-Path $root "docs"
    if (Test-Path $docsSource) {
        $docsTarget = Join-Path $publishDir "docs"
        if (Test-Path $docsTarget) { Remove-Item $docsTarget -Recurse -Force }
        Copy-Item -LiteralPath $docsSource -Destination $docsTarget -Recurse -Force
    }

    $exe = Join-Path $publishDir "AirMicHub.exe"
    if (-not (Test-Path $exe)) {
        throw "发布目录中缺少 AirMicHub.exe：$publishDir"
    }
    Write-Host ""
    Write-Host ("已发布：{0}（{1:N1} MB）" -f $exe, ((Get-Item $exe).Length / 1MB)) -ForegroundColor Green

    if (-not $NoZip) {
        $distDir = Join-Path $root "dist"
        $zipPath = Join-Path $distDir ("AirMicHub-win-x64-{0}.zip" -f $version)
        if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
        Compress-Archive -Path (Join-Path $publishDir "*") -DestinationPath $zipPath -CompressionLevel Optimal
        $hash = Get-FileHash -LiteralPath $zipPath -Algorithm SHA256
        $sumFile = Join-Path $distDir "SHA256SUMS.txt"
        ("{0}  {1}" -f $hash.Hash, (Split-Path $zipPath -Leaf)) | Set-Content -LiteralPath $sumFile -Encoding ASCII
        Write-Host ("已打包：{0}（{1:N1} MB）" -f $zipPath, ((Get-Item $zipPath).Length / 1MB)) -ForegroundColor Green
        Write-Host ("SHA256：{0}" -f $hash.Hash)
    }

    Write-Host ""
    Write-Host "构建完成。" -ForegroundColor Green
    Write-Host "运行：$exe"
    Write-Host "日志：%LOCALAPPDATA%\AirMicHub\logs"
}
finally {
    Pop-Location
}
