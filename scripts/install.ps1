#Requires -Version 7.2
<#
.SYNOPSIS
Link every skill in this repository into the folders the harnesses read, and set up the
role file (Windows).

.DESCRIPTION
pwsh -NoProfile -File <repository>/scripts/install.ps1 [target folder ...]
pwsh -NoProfile -File <repository>/scripts/install.ps1 -Roles

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

Then the role file, ~/.agents/roles.json, which tells the delegate skill which harness,
model and effort runs each role. When it is missing and this runs in a terminal, it offers
to ask for each role and write the file; it offers the models in models.txt, next to this
script, by number, and takes any other model typed. -Roles asks again, with the current values as
defaults, and does nothing else: use it to change models later. The file is written only
after you confirm it, and the previous version is kept as roles.json.bak. Keys the
questions do not cover (such as $comment) are kept.

Exit code: 0 when every skill is linked in every target, 1 when any was skipped or the
role file is not valid JSON, 2 when the questions could not be asked or answered.
#>
[CmdletBinding()]
param(
    # Ask for the roles again and rewrite ~/.agents/roles.json; link nothing.
    [switch] $Roles,
    [Parameter(ValueFromRemainingArguments)] [string[]] $Targets
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$repo = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$skillsDir = Join-Path $repo 'skills'
$roleFile = Join-Path $HOME '.agents/roles.json'
$roleNames = [ordered]@{
    'planner'       = 'writes the plan; read-only'
    'coder-simple'  = 'codes tasks the plan pins down: few files, an existing pattern'
    'coder-complex' = 'codes the hard tasks: concurrency, invariants, migrations, security'
    'reviewer'      = 'reviews diffs; read-only'
    'council-a'     = 'first of two independent reviewers'
    'council-b'     = 'second reviewer; a model from a different provider than council-a'
}
$harnesses = 'claude', 'codex', 'cursor'
# The models offered per harness, from models.txt ("<harness> <model>" lines) next to this script.
$models = @{}
$modelsFile = Join-Path $PSScriptRoot 'models.txt'
if (Test-Path -LiteralPath $modelsFile) {
    foreach ($line in Get-Content -LiteralPath $modelsFile) {
        $f = @(-split $line)
        if ($f.Count -lt 2 -or $f[0].StartsWith('#')) { continue }
        if (-not $models.Contains($f[0])) { $models[$f[0]] = [Collections.Generic.List[string]]::new() }
        $models[$f[0]].Add($f[1])
    }
}
$modelHints = @{
    claude = 'Claude Code shows them in /model'
    codex  = '`codex debug models` lists them'
    cursor = '`cursor-agent --list-models` lists them'
}
$newComment = 'Role file for the delegate skill. install.ps1 -Roles (Windows) or install.sh --roles (Linux, macOS) asks again to change it; the shape is in skills/delegate/roles.example.json.'

function Say([string] $Text) { [Console]::Out.WriteLine($Text) }
# Questions are asked only of someone at a terminal (INSTALL_ROLES_PROMPT=1 forces them, for the tests).
function Test-CanAsk { $env:INSTALL_ROLES_PROMPT -eq '1' -or -not [Console]::IsInputRedirected }
function Read-Answer([string] $Prompt) {
    [Console]::Out.Write($Prompt)
    $line = [Console]::In.ReadLine()
    if ($null -eq $line) { Say ''; Say "Input ended; $roleFile left as it was."; exit 2 }
    $line.Trim()
}
# Enter keeps the current value; - clears it.
function Read-Value([string] $Label, [string] $Current) {
    $a = Read-Answer $(if ($Current) { "  ${Label} [$Current]: " } else { "  ${Label}: " })
    if ($a -eq '') { return $Current }
    if ($a -eq '-') { return '' }
    $a
}
function Read-YesNo([string] $Question, [bool] $Default) {
    $a = Read-Answer "$Question $(if ($Default) { '[Y/n]' } else { '[y/N]' }) "
    if (-not $a) { return $Default }
    $a -match '^(y|yes)$'
}
function Get-Prop($Object, [string] $Name) {
    if ($Object -is [psobject] -and $Object.PSObject.Properties[$Name]) { $Object.PSObject.Properties[$Name].Value }
}
# Asks for one role's harness, model and effort; returns the entry, or $null for none.
function Read-Entry($Current, [string] $NoneMeans) {
    $curH = "$(Get-Prop $Current 'harness')"
    while ($true) {
        $h = Read-Value 'harness' $curH
        if (-not $h -or $h -in $harnesses) { break }
        Say "  harness is claude, codex or cursor; - leaves the role $NoneMeans."
    }
    if (-not $h) { return $null }
    # A model and an effort belong to one harness: offer them only when it is unchanged.
    $same = $h -eq $curH
    # Offer the listed models by number; anything else typed is taken as the model, exactly.
    $list = @(if ($models.Contains($h)) { $models[$h] })
    if ($list.Count) {
        $cells = @(for ($i = 0; $i -lt $list.Count; $i++) { ('{0,4}) {1}' -f ($i + 1), $list[$i]).PadRight(34) })
        for ($i = 0; $i -lt $cells.Count; $i += 3) { Say ('  ' + ($cells[$i..([Math]::Min($i + 2, $cells.Count - 1))] -join '')).TrimEnd() }
        Say "  Pick a number, or type another model exactly as $h takes it ($($modelHints[$h]))."
    } else {
        Say "  Type the model exactly as $h takes it ($($modelHints[$h]))."
    }
    while ($true) {
        $m = Read-Value 'model' $(if ($same) { "$(Get-Prop $Current 'model')" } else { '' })
        if ($list.Count -and $m -match '^\d+$') {
            $n = [int]$m
            if ($n -ge 1 -and $n -le $list.Count) { $m = $list[$n - 1]; Say "  -> $m"; break }
            Say "  there is no $m in the list: pick 1 to $($list.Count), or type the model."
            continue
        }
        if ($m) { break }
        Say '  a model is needed: pick one from the list, or type it.'
    }
    # Cursor models carry their effort in the name (cursor-grok-4.5-high), so none is asked.
    $e = if ($h -eq 'cursor') { '' } else { Read-Value 'effort (optional)' $(if ($same) { "$(Get-Prop $Current 'effort')" } else { '' }) }
    $entry = [ordered]@{ harness = $h; model = $m }
    if ($e) { $entry.effort = $e }
    $entry
}

# Asks for every role, shows the result and writes it on a yes. Returns the exit code.
function Invoke-RoleSetup {
    $doc = $null
    if (Test-Path -LiteralPath $roleFile) {
        try { $doc = Get-Content -LiteralPath $roleFile -Raw | ConvertFrom-Json } catch { $doc = $null }
        if ($doc -isnot [pscustomobject]) { Say "roles: $roleFile is not a JSON object; fix or move it, then run this again."; return 1 }
    }
    Say ''
    Say "Roles for the delegate skill, saved in $roleFile."
    Say 'For each role: the harness (claude, codex or cursor), the model (pick one from the list,'
    Say 'or type it exactly as that harness takes it: nothing translates a display name), and an'
    Say 'effort level if you want one (not for cursor: its models carry the effort in the name).'
    Say 'Enter keeps the value in [brackets]; - clears it. A role with no harness is unavailable:'
    Say 'skills stop and ask instead of picking a model.'
    $oldRoles = Get-Prop $doc 'roles'
    $newRoles = [ordered]@{}
    foreach ($role in $roleNames.Keys) {
        Say ''
        Say "${role}: $($roleNames[$role])"
        $entry = Read-Entry (Get-Prop $oldRoles $role) 'unavailable'
        if ($entry) { $newRoles[$role] = $entry }
    }

    Say ''
    Say 'A host override replaces a role when that harness runs the session, for example other'
    Say 'models when Cursor is the host. Enter on an empty [] means no override for that role.'
    $oldOv = Get-Prop $doc 'hostOverrides'
    $newOv = [ordered]@{}
    if ($oldOv -is [pscustomobject]) {
        foreach ($p in $oldOv.PSObject.Properties) { if ($p.Name -notin $harnesses) { $newOv[$p.Name] = $p.Value } }
    }
    foreach ($h in $harnesses) {
        $cur = Get-Prop $oldOv $h
        $has = $cur -is [pscustomobject] -and @($cur.PSObject.Properties).Count -gt 0
        Say ''
        if (-not (Read-YesNo "Different roles when $h runs the session?" $has)) { continue }
        $hostRoles = [ordered]@{}
        foreach ($role in $roleNames.Keys) {
            Say "  $role"
            $entry = Read-Entry (Get-Prop $cur $role) 'without an override'
            if ($entry) { $hostRoles[$role] = $entry }
        }
        if ($hostRoles.Count) { $newOv[$h] = $hostRoles }
    }

    # Keep every other key, in place; roles and hostOverrides go where they were.
    $out = [ordered]@{}
    if (-not $doc) { $out['$comment'] = $newComment }
    else {
        foreach ($p in $doc.PSObject.Properties) {
            if ($p.Name -eq 'roles') { $out.roles = $newRoles }
            elseif ($p.Name -eq 'hostOverrides') { if ($newOv.Count) { $out.hostOverrides = $newOv } }
            else { $out[$p.Name] = $p.Value }
        }
    }
    if (-not $out.Contains('roles')) { $out.roles = $newRoles }
    if ($newOv.Count -and -not $out.Contains('hostOverrides')) { $out.hostOverrides = $newOv }
    $json = $out | ConvertTo-Json -Depth 20

    Say ''
    Say $json
    if (-not (Read-YesNo "Write it to ${roleFile}?" $true)) { Say "Not written; $roleFile left as it was."; return 0 }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $roleFile) | Out-Null
    $kept = ''
    if (Test-Path -LiteralPath $roleFile) {
        Copy-Item -LiteralPath $roleFile -Destination "$roleFile.bak" -Force
        $kept = "; the previous version is in $roleFile.bak"
    }
    Set-Content -LiteralPath "$roleFile.tmp" -Value $json
    Move-Item -LiteralPath "$roleFile.tmp" -Destination $roleFile -Force
    Say "roles: wrote $roleFile$kept."
    0
}

if ($Roles) {
    if (-not (Test-CanAsk)) { "roles: the questions need a terminal; run install.ps1 -Roles in one."; exit 2 }
    exit (Invoke-RoleSetup)
}

$skills = @(Get-ChildItem -LiteralPath $skillsDir -Directory | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'SKILL.md') } | ForEach-Object Name)
$targets = @(if ($Targets) { $Targets } else { (Join-Path $HOME '.claude/skills'), (Join-Path $HOME '.agents/skills') })

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
$code = 0
if ($skipped) { "$skipped skipped; see above."; $code = 1 }
else { "all $($skills.Count) skills link to $skillsDir in $($targets.Count) folder(s)" }

if (Test-Path -LiteralPath $roleFile) {
    "roles: $roleFile is set up; install.ps1 -Roles asks again to change it."
} elseif (-not (Test-CanAsk)) {
    "roles: no role file at $roleFile, so the delegate skill has no models. Run install.ps1 -Roles in a terminal to make one."
} elseif (Read-YesNo "No role file at $roleFile, so the delegate skill has no models. Set it up now?" $true) {
    $r = Invoke-RoleSetup
    if ($r -and -not $code) { $code = $r }
} else {
    "roles: not set up; install.ps1 -Roles asks later."
}
exit $code
