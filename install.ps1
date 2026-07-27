#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Build vitebc/unica + runtime tools and configure opencode on Windows.

.DESCRIPTION
    - Builds unica from source (cargo build --release)
    - Downloads v8-runner, bsl-analyzer, rlm-tools-bsl, rlm-bsl-index
    - Generates manifest.json with SHA-256 checksums
    - Copies skills
    - Patches opencode.json

.PARAMETER UnicaDir
    Installation directory (default: $env:LOCALAPPDATA\opencode\unica)

.PARAMETER RepoRoot
    Path to unica repo checkout (default: parent of script)

.PARAMETER SkipVerify
    Skip SHA-256 verification

.PARAMETER InstallSkills
    Copy skills into .opencode\skills of current project

.PARAMETER Help
    Show this help

.EXAMPLE
    .\install.ps1 -InstallSkills
#>
param(
    [string]$UnicaDir = "",
    [string]$RepoRoot = "",
    [switch]$SkipVerify = $false,
    [switch]$InstallSkills = $false,
    [switch]$Help = $false
)

if ($Help) {
    Get-Help $PSCommandPath -Detailed
    exit 0
}

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# ---- One-liner redirect if Cargo.toml not found in current dir ----
if (-not (Test-Path ".\Cargo.toml")) {
    Write-Host "==> Cloning vitebc/unica..." -ForegroundColor Cyan
    $workDir = Join-Path $env:TEMP "unica-install-$PID"
    if (Test-Path $workDir) { Remove-Item -Recurse -Force $workDir }
    $origPref = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"
    $null = git clone --depth 1 "https://github.com/vitebc/unica.git" $workDir 2>&1
    $ErrorActionPreference = $origPref
    if ($LASTEXITCODE -ne 0) { throw "git clone failed (exit $LASTEXITCODE)" }
    Push-Location $workDir
    powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "install.ps1"
    Pop-Location
    exit 0
    exit $LASTEXITCODE
}

$ForkRepo = "vitebc/unica"
$ToolchainRepo = "IngvarConsulting/unica-toolchain"

# ---- Helper functions ----
function msg($text) { Write-Host "==> $text" -ForegroundColor Cyan }
function warn($text) { Write-Host "WARN: $text" -ForegroundColor Yellow }
function err($text) { Write-Host "ERROR: $text" -ForegroundColor Red; exit 1 }

function sha256_file($path) {
    $hash = Get-FileHash -Path $path -Algorithm SHA256
    return $hash.Hash.ToLower()
}

function download_file($url, $dest) {
    $filename = [System.IO.Path]::GetFileName($url)
    msg "Downloading $filename"
    $parent = Split-Path $dest -Parent
    if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing -TimeoutSec 300
}

# ---- Default paths ----
$ScriptPath = Split-Path -Parent $PSCommandPath
if (-not $RepoRoot) {
    $cargoToml = Join-Path $ScriptPath "Cargo.toml"
    if (Test-Path $cargoToml) {
        $RepoRoot = $ScriptPath
    } else {
        $RepoRoot = Join-Path $ScriptPath "unica-source"
    }
}
if (-not $UnicaDir) {
    $localAppData = [Environment]::GetFolderPath("LocalApplicationData")
    $UnicaDir = Join-Path $localAppData "opencode\unica"
}

$ToolsDir = $UnicaDir
$SkillsDir = Join-Path $UnicaDir "skills"
$ThirdPartyDir = Join-Path $UnicaDir "third-party"
$BuildRoot = Join-Path $UnicaDir "build"

# Tool definitions from tools.lock.json
$Tools = @(
    @{
        Name = "v8-runner"
        AssetName = "v8-runner-win-x64.exe"
        AssetTag = "v8-runner-v0.5.1-build.1"
        Sha256 = "67251d36f9e1babbf4fadfee16be0490b0205a7a2bd279795d7e5fc8012a02e1"
    }
    @{
        Name = "bsl-analyzer"
        AssetName = "bsl-analyzer-win-x64.exe"
        AssetTag = "bsl-analyzer-v0.2.55-build.1"
        Sha256 = "f024f6d03ad58bfed18cefaf38e4a6e593a1c37b22bc6926d8d270e631bc8703"
    }
    @{
        Name = "rlm-tools-bsl"
        AssetName = "rlm-tools-bsl-win-x64.exe"
        AssetTag = "rlm-tools-bsl-v1.26.0-build.3"
        Sha256 = "02e13273694f0dc5ec4e185acef2b030e95b6191d7390daf3bb9b1cc9853702d"
    }
    @{
        Name = "rlm-bsl-index"
        AssetName = "rlm-bsl-index-win-x64.exe"
        AssetTag = "rlm-tools-bsl-v1.26.0-build.3"
        Sha256 = "7e7c43c6991cbe658fb974d4a3e0afc2e0adb37a300ae87688a9d4cfb1882f65"
    }
)

