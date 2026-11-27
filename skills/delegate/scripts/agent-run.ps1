#Requires -Version 7.2
<#
.SYNOPSIS
Run one delegate on another harness's command line and report the result as one JSON object.

.DESCRIPTION
Start it as: pwsh -NoProfile -File <absolute path>/agent-run.ps1 ...
stdout carries exactly one JSON object:
  { status: ok|failed|timeout|unavailable|invalid-output|quota-exhausted, harness, model, sessionId,
    outFile, durationSec, exitCode, error }
Diagnostics go to stderr. The CLI's raw output is kept next to the out file as <OutFile>.log.
Exit code: 0 when status is ok, 2 for bad arguments, 1 otherwise.

-Role reads the role file. A coder role it leaves out (coder-mechanical, coder-simple,
coder-moderate, coder-complex, lowest first) runs as the next coder role above it that the
file has, fallback included; stderr says which. Any other missing role is unavailable.

This script never chooses or substitutes a model and never handles credentials.
See ../SKILL.md and ../references/<harness>-cli.md.
#>
[CmdletBinding()]
param(
    [string] $Role,
    [string] $HostHarness,
    [string] $Harness,
    [string] $Model,
    [string] $Effort,
    [string] $Mode = 'read-only',
    [string] $WorkDir,
    [string] $PromptFile,
    [string] $OutFile,
    [string] $SchemaFile,
    [string] $ResumeId,
    [string] $ReadDir,   # extra directories the delegate may read, separated like PATH
    [int] $TimeoutSec = 1800,
    [string] $RoleFile = (Join-Path $HOME '.agents/roles.json'),
    [switch] $Check,
    [switch] $Fallback
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
$GuardVariable = 'AGENT_SKILLS_DELEGATE'
$Harnesses = 'claude', 'codex', 'cursor'
$CoderRoles = 'coder-mechanical', 'coder-simple', 'coder-moderate', 'coder-complex'   # lowest first
$clock = [Diagnostics.Stopwatch]::StartNew()

# ---------------------------------------------------------------- result

$Result = [ordered]@{
    status = 'failed'; harness = $Harness; model = $Model; sessionId = ''
    outFile = $OutFile; durationSec = 0; exitCode = 0; error = ''
}

function Complete([string] $Status, [string] $ErrorText = '', [int] $ExitCode = -1) {
    $Result.status = $Status
    $Result.error = $ErrorText
    $Result.durationSec = [math]::Round($clock.Elapsed.TotalSeconds, 1)
    $Result | ConvertTo-Json -Compress
    if ($ExitCode -lt 0) { $ExitCode = if ($Status -eq 'ok') { 0 } else { 1 } }
    exit $ExitCode
}

function Fail-Arguments([string] $Text) { Complete 'failed' $Text 2 }

# ---------------------------------------------------------------- processes

function Resolve-Launcher([string] $Name) {
    # Get-Command finds .exe, .cmd and shell-script launchers; a .ps1 shim runs under pwsh.
    $cmd = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return @{ File = $cmd.Source; Prefix = @() } }
    $ps1 = Get-Command $Name -CommandType ExternalScript -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($ps1) { return @{ File = (Get-Process -Id $PID).Path; Prefix = @('-NoProfile', '-File', $ps1.Source) } }
    return $null
}

