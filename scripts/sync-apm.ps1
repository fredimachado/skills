#Requires -Version 7.2
<#
.SYNOPSIS
Install the third-party skills listed in apm/apm.yml for every harness, through APM.

.DESCRIPTION
pwsh -NoProfile -File <repository>/scripts/sync-apm.ps1 [-ApmHome <folder>]

apm/apm.yml in this repository is the one list of third-party skills; apm/apm.lock.yaml
pins their exact commits. APM keeps its user-scope manifest, lock and working state in
its home ($APM_HOME, default ~/.apm), which is per machine. This script:

  1. copies apm/apm.yml, and apm/apm.lock.yaml when it exists, into the APM home
  2. runs `apm install -g`, which deploys the skills to ~/.claude/skills (Claude Code)
     and ~/.agents/skills (Codex, Cursor)
  3. copies the lock APM wrote back to apm/apm.lock.yaml, to commit

Use it on a new machine to restore the same versions, and after editing apm/apm.yml.
Never run `apm install -g <package>` directly: that changes the copy in the APM home,
and the next sync overwrites it.

When apm is missing, it shows the install command for this OS and, from a terminal, asks
"Install it now? [Y/n]" (Enter means yes) and runs exactly that command. Without a
terminal it only shows the command.

Exit code: APM's own; 2 when apm is not installed (or the install was declined).
#>
[CmdletBinding()]
param([string] $ApmHome = $(if ($env:APM_HOME) { $env:APM_HOME } else { Join-Path $HOME '.apm' }))

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$source = Join-Path (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path 'apm'
$manifest = Join-Path $source 'apm.yml'
$lock = Join-Path $source 'apm.lock.yaml'

if (-not (Get-Command apm -ErrorAction SilentlyContinue)) {
    # The installer for this OS. SYNC_APM_INSTALL_COMMAND replaces it (used by the tests).
    $install = if ($env:SYNC_APM_INSTALL_COMMAND) { $env:SYNC_APM_INSTALL_COMMAND }
               elseif (-not $IsWindows) { 'curl -sSL https://aka.ms/apm-unix | sh' }
               elseif (Get-Command winget -ErrorAction SilentlyContinue) { 'winget install --id Microsoft.APM --exact --source winget' }
               else { 'irm https://aka.ms/apm-windows | iex' }
    'apm is not installed. It installs with:'
    "  $install"
    # Ask only someone at a terminal (SYNC_APM_PROMPT=1 forces the question, for the tests).
    if ($env:SYNC_APM_PROMPT -ne '1' -and [Console]::IsInputRedirected) { 'Run that, then run this script again.'; exit 2 }
    [Console]::Out.Write('Install it now? [Y/n] ')
    $answer = "$([Console]::In.ReadLine())".Trim()
    if ($answer -and $answer -notmatch '^(y|yes)$') { 'Not installed. Run the command above yourself, then run this script again.'; exit 2 }

    Invoke-Expression $install   # exactly the command shown above

    # A fresh install is not on this session's PATH yet: look where the installers put it.
    $places = if ($IsWindows) { @("$env:LOCALAPPDATA\Microsoft\WinGet\Links", "$env:LOCALAPPDATA\Programs\apm\current") }
              else { @("$HOME/.local/bin") }
    foreach ($p in $places) {
        if (Get-ChildItem -LiteralPath $p -Filter 'apm*' -File -ErrorAction SilentlyContinue) { $env:PATH = "$p$([IO.Path]::PathSeparator)$env:PATH" }
    }
    if (-not (Get-Command apm -ErrorAction SilentlyContinue)) {
        'apm is still not found after the install. Open a new terminal and run this script again.'
        exit 2
    }
}
if (-not (Test-Path -LiteralPath $manifest)) { "No manifest at $manifest."; exit 2 }

New-Item -ItemType Directory -Force -Path $ApmHome | Out-Null
Copy-Item -LiteralPath $manifest -Destination (Join-Path $ApmHome 'apm.yml') -Force
if (Test-Path -LiteralPath $lock) { Copy-Item -LiteralPath $lock -Destination (Join-Path $ApmHome 'apm.lock.yaml') -Force }

$env:APM_HOME = $ApmHome
& apm install -g
$code = $LASTEXITCODE
if ($code -ne 0) { "apm install -g failed (exit $code); apm/apm.lock.yaml left as it was."; exit $code }

$written = Join-Path $ApmHome 'apm.lock.yaml'
if (Test-Path -LiteralPath $written) {
    $changed = -not (Test-Path -LiteralPath $lock) -or
               (Get-FileHash -LiteralPath $written).Hash -ne (Get-FileHash -LiteralPath $lock).Hash
    if ($changed) {
        Copy-Item -LiteralPath $written -Destination $lock -Force
        "apm/apm.lock.yaml updated; commit it."
    } else {
        'apm/apm.lock.yaml unchanged.'
    }
}
exit 0