# ---- Check dependencies ----
function Check-Deps {
    $missing = @()
    if (-not (Get-Command "cargo" -ErrorAction SilentlyContinue)) { $missing += "Rust (cargo)" }
    if (-not (Get-Command "git" -ErrorAction SilentlyContinue)) { $missing += "git" }
    if (-not (Get-Command "python3" -ErrorAction SilentlyContinue) -and -not (Get-Command "python" -ErrorAction SilentlyContinue)) {
        $missing += "Python 3"
    }
    if ($missing.Count -gt 0) {
        err "Missing dependencies: $($missing -join ', '). Install Rust from https://rustup.rs, Git from https://git-scm.com"
    }
    msg "All core dependencies found"
}

# ---- Build unica ----
function Build-Unica {
    if (-not (Test-Path (Join-Path $RepoRoot "Cargo.toml"))) {
        msg "Cloning $ForkRepo to $RepoRoot"
        git clone --depth 1 "https://github.com/$ForkRepo.git" $RepoRoot
    } else {
        msg "Using repo at $RepoRoot"
    }

    msg "Building unica (cargo build --release)"
    Push-Location $RepoRoot
    try {
        cargo build --release --package unica-coder --bin unica
        if (-not (Test-Path $ToolsDir)) { New-Item -ItemType Directory -Path $ToolsDir -Force | Out-Null }
        Copy-Item "target\release\unica.exe" (Join-Path $ToolsDir "unica.exe") -Force
        msg "unica built: $(Join-Path $ToolsDir 'unica.exe')"
    } finally {
        Pop-Location
    }
}

# ---- Download tools ----
function Download-Tool($tool) {
    $url = "https://github.com/$ToolchainRepo/releases/download/$($tool.AssetTag)/$($tool.AssetName)"
    $dest = Join-Path $ToolsDir $tool.AssetName
    $exeDest = Join-Path $ToolsDir "$($tool.Name).exe"

    if ($tool.Name -eq "v8-runner") {
        # v8-runner publishes tar.gz on GitHub, but we download from unica-toolchain as .exe
        download_file $url $dest
    } elseif ($tool.Name -eq "bsl-analyzer") {
        download_file $url $dest
    } else {
        # rlm tools
        download_file $url $dest
    }

    if (-not $SkipVerify) {
        $actual = sha256_file $dest
        $expected = $tool.Sha256
        if ($actual -ne $expected) {
            err "SHA-256 mismatch for $($tool.Name): expected $expected, got $actual"
        }
        msg "$($tool.Name) checksum OK"
    }

    Copy-Item $dest $exeDest -Force
    msg "$($tool.Name) installed: $exeDest"
}

function Download-Tools {
    foreach ($tool in $Tools) {
        Download-Tool $tool
    }
}

# ---- Copy skills ----
function Copy-Skills {
    $src = Join-Path $RepoRoot "plugins\unica\skills"
    if (-not (Test-Path $src)) {
        warn "Skills directory not found: $src"
        return
    }
    if (-not (Test-Path $SkillsDir)) { New-Item -ItemType Directory -Path $SkillsDir -Force | Out-Null }
    Copy-Item "$src\*" $SkillsDir -Recurse -Force
    $count = (Get-ChildItem $SkillsDir -Recurse -Filter "SKILL.md").Count
    msg "Skills copied to $SkillsDir ($count skills)"
}

# ---- Generate manifest ----
function Generate-Manifest {
    msg "Generating manifest.json"
    if (-not (Test-Path $ThirdPartyDir)) { New-Item -ItemType Directory -Path $ThirdPartyDir -Force | Out-Null }

    $manifest = @{
        schemaVersion = 2
        builtAt = [DateTime]::UtcNow.ToString("o")
        target = "win-x64"
        tools = @()
    }

    Get-ChildItem $ToolsDir -File | ForEach-Object {
        $hash = sha256_file $_.FullName
        $manifest.tools += @{
            name = $_.Name
            binaryPath = $_.Name
            sha256 = $hash
        }
    }

    $json = $manifest | ConvertTo-Json -Depth 10
    Set-Content (Join-Path $ThirdPartyDir "manifest.json") $json -Encoding UTF8
    msg "Manifest generated: $(Join-Path $ThirdPartyDir 'manifest.json')"
}

# ---- Configure opencode.json ----
function Get-OpencodeConfig {
    $configs = @("opencode.json", "opencode.jsonc", ".opencode\opencode.json", ".opencode\opencode.jsonc")
    $dir = Get-Location
    while ($dir) {
        foreach ($cfg in $configs) {
            $path = Join-Path $dir $cfg
            if (Test-Path $path) { return $path }
        }
        $parent = Split-Path $dir -Parent
        if ($parent -eq $dir) { break }
        $dir = $parent
    }
    return $null
}