function Invoke-Launcher($Launcher, [string[]] $Arguments, [string] $Cwd, [string] $Stdin, [int] $Seconds) {
    $psi = [Diagnostics.ProcessStartInfo]::new($Launcher.File)
    foreach ($a in @($Launcher.Prefix) + @($Arguments)) { $psi.ArgumentList.Add($a) }
    $psi.WorkingDirectory = if ($Cwd) { $Cwd } else { (Get-Location).Path }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $utf8 = [Text.UTF8Encoding]::new($false)
    $psi.StandardInputEncoding = $utf8
    $psi.StandardOutputEncoding = $utf8
    $psi.StandardErrorEncoding = $utf8
    $psi.Environment[$GuardVariable] = '1'

    $p = [Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEndAsync()
    $err = $p.StandardError.ReadToEndAsync()
    try {
        if ($Stdin) { $p.StandardInput.Write($Stdin) }
        $p.StandardInput.Close()
    } catch [IO.IOException] { }   # the CLI exited without reading stdin

    $timedOut = -not $p.WaitForExit($Seconds * 1000)
    if ($timedOut) {
        try { $p.Kill($true) } catch { }
        $null = $p.WaitForExit(10000)
    } else {
        $p.WaitForExit()   # flush redirected output
    }
    $null = [Threading.Tasks.Task]::WaitAll(@($out, $err), 10000)
    @{
        ExitCode = if ($timedOut) { -1 } else { $p.ExitCode }
        TimedOut = $timedOut
        Stdout = if ($out.IsCompleted) { $out.Result } else { '' }
        Stderr = if ($err.IsCompleted) { $err.Result } else { '' }
    }
}

function ConvertFrom-JsonOrNull([string] $Text) {
    try { return $Text | ConvertFrom-Json -Depth 50 } catch { return $null }
}

function Get-Field($Object, [string] $Name) {
    if ($null -ne $Object -and $Object.PSObject.Properties[$Name]) { return $Object.$Name }
    return $null
}

# Only inspect provider errors and failed CLI diagnostics, never successful reply text.
function Test-QuotaMessage([string] $Message) {
    $prefix = '^(?:Error:\s*)?'
    $messageText = $Message.Trim()
    $messageText -match "${prefix}You(?:'|’)ve (?:hit|reached) your (?:usage|session|5-hour|weekly|Opus|Sonnet|Fable) limit\b" -or
        $messageText -match "${prefix}(?:You(?:'|’)ve hit your limit\s+·\s+resets|5-hour limit reached)\b" -or
        $messageText -match "${prefix}(?:Your workspace is out of credits\.|You hit your spend cap set in your workspace\.)"
}

function Test-QuotaError($ErrorObject, [string] $Message) {
    (Get-Field $ErrorObject 'code') -in 'usage_limit_reached', 'insufficient_quota' -or
        (Get-Field $ErrorObject 'type') -in 'usage_limit_reached', 'insufficient_quota' -or
        (Test-QuotaMessage $Message)
}

# ---------------------------------------------------------------- adapters
# One adapter per CLI. Each lists the flags it uses (checked by -Check), how to tell it is
# signed in, which models it offers, how to build a run, and how to read the result.

$ClaudeReadOnlyTools = 'Read,Grep,Glob,Bash'
$ClaudeReadOnlyCommands = 'Bash(git diff:*)', 'Bash(git log:*)', 'Bash(git show:*)', 'Bash(git status:*)', 'Bash(git rev-parse:*)'

$Adapters = @{
    claude = @{
        Command = 'claude'
        Help = @(@{ Args = @('--help'); Flags = @('-p', '--model', '--effort', '--permission-mode', '--tools',
                    '--allowedTools', '--output-format', '--json-schema', '--resume', '--add-dir') })
        SignedIn = {
            param($L)
            $r = Invoke-Launcher $L @('auth', 'status') $null '' 60
            $j = ConvertFrom-JsonOrNull $r.Stdout
            return ($r.ExitCode -eq 0 -and $j -and (Get-Field $j 'loggedIn') -eq $true)
        }
        Models = { param($L) $null }   # no model list; an unknown model fails the run
        Build = {
            param($C)
            $a = @('-p', '--output-format', 'json', '--model', $C.Model)
            if ($C.Effort) { $a += '--effort', $C.Effort }
            if ($C.ResumeId) { $a += '--resume', $C.ResumeId }
            if ($C.Schema) { $a += '--json-schema', $C.Schema }
            # Claude reads only inside its working directories: add the ones the brief points to.
            $a += @('--add-dir') + $C.ReadDirs
            if ($C.Mode -eq 'write') {
                # Write mode is full access on every CLI: edits, git, the network and Docker.
                $a += '--permission-mode', 'bypassPermissions'
            } else {
                $a += '--permission-mode', 'dontAsk', '--tools', $ClaudeReadOnlyTools, '--allowedTools'
                $a += $ClaudeReadOnlyCommands
            }
            @{ Args = $a; Cwd = $C.WorkDir; Stdin = $C.Prompt }
        }
        Parse = {
            param($C, $R)
            $j = $null
            foreach ($line in ($R.Stdout -split "`n")) {
                $candidate = ConvertFrom-JsonOrNull $line
                if ($candidate -and (Get-Field $candidate 'type') -eq 'result') { $j = $candidate }
            }
            if (-not $j) { return @{ Invalid = 'no JSON result on stdout' } }
            $model = ''
            $usage = Get-Field $j 'modelUsage'
            if ($usage) {
                $model = $usage.PSObject.Properties |
                    Sort-Object { [double](Get-Field $_.Value 'outputTokens') } -Descending |
                    Select-Object -First 1 -ExpandProperty Name
            }
            $message = [string](Get-Field $j 'result')
            $isError = (Get-Field $j 'is_error') -eq $true
            $text = $message
            $structured = Get-Field $j 'structured_output'
            if ($C.Schema) { $text = if ($null -ne $structured) { $structured | ConvertTo-Json -Depth 50 } else { '' } }
            @{ Text = $text; SessionId = [string](Get-Field $j 'session_id'); Model = $model
               Error = if ($isError) { "claude reported an error: $message" } else { '' }
               Quota = $isError -and (Test-QuotaError (Get-Field $j 'error') $message) }
        }
    }

    codex = @{
        Command = 'codex'
        Help = @(
            @{ Args = @('exec', '--help'); Flags = @('-m', '-s', '-C', '--json', '-o', '--output-schema', '-c', 'resume',
                    '--dangerously-bypass-approvals-and-sandbox') },
            @{ Args = @('exec', 'resume', '--help'); Flags = @('-m', '--json', '-o', '--output-schema', '-c',
                    '--dangerously-bypass-approvals-and-sandbox') })
        SignedIn = {
            param($L)
            $r = Invoke-Launcher $L @('login', 'status') $null '' 60
            return ($r.ExitCode -eq 0 -and "$($r.Stdout)$($r.Stderr)" -notmatch 'not logged in')
        }
        Models = {
            param($L)
            $r = Invoke-Launcher $L @('debug', 'models') $null '' 60
            $j = ConvertFrom-JsonOrNull $r.Stdout
            if (-not $j) { return $null }
            $list = if (Get-Field $j 'models') { $j.models } else { $j }
            @($list | ForEach-Object { Get-Field $_ 'slug' } | Where-Object { $_ })
        }
        Build = {
            param($C)
            # Write mode is full access. exec resume has no -s: set the read-only sandbox by config there.
            $access = if ($C.Mode -eq 'write') { @('--dangerously-bypass-approvals-and-sandbox') }
                      elseif ($C.ResumeId) { @('-c', 'sandbox_mode=read-only') }
                      else { @('-s', 'read-only') }
            $C.LastMessage = Join-Path ([IO.Path]::GetTempPath()) "agent-run-$([guid]::NewGuid().ToString('N')).txt"
            $common = @('--json', '-o', $C.LastMessage, '-m', $C.Model)
            if ($C.Effort) { $common += '-c', "model_reasoning_effort=$($C.Effort)" }
            if ($C.SchemaFile) { $common += '--output-schema', $C.SchemaFile }
            if ($C.ResumeId) {
                # exec resume has no -C: it runs in the work directory.
                $a = @('exec', 'resume') + $common + $access + @($C.ResumeId, '-')
            } else {
                $a = @('exec') + $common + $access + @('-C', $C.WorkDir, '-')
            }
            @{ Args = $a; Cwd = $C.WorkDir; Stdin = $C.Prompt }
        }
        Parse = {
            param($C, $R)
            $thread = ''; $failure = ''; $quota = $false
            foreach ($line in ($R.Stdout -split "`n")) {
                $e = ConvertFrom-JsonOrNull $line
                if (-not $e) { continue }
                switch (Get-Field $e 'type') {
                    'thread.started' { $thread = [string](Get-Field $e 'thread_id') }
                    'turn.failed' {
                        $failure = ($e | ConvertTo-Json -Compress -Depth 10)
                        $turnError = Get-Field $e 'error'
                        $quota = Test-QuotaError $turnError (Get-Field $turnError 'message')
                    }
                    'error' {
                        $failure = [string](Get-Field $e 'message')
                        $quota = Test-QuotaError $e $failure
                        if ($quota -and -not $failure) { $failure = ($e | ConvertTo-Json -Compress -Depth 10) }
                    }
                    'turn.completed' { $quota = $false }
                }
            }
            $text = if (Test-Path -LiteralPath $C.LastMessage) { Get-Content -LiteralPath $C.LastMessage -Raw } else { $null }
            Remove-Item -LiteralPath $C.LastMessage -ErrorAction SilentlyContinue
            if (-not $thread -and -not $text -and -not $quota) { return @{ Invalid = 'no session events and no final message' } }
            if ($null -eq $text -and -not $failure) { return @{ Invalid = 'no final message' } }
            @{ Text = [string]$text; SessionId = $(if ($thread) { $thread } else { $C.ResumeId }); Model = ''
               Error = $(if ($failure) { "codex reported a failure: $failure" } else { '' }); Quota = $quota }
        }
    }

    cursor = @{
        Command = 'cursor-agent'
        Help = @(@{ Args = @('--help'); Flags = @('-p', '--model', '--mode', '-f', '--sandbox', '--trust', '--workspace',
                    '--output-format', '--resume', '--list-models', '--add-dir') })
        SignedIn = {
            param($L)
            $r = Invoke-Launcher $L @('status') $null '' 60
            return ($r.ExitCode -eq 0 -and "$($r.Stdout)$($r.Stderr)" -notmatch 'not (logged|signed) in|unauthenticated')
        }
        Models = {
            param($L)
            $r = Invoke-Launcher $L @('--list-models') $null '' 60
            if ($r.ExitCode -ne 0) { return $null }
            @($r.Stdout -split "`n" | ForEach-Object { if ($_ -match '^\s*(\S+)\s+-\s') { $Matches[1] } })
        }
        Build = {
            param($C)
            $model = if ($C.Effort) { "$($C.Model)[effort=$($C.Effort)]" } else { $C.Model }
            $a = @('-p', '--output-format', 'json', '--trust', '--model', $model, '--workspace', $C.WorkDir)
            if ($C.ResumeId) { $a += '--resume', $C.ResumeId }
            foreach ($d in $C.ReadDirs) { $a += '--add-dir', $d }
            $a += if ($C.Mode -eq 'write') { @('-f', '--sandbox', 'disabled') } else { @('--mode', 'plan') }
            $prompt = $C.Prompt
            if ($C.Schema) {
                # Cursor has no schema flag: ask for the shape in the brief and validate afterwards.
                $prompt += "`n`nReply with only one JSON object, no other text, that validates against this JSON Schema:`n$($C.Schema)`n"
            }
            @{ Args = $a; Cwd = $C.WorkDir; Stdin = $prompt }
        }
        Parse = {
            param($C, $R)
            $j = $null
            foreach ($line in ($R.Stdout -split "`n")) {
                $candidate = ConvertFrom-JsonOrNull $line
                if ($candidate -and (Get-Field $candidate 'type') -eq 'result') { $j = $candidate }
            }
            if (-not $j) { return @{ Invalid = 'no JSON result on stdout' } }
            $message = [string](Get-Field $j 'result')
            $isError = (Get-Field $j 'is_error') -eq $true
            $text = $message
            if ($C.Schema -and $text -match '(?s)\{.*\}') { $text = $Matches[0] }
            @{ Text = $text; SessionId = [string](Get-Field $j 'session_id'); Model = ''
               Error = if ($isError) { "cursor reported an error: $message" } else { '' }
               Quota = $isError -and (Test-QuotaError (Get-Field $j 'error') $message) }
        }
    }
}

# ---------------------------------------------------------------- -Check

if ($Check) {
    $clis = foreach ($h in $Harnesses) {
        $ad = $Adapters[$h]
        $l = Resolve-Launcher $ad.Command
        if (-not $l) {
            [ordered]@{ harness = $h; command = $ad.Command; installed = $false; version = ''; missingFlags = @() }
            continue
        }
        $version = (Invoke-Launcher $l @('--version') $null '' 60).Stdout.Trim()
        $missing = foreach ($probe in $ad.Help) {
            $help = Invoke-Launcher $l $probe.Args $null '' 60
            $text = "$($help.Stdout)`n$($help.Stderr)"
            foreach ($flag in $probe.Flags) {
                if ($text -notmatch "(?m)(^|[\s,\[])$([regex]::Escape($flag))(?=$|[\s,=<\[])") { $flag }
            }
        }
        [ordered]@{ harness = $h; command = $ad.Command; installed = $true; version = $version
                    missingFlags = @($missing | Select-Object -Unique) }
    }
    $bad = @($clis | Where-Object { $_.missingFlags.Count -gt 0 })
    [ordered]@{ status = $(if ($bad) { 'failed' } else { 'ok' }); clis = @($clis) } | ConvertTo-Json -Compress -Depth 5
    exit $(if ($bad) { 1 } else { 0 })
}

# ---------------------------------------------------------------- arguments

if ([Environment]::GetEnvironmentVariable($GuardVariable)) {
    Complete 'failed' "$GuardVariable is set: this process is already a delegate and must not start another one."
}
if ($Mode -notin 'read-only', 'write') { Fail-Arguments "-Mode must be read-only or write, not '$Mode'." }
if (-not $WorkDir -or -not (Test-Path -LiteralPath $WorkDir -PathType Container)) { Fail-Arguments "-WorkDir '$WorkDir' is not a directory." }
if (-not $PromptFile -or -not (Test-Path -LiteralPath $PromptFile -PathType Leaf)) { Fail-Arguments "-PromptFile '$PromptFile' does not exist." }
if (-not $OutFile) { Fail-Arguments '-OutFile is required.' }
if ($SchemaFile -and -not (Test-Path -LiteralPath $SchemaFile -PathType Leaf)) { Fail-Arguments "-SchemaFile '$SchemaFile' does not exist." }
if ($HostHarness -and $HostHarness -notin $Harnesses) { Fail-Arguments "-HostHarness must be one of $($Harnesses -join ', ')." }
if ($Fallback -and (-not $Role -or $Harness -or $Model -or $Effort)) {
    Fail-Arguments '-Fallback needs -Role and cannot be combined with -Harness, -Model or -Effort.'
}
$WorkDir = (Resolve-Path -LiteralPath $WorkDir).Path
$Result.outFile = $OutFile

# The skills folder is always readable, so briefs can point at the standards and references.
$skillsRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).Path
$ReadDirs = @($skillsRoot)
# Skills reached through links (junctions, symlinks) live elsewhere; briefs may name either path.
foreach ($child in Get-ChildItem -LiteralPath $skillsRoot -Directory -ErrorAction SilentlyContinue) {
    if ($child.LinkType) {
        $real = $child.ResolveLinkTarget($true)
        if ($real -and $real.FullName -notin $ReadDirs) { $ReadDirs += $real.FullName }
    }
}
foreach ($d in ($ReadDir -split [regex]::Escape([IO.Path]::PathSeparator) | Where-Object { $_ })) {
    if (-not (Test-Path -LiteralPath $d -PathType Container)) { Fail-Arguments "-ReadDir '$d' is not a directory." }
    $ReadDirs += (Resolve-Path -LiteralPath $d).Path
}

