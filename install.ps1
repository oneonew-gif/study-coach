# install.ps1 - study-coach one-line installer for Windows (PowerShell 5.1+)
#
# Usage (PowerShell):
#   irm https://raw.githubusercontent.com/oneonew-gif/study-coach/main/install.ps1 | iex
# Or from a local copy:
#   powershell -ExecutionPolicy Bypass -File install.ps1 [-Zip <file.zip>] [-Dir <dest>] [-NoWinget]
#
# What it does:
#   1. Installs missing Git for Windows / Python 3 / Node LTS via winget (skip with -NoWinget)
#   2. Runs install.sh through Git Bash (Git Bash is the official Windows path)
#   3. Prints how to call the engine from cmd/PowerShell: <engine>\bin\sc.cmd
#
# This file is intentionally ASCII-only: Windows PowerShell 5.1 reads BOM-less files
# as the ANSI code page, so any Chinese text here would turn into mojibake.

param(
  [string]$Zip = "",
  [string]$Dir = "",
  [switch]$NoWinget
)

$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$Repo = "oneonew-gif/study-coach"
$RawInstallSh = "https://raw.githubusercontent.com/$Repo/main/install.sh"

function Say($m) { Write-Host $m }
function Die($m) { Write-Host "[x] $m" -ForegroundColor Red; exit 1 }

function Refresh-Path {
  $m = [Environment]::GetEnvironmentVariable("Path", "Machine")
  $u = [Environment]::GetEnvironmentVariable("Path", "User")
  $env:Path = "$m;$u"
}

function Find-GitBash {
  $cands = @(
    "$env:ProgramFiles\Git\bin\bash.exe",
    "$env:ProgramW6432\Git\bin\bash.exe",
    "${env:ProgramFiles(x86)}\Git\bin\bash.exe",
    "$env:LocalAppData\Programs\Git\bin\bash.exe"
  )
  foreach ($c in $cands) { if ($c -and (Test-Path $c)) { return $c } }
  $git = Get-Command git.exe -ErrorAction SilentlyContinue
  if ($git) {
    $b = Join-Path (Split-Path (Split-Path $git.Source)) "bin\bash.exe"
    if (Test-Path $b) { return $b }
  }
  return $null   # never fall back to System32\bash.exe: that is WSL
}

# Real Python check: the WindowsApps python.exe stub is found on PATH but only opens the Store.
function Test-RealPython {
  foreach ($c in @(@("python3"), @("python"), @("py", "-3"))) {
    $exe = $c[0]
    if (-not (Get-Command $exe -ErrorAction SilentlyContinue)) { continue }
    $args2 = @()
    if ($c.Length -gt 1) { $args2 += $c[1..($c.Length - 1)] }
    $args2 += @("-c", "import sys; sys.exit(0 if sys.version_info[:2] >= (3, 8) else 1)")
    try {
      & $exe @args2 2>$null | Out-Null
      if ($LASTEXITCODE -eq 0) { return $true }
    } catch {}
  }
  return $false
}

function Winget-Install($id, $label) {
  if ($NoWinget) { Say "    (skipped: -NoWinget) please install $label manually"; return }
  if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Say "    winget not available. Install $label manually, then rerun."
    return
  }
  Say "    installing $label via winget ..."
  winget install --id $id -e --accept-source-agreements --accept-package-agreements --silent | Out-Host
  Refresh-Path
}

Say ""
Say "study-coach installer (Windows)"
Say "----------------------------------------------"

# 1. Git Bash
Say "1. Git for Windows (Git Bash)"
$bash = Find-GitBash
if (-not $bash) { Winget-Install "Git.Git" "Git for Windows"; $bash = Find-GitBash }
if (-not $bash) { Die "Git Bash not found. Install Git for Windows (https://git-scm.com/download/win), open a NEW PowerShell, rerun." }
Say "    ok: $bash"

# 2. Python 3.8+
Say "2. Python 3.8+"
if (-not (Test-RealPython)) {
  Winget-Install "Python.Python.3.12" "Python 3"
  if (-not (Test-RealPython)) {
    Say "    [!] Python still not usable. If 'python' opens the Microsoft Store:"
    Say "        Settings > Apps > Advanced app settings > App execution aliases > turn OFF python.exe / python3.exe"
    Say "        then open a NEW terminal. Engine files will still be installed."
  } else { Say "    ok" }
} else { Say "    ok" }

# 3. Node (optional, only the quiz tool needs it)
Say "3. Node.js (optional, quiz only)"
if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
  Winget-Install "OpenJS.NodeJS.LTS" "Node.js LTS"
}
if (Get-Command node -ErrorAction SilentlyContinue) { Say "    ok" } else { Say "    not installed - quiz unavailable, everything else works" }

# 4. Run install.sh in Git Bash
Say "4. Installing engine via Git Bash ..."
$work = Join-Path $env:TEMP ("study-coach-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $work | Out-Null
try {
  $localSh = Join-Path $PSScriptRoot "install.sh"
  if ($PSScriptRoot -and (Test-Path $localSh)) {
    $sh = $localSh
  } else {
    $sh = Join-Path $work "install.sh"
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -UseBasicParsing -Uri $RawInstallSh -OutFile $sh
  }
  # Strip CR in case the file was saved with CRLF (bash would fail on "set -u\r")
  $txt = [IO.File]::ReadAllText($sh) -replace "`r`n", "`n"
  $shLf = Join-Path $work "install-lf.sh"
  [IO.File]::WriteAllText($shLf, $txt, (New-Object System.Text.UTF8Encoding($false)))

  $env:MSYS_NO_PATHCONV = "1"
  $env:MSYS2_ARG_CONV_EXCL = "*"
  $bashArgs = @($shLf.Replace('\', '/'))
  if ($Zip) { $bashArgs += @("--zip", (Resolve-Path $Zip).Path.Replace('\', '/')) }
  if ($Dir) { $bashArgs += @("--dir", $Dir.Replace('\', '/')) }
  & $bash @bashArgs
  $rc = $LASTEXITCODE
} finally {
  Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}
if ($rc -ne 0) { Die "install.sh failed (exit $rc). See messages above." }

$home2 = if ($env:WORKBUDDY_HOME) { $env:WORKBUDDY_HOME } else { Join-Path $env:USERPROFILE ".workbuddy" }
$engine = if ($Dir) { $Dir } else { Join-Path $home2 "skills\study-coach" }
Say ""
Say "Done. From cmd / PowerShell use:"
Say "    & `"$engine\bin\sc.cmd`" help"
Say "    & `"$engine\bin\sc.cmd`" token      # store Canvas token safely"
Say "    & `"$engine\bin\sc.cmd`" doctor"
if ($engine -match "OneDrive") {
  Say "[!] Engine is inside a OneDrive folder. Sync locks can break scripts; consider -Dir C:\study-coach"
}