function Update-OpencodeConfig {
    $configPath = Get-OpencodeConfig
    if (-not $configPath) {
        $configPath = Join-Path (Get-Location) "opencode.json"
    }

    $data = @{}
    if (Test-Path $configPath) {
        $content = Get-Content $configPath -Raw -Encoding UTF8
        if ($content) {
            $data = $content | ConvertFrom-Json -AsHashtable
            if (-not $data) { $data = @{} }
        }
    }

    if ($data.ContainsKey("mcp") -and $data["mcp"].ContainsKey("unica")) {
        msg "openCode config already has unica MCP server: $configPath"
        return
    }

    $unicaExe = Join-Path $ToolsDir "unica.exe"
    if (-not $data.ContainsKey("mcp")) { $data["mcp"] = @{} }
    $data["mcp"]["unica"] = @{
        type = "local"
        command = @($unicaExe)
        enabled = $true
    }

    $json = $data | ConvertTo-Json -Depth 10
    Set-Content $configPath $json -Encoding UTF8
    msg "openCode config updated: $configPath"
}

# ---- Install skills to project ----
function Install-SkillsToProject {
    $dir = Get-Location
    $projectSkills = $null
    while ($dir) {
        $candidate = Join-Path $dir ".opencode\skills"
        if (Test-Path (Join-Path $dir ".opencode")) {
            $projectSkills = $candidate
            break
        }
        $parent = Split-Path $dir -Parent
        if ($parent -eq $dir) { break }
        $dir = $parent
    }
    if (-not $projectSkills) { $projectSkills = Join-Path (Get-Location) ".opencode\skills" }

    if (Test-Path $SkillsDir) {
        if (-not (Test-Path $projectSkills)) { New-Item -ItemType Directory -Path $projectSkills -Force | Out-Null }
        Copy-Item "$SkillsDir\*" $projectSkills -Recurse -Force
        msg "Skills installed to $projectSkills"
    }
}

# ---- Verify installation ----
function Verify-Installation {
    $errors = 0
    Write-Host "`n--- Проверка установленных файлов ---`n"

    Write-Host "  Бинарники ($ToolsDir):"
    $toolList = @("unica.exe", "v8-runner.exe", "bsl-analyzer.exe", "rlm-tools-bsl.exe", "rlm-bsl-index.exe")
    foreach ($tool in $toolList) {
        $path = Join-Path $ToolsDir $tool
        if (Test-Path $path) {
            $size = (Get-Item $path).Length
            if ($tool -eq "unica.exe") {
                $result = & $path --help 2>&1 | Select-String -Pattern "unica"
                if ($result) { Write-Host "    [OK]  $tool ($size bytes, запускается)" -ForegroundColor Green }
                else { Write-Host "    [ERR] $tool (файл есть, но не запускается)" -ForegroundColor Red; $errors++ }
            } else {
                Write-Host "    [OK]  $tool ($size bytes)" -ForegroundColor Green
            }
        } else {
            Write-Host "    [--]  $tool (не установлен)" -ForegroundColor DarkYellow
            $errors++
        }
    }

    Write-Host "`n  Манифест:"
    $manifest = Join-Path $ThirdPartyDir "manifest.json"
    if (Test-Path $manifest) {
        Write-Host "    [OK]  manifest.json" -ForegroundColor Green
    } else {
        Write-Host "    [--]  manifest.json (не найден)" -ForegroundColor DarkYellow; $errors++
    }

    Write-Host "`n  Навыки:"
    if (Test-Path $SkillsDir) {
        $skillCount = (Get-ChildItem $SkillsDir -Recurse -Filter "SKILL.md").Count
        Write-Host "    [OK]  skills/ ($skillCount навыков)" -ForegroundColor Green
    } else {
        Write-Host "    [--]  skills/ (не установлены)" -ForegroundColor DarkYellow; $errors++
    }

    Write-Host ""
    if ($errors -eq 0) { msg "Все компоненты установлены" }
    else { warn "$errors компонентов отсутствуют или повреждены" }
}

# ---- Main ----
function Main {
    Write-Host ""
    Write-Host "==============================================" -ForegroundColor Cyan
    Write-Host " vitebc/unica — Windows installer" -ForegroundColor Cyan
    Write-Host "==============================================" -ForegroundColor Cyan
    Write-Host ""

    Check-Deps
    msg "Install dir: $UnicaDir"

    New-Item -ItemType Directory -Path $BuildRoot -Force | Out-Null
    if (-not (Test-Path $ToolsDir)) { New-Item -ItemType Directory -Path $ToolsDir -Force | Out-Null }

    Build-Unica
    Download-Tools
    Copy-Skills
    Generate-Manifest
    Update-OpencodeConfig

    if ($InstallSkills) { Install-SkillsToProject }

    Verify-Installation

    Write-Host ""
    Write-Host "==============================================" -ForegroundColor Cyan
    Write-Host " Installation complete!" -ForegroundColor Cyan
    Write-Host "   Tools:  $ToolsDir" -ForegroundColor Cyan
    Write-Host "   Skills: $SkillsDir" -ForegroundColor Cyan
    Write-Host " Restart opencode to pick up the MCP server." -ForegroundColor Cyan
    Write-Host "==============================================" -ForegroundColor Cyan
}

Main