if ($Role) {
    if (-not $HostHarness) { Fail-Arguments '-Role needs -HostHarness, to apply hostOverrides.' }
    if (-not (Test-Path -LiteralPath $RoleFile)) { Complete 'unavailable' "Role file '$RoleFile' not found." }
    $roles = ConvertFrom-JsonOrNull (Get-Content -LiteralPath $RoleFile -Raw)
    if (-not $roles) { Complete 'unavailable' "Role file '$RoleFile' is not valid JSON." }
    # A coder role the file leaves out runs as the next coder role above it that the file has.
    $tier = [array]::IndexOf($CoderRoles, $Role)
    $names = @(if ($tier -ge 0) { $CoderRoles[$tier..($CoderRoles.Count - 1)] } else { $Role })
    $entry = $null
    foreach ($name in $names) {
        # A host override replaces the whole role: effort levels belong to one harness.
        $entry = Get-Field (Get-Field (Get-Field $roles 'hostOverrides') $HostHarness) $name
        if ($null -eq $entry) { $entry = Get-Field (Get-Field $roles 'roles') $name }
        if ($null -eq $entry) { continue }
        if ($name -ne $Role) { [Console]::Error.WriteLine("agent-run: role '$Role' is not in '$RoleFile'; running it as '$name'.") }
        break
    }
    if ($Fallback) {
        $entry = Get-Field $entry 'fallback'
        if ((Get-Field $entry 'harness') -cnotin $Harnesses -or (Get-Field $entry 'model') -isnot [string] -or
            [string]::IsNullOrWhiteSpace((Get-Field $entry 'model'))) {
            Complete 'unavailable' "Role '$Role' on host '$HostHarness' has no valid fallback in '$RoleFile'."
        }
    }
    if (-not $Harness) { $Harness = [string](Get-Field $entry 'harness') }
    if (-not $Model) { $Model = [string](Get-Field $entry 'model') }
    if (-not $Effort) { $Effort = [string](Get-Field $entry 'effort') }
    $Result.harness = $Harness; $Result.model = $Model
    if (-not $Harness -or -not $Model) { Complete 'unavailable' "Role '$Role' on host '$HostHarness' has no harness and model in '$RoleFile'." }
}
if ($Harness -notin $Harnesses) { Fail-Arguments "-Harness must be one of $($Harnesses -join ', '), not '$Harness'." }
if (-not $Model) { Fail-Arguments 'Pass -Model or a -Role that sets one.' }

