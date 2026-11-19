#Requires -Version 7.2
<#
.SYNOPSIS
Link every skill in this repository into the folders the harnesses read (Windows).

.DESCRIPTION
pwsh -NoProfile -File <repository>/scripts/install.ps1 [target folder ...]

Links each folder under skills/ that has a SKILL.md into every target folder: a junction
on Windows, a symbolic link elsewhere. With no target, the targets are ~/.claude/skills
(Claude Code; Cursor reads it too) and ~/.agents/skills (Codex, Cursor). Every skill is
linked, so a sibling reference such as ../babysit-pr/SKILL.md resolves next to the link.
install.sh does the same on Linux and macOS without PowerShell.

- A missing link is created. A link that already points into this repository is left as
  it is, so running the script twice changes nothing.
- A real directory or file with a skill's name is never replaced: it is reported and
  skipped. Neither is a link that points somewhere else, including one whose target is
  gone. Retire those yourself, then run this again.
- Everything else in the target folders is left alone.

Exit code: 0 when every skill is linked in every target, 1 when any was skipped.
#>
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$repo = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$skillsDir = Join-Path $repo 'skills'
$skills = @(Get-ChildItem -LiteralPath $skillsDir -Directory | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'SKILL.md') } | ForEach-Object Name)
$targets = @(if ($args.Count) { $args } else { (Join-Path $HOME '.claude/skills'), (Join-Path $HOME '.agents/skills') })

function Get-RealPath([string] $Path) { [IO.Path]::GetFullPath($Path).TrimEnd('\', '/') }

$skipped = 0
foreach ($target in $targets) {
    if (-not (Test-Path -LiteralPath $target)) { New-Item -ItemType Directory -Force -Path $target | Out-Null }
    "== $target"
    foreach ($skill in $skills) {
        $source = Join-Path $skillsDir $skill
        $link = Join-Path $target $skill
        $item = Get-Item -LiteralPath $link -Force -ErrorAction SilentlyContinue
        if (-not $item) {
            if ($IsWindows) { New-Item -ItemType Junction -Path $link -Target $source | Out-Null }
            else { New-Item -ItemType SymbolicLink -Path $link -Target $source | Out-Null }
            "linked: $skill -> $source"
            continue
        }
        if (-not $item.LinkType) {
            "skipped: $skill is a real directory or file at $link; not replaced. Retire it yourself, then run this again."
            $skipped++
            continue
        }
        $points = $item.ResolveLinkTarget($true)
        $pointsTo = if ($points) { Get-RealPath $points.FullName } else { "$($item.Target)" }
        if ($pointsTo -eq (Get-RealPath $source)) {
            "already linked: $skill"
        } else {
            "skipped: $skill at $link points to $pointsTo, not $source; left alone."
            $skipped++
        }
    }
}
if ($skipped) { "$skipped skipped; see above."; exit 1 }
"all $($skills.Count) skills link to $skillsDir in $($targets.Count) folder(s)"
exit 0