# ---------------------------------------------------------------- work directory guards

function Get-GitState([string] $Dir) {
    $top = git -C $Dir rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    $head = git -C $Dir rev-parse HEAD 2>$null
    $status = (git -C $Dir status --porcelain=v1 --untracked-files=all 2>$null) -join "`n"
    $diff = (git -C $Dir diff HEAD --binary 2>$null) -join "`n"
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($diff)))
    "$head`n$status`n$hash"
}

if ($Mode -eq 'write') {
    # Write mode runs only in a linked worktree, never in a main checkout.
    # Resolve the paths ourselves: --path-format=absolute needs git 2.31 or later.
    $dirs = @(git -C $WorkDir rev-parse --git-dir --git-common-dir 2>$null | ForEach-Object {
        [IO.Path]::GetFullPath($(if ([IO.Path]::IsPathRooted($_)) { $_ } else { Join-Path $WorkDir $_ })).TrimEnd('/', '\')
    })
    if ($LASTEXITCODE -ne 0 -or $dirs.Count -ne 2 -or $dirs[0] -eq $dirs[1]) {
        Complete 'failed' "Write mode needs a linked git worktree (git worktree add); '$WorkDir' is not one."
    }
}

# ---------------------------------------------------------------- run

$adapter = $Adapters[$Harness]
$launcher = Resolve-Launcher $adapter.Command
if (-not $launcher) { Complete 'unavailable' "$($adapter.Command) is not installed (not found on PATH)." }
if (-not (& $adapter.SignedIn $launcher)) { Complete 'unavailable' "$($adapter.Command) is not signed in. Sign in to it yourself; this script never handles credentials." }
$offered = & $adapter.Models $launcher
if ($null -ne $offered -and $Model -notin $offered) { Complete 'unavailable' "$($adapter.Command) does not offer model '$Model'." }

$context = @{
    Model = $Model; Effort = $Effort; Mode = $Mode; WorkDir = $WorkDir; ResumeId = $ResumeId; ReadDirs = $ReadDirs
    Prompt = Get-Content -LiteralPath $PromptFile -Raw
    SchemaFile = $(if ($SchemaFile) { (Resolve-Path -LiteralPath $SchemaFile).Path } else { '' })
    Schema = $(if ($SchemaFile) { (Get-Content -LiteralPath $SchemaFile -Raw | ConvertFrom-Json -Depth 50 | ConvertTo-Json -Depth 50 -Compress) } else { '' })
    LastMessage = ''
}
$before = if ($Mode -eq 'read-only') { Get-GitState $WorkDir } else { $null }
$run = & $adapter.Build $context
[Console]::Error.WriteLine("agent-run: $($adapter.Command) $($run.Args -join ' ')")
$r = Invoke-Launcher $launcher $run.Args $run.Cwd $run.Stdin $TimeoutSec
$Result.exitCode = $r.ExitCode

$outDir = Split-Path -Parent ([IO.Path]::GetFullPath($OutFile))
if ($outDir) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
Set-Content -LiteralPath "$OutFile.log" -Encoding utf8 -Value "# stdout`n$($r.Stdout)`n# stderr`n$($r.Stderr)"

if ($r.TimedOut) { Complete 'timeout' "No result after $TimeoutSec seconds; the process tree was killed." }

$parsed = & $adapter.Parse $context $r
if ($parsed.ContainsKey('Model') -and $parsed.Model) { $Result.model = $parsed.Model }
if ($parsed.ContainsKey('SessionId') -and $parsed.SessionId) { $Result.sessionId = $parsed.SessionId }
if ($parsed.ContainsKey('Text') -and $null -ne $parsed.Text) { Set-Content -LiteralPath $OutFile -Value $parsed.Text -Encoding utf8 -NoNewline }

$quota = $parsed.ContainsKey('Quota') -and $parsed.Quota
if (-not $quota -and $r.ExitCode -ne 0 -and -not $parsed.ContainsKey('Text')) {
    $quota = @($r.Stderr -split "`n" | Where-Object { Test-QuotaMessage $_ }).Count -gt 0
}
if ($quota) {
    if ($Mode -eq 'read-only' -and $null -ne $before -and (Get-GitState $WorkDir) -ne $before) {
        Complete 'failed' "The read-only delegate changed '$WorkDir'. Check git status there before trusting it."
    }
    Complete 'quota-exhausted' "$($adapter.Command) reported a usage quota limit. See '$OutFile.log'."
}

if ($r.ExitCode -ne 0) {
    $why = if ($parsed.ContainsKey('Error') -and $parsed.Error) { $parsed.Error }
           else { (($r.Stderr.Trim() -split "`n") | Select-Object -Last 5) -join ' ' }
    if ($why.Length -gt 600) { $why = $why.Substring(0, 600) + ' ...' }
    if ("$($r.Stderr)$($r.Stdout)" -match '(?i)cannot use this model|model\b.*\b(not (found|available|supported)|does not exist|invalid|unknown)') {
        Complete 'unavailable' "$($adapter.Command) rejected model '$Model': $why"
    }
    Complete 'failed' "$($adapter.Command) exited with $($r.ExitCode): $why"
}
if ($parsed.ContainsKey('Invalid')) { Complete 'invalid-output' $parsed.Invalid }
if ($parsed.Error) { Complete 'failed' $parsed.Error }

if ($parsed.Model -and $parsed.Model -notmatch [regex]::Escape($Model)) {
    Complete 'unavailable' "Asked for model '$Model' but $($adapter.Command) ran '$($parsed.Model)'. Not substituting."
}

if ($Mode -eq 'read-only' -and $null -ne $before -and (Get-GitState $WorkDir) -ne $before) {
    Complete 'failed' "The read-only delegate changed '$WorkDir'. Check git status there before trusting it."
}

if ($SchemaFile) {
    if (-not $parsed.Text -or -not (Test-Json -Json $parsed.Text -Schema (Get-Content -LiteralPath $SchemaFile -Raw) -ErrorAction SilentlyContinue)) {
        Complete 'invalid-output' 'The result does not validate against -SchemaFile.'
    }
}

Complete 'ok'
