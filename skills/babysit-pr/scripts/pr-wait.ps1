#Requires -Version 7.2
<#
.SYNOPSIS
Watch one GitHub pull request and print one line per real event.

.DESCRIPTION
pwsh -NoProfile -File <skill dir>/scripts/pr-wait.ps1 <pr number or URL>
     [-Repo owner/name] [-Until green|ready|any-change] [-IntervalSec 20]
     [-MaxWaitSec <n>] [-Once] [-GatingBots <names>] [-Json]

stdout carries one line per real event and nothing else; progress goes to stderr.
-Until
  green       the gating checks passed on the current head. Gating checks are the
              required checks; when none are required, or the rules cannot be read,
              every CI check gates.
  ready       green, every gating bot (-GatingBots, comma-separated, default none)
              reviewed the current head, no unresolved review thread, and the branch
              is not behind (default)
  any-change  stop after the first poll that prints an event
Exit codes
  0  the -Until condition is met on the current head, or the PR merged
  1  action needed: a gating check failed, conflicts, PR closed, ready blocked by
     unresolved threads or a branch that is behind, or GitHub stayed unreachable
  2  bad arguments, unknown PR, gh missing or signed out, or another watcher holds this PR
  3  still pending when -MaxWaitSec ran out, or after -Once. Run it again.

State lives in %LOCALAPPDATA%\pr-wait on Windows, $XDG_STATE_HOME/pr-wait or
~/.local/state/pr-wait elsewhere ($env:PR_WAIT_STATE_DIR overrides). The first run for
a PR records what exists and reports only what comes after; a restart reports what
arrived while nothing was watching. One watcher per PR, through an exclusive file lock
the operating system releases on exit.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)] [string] $Pr,
    [string] $Repo,
    [string] $Until = 'ready',
    [int] $IntervalSec = 20,
    [int] $MaxWaitSec = 0,
    [switch] $Once,
    [string] $GatingBots = '',
    [switch] $Json
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$StatusBots = 'github-actions', 'vercel', 'netlify', 'railway', 'cloudflare'
$StaleStateSeconds = 6 * 3600
$MaxFailedPolls = 10
$GhTimeoutSec = 60
$Backoff = if ($env:PR_WAIT_BACKOFF_SEC) { [double]$env:PR_WAIT_BACKOFF_SEC } else { 2 }
$Transient = '(?i)HTTP (5\d\d|429)|rate limit|timed? ?out|connection (reset|refused)|\bEOF\b|temporar|could not resolve host|TLS handshake|Something went wrong'
$RateLimit = '(?i)rate limit|HTTP 429'
$Rank = @{ fail = 4; cancel = 3; pending = 2; pass = 1; skipping = 0 }
$Gating = @($GatingBots -split ',' | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ })
$clock = [Diagnostics.Stopwatch]::StartNew()

function Write-Log([string] $Text) { [Console]::Error.WriteLine("pr-wait: $Text") }

function Stop-Early([string] $Text, [int] $Code = 2) {
    # Fatal messages go to stdout so a monitor shows the agent why it stopped.
    $line = if ($Json) { [ordered]@{ id = "error:$Code"; pr = $Pr; type = 'error'; text = $Text } | ConvertTo-Json -Compress }
            else { "pr-wait: $Text" }
    [Console]::Out.WriteLine($line)
    exit $Code
}

function Get-Field($Object, [string] $Name) {
    if ($null -ne $Object -and $Object -isnot [string] -and $Object.PSObject.Properties[$Name]) { return $Object.$Name }
    return $null
}

# ---------------------------------------------------------------- gh

class GhError : Exception {
    [bool] $Transient
    [bool] $NotFound
    GhError([string] $m, [bool] $t, [bool] $n) : base($m) { $this.Transient = $t; $this.NotFound = $n }
}

$GhLauncher = Get-Command gh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $GhLauncher) { Stop-Early 'gh is not installed (not found on PATH).' }

function Invoke-GhOnce([string[]] $Arguments) {
    $psi = [Diagnostics.ProcessStartInfo]::new($GhLauncher.Source)
    foreach ($a in $Arguments) { $psi.ArgumentList.Add($a) }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $psi.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    $psi.Environment['GH_PROMPT_DISABLED'] = '1'
    $p = [Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEndAsync()
    $err = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($GhTimeoutSec * 1000)) {
        try { $p.Kill($true) } catch { }
        return @{ Code = -1; Out = ''; Err = "gh timed out after $GhTimeoutSec s" }
    }
    $p.WaitForExit()
    @{ Code = $p.ExitCode; Out = $out.Result; Err = $err.Result }
}

# Run gh; retry transient failures with backoff, and back off longer on rate limits.
function Invoke-Gh([string[]] $Arguments) {
    $delay = $Backoff
    for ($attempt = 1; ; $attempt++) {
        $r = Invoke-GhOnce $Arguments
        if ($r.Code -eq 0) { return $r.Out }
        $lines = @($r.Err.Trim() -split "`n" | Where-Object { $_ })
        $message = if ($lines) { $lines[-1].Trim() } else { "gh exited $($r.Code)" }
        # A gh that died without saying why (a crash, a kill) is worth another try.
        $isTransient = ($r.Err -match $Transient) -or -not $r.Err.Trim()
        if (-not $isTransient -or $attempt -ge 5) {
            throw [GhError]::new($message, $isTransient, ($r.Err -match 'HTTP 404|Not Found'))
        }
        $wait = if ($r.Err -match $RateLimit) { $delay * 15 } else { $delay }
        Write-Log "gh $($Arguments[0..1] -join ' '): $message; retry in $([math]::Round($wait))s"
        Start-Sleep -Milliseconds ([int]($wait * 1000))
        $delay *= 2
    }
}

function Invoke-GhJson([string] $Path) { (Invoke-Gh @('api', $Path)) | ConvertFrom-Json -Depth 50 }

# Every page of a paginated endpoint, flattened. $Items names the list inside each page.
function Invoke-GhPages([string] $Path, [string] $Items = '') {
    $raw = Invoke-Gh @('api', '--paginate', '--slurp', $Path)
    $pages = $raw | ConvertFrom-Json -Depth 50 -NoEnumerate
    Expand-Pages $pages $Items
}

function Expand-Pages($Value, [string] $Items) {
    if ($null -eq $Value) { return }
    if ($Value -is [array]) { foreach ($v in $Value) { Expand-Pages $v $Items }; return }
    if ($Items -and $Value -isnot [string] -and $Value.PSObject.Properties[$Items]) {
        Expand-Pages $Value.$Items ''   # an empty list expands to nothing
        return
    }
    , $Value
}

# ---------------------------------------------------------------- arguments

if (-not $Pr -or -not $Pr.Trim()) { Stop-Early 'missing PR number. Did a variable expand to nothing? Usage: pr-wait.ps1 <pr> [-Repo owner/name]' }
if ($Until -notin 'green', 'ready', 'any-change') { Stop-Early "-Until must be green, ready or any-change, not '$Until'." }
if ($IntervalSec -lt 1) { $IntervalSec = 1 }
$number = 0
if ($Pr.Trim() -match '^https?://github\.com/([^/\s]+/[^/\s]+)/pull/(\d+)') {
    if (-not $Repo) { $Repo = $Matches[1] }
    $number = [int]$Matches[2]
} elseif ($Pr.Trim() -match '^#?(\d+)$') {
    $number = [int]$Matches[1]
} else {
    Stop-Early "'$Pr' is not a PR number or PR URL."
}
if ($number -le 0) { Stop-Early "'$Pr' is not a valid PR number." }

$auth = Invoke-GhOnce @('auth', 'status')
if ($auth.Code -ne 0) { Stop-Early 'gh is not signed in. Run `gh auth login` yourself; this script never handles credentials.' }
if (-not $Repo) {
    try { $Repo = ((Invoke-Gh @('repo', 'view', '--json', 'nameWithOwner')) | ConvertFrom-Json).nameWithOwner }
    catch { Stop-Early "no -Repo given and the current directory has no GitHub repo ($($_.Exception.Message))" }
}
if ($Repo -notmatch '^[\w.-]+/[\w.-]+$') { Stop-Early "'$Repo' is not owner/name." }

# ---------------------------------------------------------------- state and lock

$stateDir = if ($env:PR_WAIT_STATE_DIR) { $env:PR_WAIT_STATE_DIR }
            elseif ($IsWindows) { Join-Path $env:LOCALAPPDATA 'pr-wait' }
            elseif ($env:XDG_STATE_HOME) { Join-Path $env:XDG_STATE_HOME 'pr-wait' }
            else { Join-Path $HOME '.local/state/pr-wait' }
New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
$stem = Join-Path $stateDir "$($Repo -replace '/', '__')__$number"

try {
    # Held for the life of the process; the operating system releases it on exit.
    $script:Lock = [IO.File]::Open("$stem.lock", [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
} catch [IO.IOException] {
    $other = Get-Content -LiteralPath "$stem.pid" -ErrorAction SilentlyContinue
    if (-not $other) { $other = 'unknown' }
    Stop-Early "pid $other already watches $Repo#$number, so this watcher exits to avoid duplicate events. If no events reach you from it, stop pid $other and start again."
}
Set-Content -LiteralPath "$stem.pid" -Value $PID

$statePath = "$stem.json"
$state = $null
if ((Test-Path -LiteralPath $statePath) -and ((Get-Date) - (Get-Item -LiteralPath $statePath).LastWriteTime).TotalSeconds -lt $StaleStateSeconds) {
    try { $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable } catch { $state = $null }
}
$Baseline = $null -eq $state
if ($Baseline) { $state = @{ reported = @(); baseOid = $null; mergeState = $null } }
$Reported = [Collections.Generic.HashSet[string]]::new([string[]]@($state.reported))
$Printed = [Collections.Generic.HashSet[string]]::new()
$script:Events = 0

function Save-State {
    $state.reported = @($Reported)
    $tmp = "$statePath.tmp"
    Set-Content -LiteralPath $tmp -Value ($state | ConvertTo-Json -Depth 5 -Compress) -Encoding utf8
    [IO.File]::Move($tmp, $statePath, $true)
}

function Write-Line([string] $Id, [string] $Type, [string] $Text) {
    if (-not $Printed.Add($Text)) { return }
    # Straight to stdout: events must not become a function's return value.
    $line = if ($Json) { [ordered]@{ id = $Id; pr = $number; type = $Type; text = $Text } | ConvertTo-Json -Compress }
            else { "#$number $Text" }
    [Console]::Out.WriteLine($line)
}

# Print an event once per PR, across restarts. The first run only records.
function Send-Event([string] $Key, [string] $Type, [string] $Text) {
    if (-not $Reported.Add($Key)) { return }
    if (-not $Baseline) { $script:Events++; Write-Line $Key $Type $Text }
}

function Complete-Watch([int] $Code, [string] $Id, [string] $Type, [string] $Text, [switch] $Failed) {
    if ($Text) { Write-Line $Id $Type $Text }
    # A first run that never finished a poll has no baseline worth keeping: saving an
    # empty one would make the next run report everything that exists as new.
    if (-not ($Failed -and $Baseline)) { Save-State }
    exit $Code
}

# ---------------------------------------------------------------- reading GitHub

$script:Viewer = $null
$script:Required = $null

# Required checks for the base branch: known, none, or unknown (rules unreadable).
function Get-RequiredChecks([string] $Base) {
    $checks = [Collections.Generic.List[object]]::new()
    $unknown = @()
    try {
        foreach ($rule in @(Expand-Pages (Invoke-GhJson "repos/$Repo/rules/branches/$Base") '')) {
            if ((Get-Field $rule 'type') -ne 'required_status_checks') { continue }
            foreach ($c in @(Get-Field (Get-Field $rule 'parameters') 'required_status_checks')) {
                if ($c) { $checks.Add(@{ Name = $c.context; App = Get-Field $c 'integration_id' }) }
            }
        }
    } catch [GhError] {
        if (-not $_.Exception.NotFound) { $unknown += "rulesets: $($_.Exception.Message)" }
    }
    try {
        $classic = Invoke-GhJson "repos/$Repo/branches/$Base/protection/required_status_checks"
        $seen = @{}
        foreach ($c in @(Get-Field $classic 'checks')) {
            if ($c) { $checks.Add(@{ Name = $c.context; App = Get-Field $c 'app_id' }); $seen[$c.context] = $true }
        }
        foreach ($name in @(Get-Field $classic 'contexts')) {
            if ($name -and -not $seen[$name]) { $checks.Add(@{ Name = $name; App = $null }) }
        }
    } catch [GhError] {
        # "Branch not protected" and "Required status checks not enabled" mean none.
        if ($_.Exception.Message -notmatch 'not protected|not enabled') { $unknown += "branch protection: $($_.Exception.Message)" }
    }
    if ($unknown) { return @{ State = 'unknown'; Checks = @(); Why = ($unknown -join '; ') } }
    if ($checks.Count) { return @{ State = 'known'; Checks = @($checks); Why = '' } }
    @{ State = 'none'; Checks = @(); Why = '' }
}

function Get-Bucket([string] $Status, $Conclusion) {
    if ($Status -ne 'completed') { return 'pending' }
    switch ($Conclusion) {
        { $_ -in 'success', 'neutral' } { return 'pass' }
        'skipped' { return 'skipping' }
        'cancelled' { return 'cancel' }
        default { return 'fail' }
    }
}

# All checks on a commit: check runs and commit statuses.
function Get-Checks([string] $Sha) {
    $list = [Collections.Generic.List[object]]::new()
    foreach ($run in @(Invoke-GhPages "repos/$Repo/commits/$Sha/check-runs?per_page=100" 'check_runs')) {
        if (-not $run) { continue }
        $list.Add(@{ Name = $run.name; Bucket = (Get-Bucket $run.status (Get-Field $run 'conclusion'))
                     Link = Get-Field $run 'html_url'; App = Get-Field (Get-Field $run 'app') 'id' })
    }
    foreach ($s in @(Invoke-GhPages "repos/$Repo/commits/$Sha/status?per_page=100" 'statuses')) {
        if (-not $s) { continue }
        $bucket = switch ($s.state) { 'success' { 'pass' } 'pending' { 'pending' } default { 'fail' } }
        $list.Add(@{ Name = $s.context; Bucket = $bucket; Link = Get-Field $s 'target_url'; App = $null })
    }
    @($list)
}

function Get-Snapshot {
    # Every check, review and approval belongs to a head. If the head moves while we
    # read, the snapshot mixes two heads: discard it and read again.
    for ($try = 1; $try -le 3; $try++) {
        $pr = Invoke-GhJson "repos/$Repo/pulls/$number"
        if ((Get-Field $pr 'merged') -eq $true -or $pr.state -ne 'open') { return @{ Pr = $pr } }
        $head = $pr.head.sha
        $base = $pr.base.ref
        if ($null -eq $script:Required) {
            $script:Required = Get-RequiredChecks $base
            switch ($script:Required.State) {
                'known' { $g = ($script:Required.Checks | ForEach-Object { $_.Name }) -join ', ' }
                'none' { $g = 'none set, so every CI check gates' }
                default { $g = "unknown ($($script:Required.Why)), so every CI check gates" }
            }
            Write-Log "watching $Repo#$number until $Until; required checks: $g"
        }
        $snap = @{
            Pr = $pr; Head = $head; Base = $base
            Checks = Get-Checks $head
            Comments = @(Invoke-GhPages "repos/$Repo/issues/$number/comments?per_page=100")
            Reviews = @(Invoke-GhPages "repos/$Repo/pulls/$number/reviews?per_page=100")
            Threads = @(Get-Threads)
            BaseOid = (Invoke-GhJson "repos/$Repo/branches/$base").commit.sha
        }
        $again = Invoke-GhJson "repos/$Repo/pulls/$number"
        if ($again.head.sha -eq $head) { return $snap }
        Write-Log "head moved from $($head.Substring(0, 7)) to $($again.head.sha.Substring(0, 7)) during a poll; reading again"
    }
    throw [GhError]::new('the head kept moving during three reads', $true, $false)
}

$ThreadQuery = 'query($owner: String!, $name: String!, $number: Int!, $endCursor: String) { repository(owner: $owner, name: $name) { pullRequest(number: $number) { reviewThreads(first: 100, after: $endCursor) { pageInfo { hasNextPage endCursor } nodes { isResolved path line comments(first: 100) { nodes { id url body author { login } } } } } } } }'

function Get-Threads {
    $owner, $name = $Repo -split '/'
    $raw = Invoke-Gh @('api', 'graphql', '--paginate', '--slurp', '-f', "query=$ThreadQuery",
                       '-F', "owner=$owner", '-F', "name=$name", '-F', "number=$number")
    foreach ($page in @(Expand-Pages ($raw | ConvertFrom-Json -Depth 50 -NoEnumerate) '')) {
        $threads = Get-Field (Get-Field (Get-Field (Get-Field $page 'data') 'repository') 'pullRequest') 'reviewThreads'
        foreach ($t in @(Get-Field $threads 'nodes')) { if ($t) { , $t } }
    }
}

# ---------------------------------------------------------------- one poll

function Get-Snippet([string] $Body, [int] $Limit = 100) {
    $t = ($Body -replace '<!--[\s\S]*?-->', ' ' -replace '<[^>]+>', ' ' -replace '\s+', ' ').Trim()
    if ($t.Length -le $Limit) { return $t }
    $t.Substring(0, $Limit - 3) + '...'
}
function Get-BotName([string] $Text) {
    $l = "$Text".ToLowerInvariant()
    $Gating | Where-Object { $l.Contains($_) } | Select-Object -First 1
}
function Test-StatusBot([string] $Login) {
    $l = "$Login".ToLowerInvariant()
    [bool]($StatusBots | Where-Object { $l.Contains($_) })
}

$script:PrevSnapshot = $null

function Invoke-Poll {
    $snap = Get-Snapshot
    $pr = $snap.Pr
    $url = $pr.html_url
    if ((Get-Field $pr 'merged') -eq $true) { Complete-Watch 0 "final:merged" 'merged' "merged: $url" }
    if ($pr.state -ne 'open') { Complete-Watch 1 "final:closed" 'closed' "closed without merging: $url" }
    if (-not $script:Viewer) { $script:Viewer = (Invoke-GhJson 'user').login }

    $head = $snap.Head; $short = $head.Substring(0, 7); $base = $snap.Base
    $mine = @($pr.user.login, $script:Viewer)
    $script:Events = 0
    $req = $script:Required
    $unknownNote = if ($req.State -eq 'unknown') { ' (required checks unknown: gated on every CI check)' } else { '' }

    # Collapse duplicate names to the worst bucket.
    $byName = @{}
    foreach ($c in $snap.Checks) {
        $cur = $byName[$c.Name]
        if (-not $cur -or $Rank[$c.Bucket] -gt $Rank[$cur.Bucket]) { $byName[$c.Name] = $c }
    }
    # Gating checks: the required set (matched on the app where GitHub names one), else every CI check.
    $gate = @{}
    if ($req.State -eq 'known') {
        foreach ($r in $req.Checks) {
            $match = @($snap.Checks | Where-Object { $_.Name -eq $r.Name -and ($null -eq $r.App -or $r.App -eq -1 -or $_.App -eq $r.App) })
            $worst = $match | Sort-Object { $Rank[$_.Bucket] } -Descending | Select-Object -First 1
            $gate[$r.Name] = if ($worst) { $worst } else { @{ Name = $r.Name; Bucket = 'pending'; Link = '' } }
        }
    } else {
        foreach ($k in $byName.Keys) { if (-not (Get-BotName $k)) { $gate[$k] = $byName[$k] } }
    }
    $label = if ($req.State -eq 'known') { 'required check' } else { 'check' }
    $failLines = @()
    foreach ($name in ($gate.Keys | Sort-Object)) {
        $c = $gate[$name]
        if ($c.Bucket -in 'fail', 'cancel') {
            $line = "$label failed: $name $($c.Link)".Trim()
            $failLines += $line
            Send-Event "fail:${head}:${name}:$($c.Link)" 'check-failed' $line
        }
    }
    $gateDone = $gate.Count -gt 0 -and -not @($gate.Values | Where-Object { $_.Bucket -eq 'pending' })
    $allDone = $gateDone -and -not @($byName.Values | Where-Object { $_.Bucket -eq 'pending' })
    $fingerprint = ($byName.Keys | Sort-Object | ForEach-Object { "$_=$($byName[$_].Bucket)" }) -join ';'
    # Checks register a few seconds after a push: when watching, two identical polls
    # in a row guard against calling a half-registered set finished.
    $stable = $Once -or $fingerprint -eq $script:PrevSnapshot
    $script:PrevSnapshot = $fingerprint
    $green = $gateDone -and $stable -and -not $failLines

    # People talking. Comment edits are never events.
    foreach ($c in $snap.Comments) {
        $login = $c.user.login
        if ($login -in $mine -or (Get-BotName $login) -or (Test-StatusBot $login)) { continue }
        Send-Event "c:$($c.id)" 'comment' "comment from ${login}: $(Get-Snippet $c.body) $($c.html_url)"
    }
    foreach ($r in $snap.Reviews) {
        $login = $r.user.login
        if ($login -in $mine -or (Get-BotName $login) -or (Test-StatusBot $login)) { continue }
        if ($r.state -in 'APPROVED', 'CHANGES_REQUESTED' -or "$($r.body)".Trim()) {
            $st = $r.state.ToLowerInvariant().Replace('_', ' ')
            Send-Event "r:$($r.id)" 'review' "review from $login ($st): $(Get-Snippet $r.body) $($r.html_url)"
        }
    }
    $unresolved = @()
    foreach ($t in $snap.Threads) {
        $nodes = @(Get-Field (Get-Field $t 'comments') 'nodes')
        if (-not $t.isResolved -and $nodes) { $unresolved += $nodes[0].url }
        $where = if (Get-Field $t 'line') { "$($t.path):$($t.line)" } else { $t.path }
        for ($i = 0; $i -lt $nodes.Count; $i++) {
            $login = Get-Field (Get-Field $nodes[$i] 'author') 'login'
            if ($login -in $mine) { continue }
            $kind = if ($i -eq 0) { 'new thread' } else { 'thread reply' }
            Send-Event "t:$($nodes[$i].id)" 'thread' "$kind from $login on ${where}: $(Get-Snippet $nodes[$i].body) $($nodes[$i].url)"
        }
    }

    # Gating bots on the current head: a review of the head commit, its own checks
    # finished, or a summary comment that names the head.
    $reviewed = @()
    foreach ($bot in $Gating) {
        $own = @($snap.Checks | Where-Object { (Get-BotName $_.Name) -eq $bot })
        $onHead = @($snap.Reviews | Where-Object { "$($_.user.login)".ToLowerInvariant().Contains($bot) -and $_.commit_id -eq $head })
        $summary = @($snap.Comments | Where-Object { "$($_.user.login)".ToLowerInvariant().Contains($bot) -and "$($_.body)".Contains($short) })
        $done = if ($own) { -not @($own | Where-Object { $_.Bucket -eq 'pending' }) } else { [bool]($onHead -or $summary) }
        if ($done) {
            $reviewed += $bot
            Send-Event "bot:${bot}:$head" 'bot' "$bot finished on $short"
        }
    }

    # Base branch and merge state.
    $oldBase = $state.baseOid
    if ($snap.BaseOid -and $oldBase -and $snap.BaseOid -ne $oldBase -and -not $Baseline) {
        try {
            $mineFiles = @(Invoke-GhPages "repos/$Repo/pulls/$number/files?per_page=100" | ForEach-Object { $_.filename })
            $moved = @((Invoke-GhJson "repos/$Repo/compare/$oldBase...$($snap.BaseOid)").files | ForEach-Object { $_.filename })
            $touched = @($mineFiles | Where-Object { $_ -in $moved } | Sort-Object)
            if ($touched) {
                $more = if ($touched.Count -gt 5) { " and $($touched.Count - 5) more" } else { '' }
                Send-Event "base:$($snap.BaseOid)" 'base-moved' "$base moved to $($snap.BaseOid.Substring(0, 7)) and touches files in this PR: $(($touched | Select-Object -First 5) -join ', ')$more"
            }
        } catch [GhError] { Write-Log "could not compare base commits: $($_.Exception.Message)" }
    }
    if ($snap.BaseOid) { $state.baseOid = $snap.BaseOid }
    $mergeState = "$($pr.mergeable_state)".ToUpperInvariant()
    $dirtyLine = "merge state is DIRTY: the branch conflicts with $base, rebase it"
    $behindLine = "merge state is BEHIND: update the branch from $base before merging"
    if ($mergeState -in 'BEHIND', 'DIRTY' -and $state.mergeState -ne $mergeState) {
        Send-Event "merge:${mergeState}:${head}:$($snap.BaseOid)" 'merge-state' $(if ($mergeState -eq 'DIRTY') { $dirtyLine } else { $behindLine })
    }
    if ($mergeState -and $mergeState -ne 'UNKNOWN') { $state.mergeState = $mergeState }

    # Summary for the checks line and the final lines.
    $counts = $byName.Values | Group-Object { $_.Bucket } | Sort-Object Name | ForEach-Object { "$($_.Count) $($_.Name)" }
    $parts = @(($counts -join ', '))
    if ($req.State -eq 'known') {
        $ok = @($gate.Values | Where-Object { $_.Bucket -in 'pass', 'skipping' }).Count
        $parts += "required $ok/$($gate.Count) green"
    }
    if ($Gating) { $parts += "bots reviewed: $(if ($reviewed) { $reviewed -join ', ' } else { 'none yet' })" }
    $parts += "$($unresolved.Count) unresolved threads", "merge state $mergeState"
    $summary = ($parts | Where-Object { $_ }) -join '; '

    if ($Until -ne 'any-change') {
        if ($mergeState -eq 'DIRTY') { Complete-Watch 1 "final:dirty:$head" 'blocked' $dirtyLine }
        if ($failLines) { Complete-Watch 1 "final:failed:$head" 'failed' "$($failLines[-1])$unknownNote" }
        if ($green -and $Until -eq 'green') {
            $null = $Reported.Add("checks:$head")
            Complete-Watch 0 "final:green:$head" 'green' "green on ${short}: $summary$unknownNote"
        }
        if ($green -and $Until -eq 'ready' -and $reviewed.Count -eq $Gating.Count) {
            if ($unresolved) { Complete-Watch 1 "final:threads:$head" 'blocked' "blocked by $($unresolved.Count) unresolved threads on ${short}: $($unresolved -join ' ')" }
            if ($mergeState -eq 'BEHIND') { Complete-Watch 1 "final:behind:$head" 'blocked' $behindLine }
            $null = $Reported.Add("checks:$head")
            Complete-Watch 0 "final:ready:$head" 'ready' "ready on ${short}: $summary$unknownNote"
        }
    }
    if ($allDone -and ($stable -or $Baseline)) { Send-Event "checks:$head" 'checks-finished' "checks finished on ${short}: $summary" }
    if ($Until -eq 'any-change' -and $script:Events) { Complete-Watch 0 '' '' '' }
    return "still pending on ${short}: $summary$unknownNote"
}

# ---------------------------------------------------------------- loop

$failures = 0
$firstPoll = $true
while ($true) {
    $pending = 'still pending'
    try {
        $pending = Invoke-Poll
        $failures = 0
        Save-State
        if ($Baseline) { Write-Log "baseline recorded for $Repo#$number; reporting only new events" }
        $Baseline = $false
    } catch [GhError] {
        $e = $_.Exception
        if ($firstPoll -and $e.NotFound) { Stop-Early "cannot read $Repo#${number}: $($e.Message)" }
        if (-not $e.Transient) { Complete-Watch 1 'final:error' 'error' "pr-wait stopped: $($e.Message)" -Failed }
        $failures++
        Write-Log "poll failed ($failures/$MaxFailedPolls): $($e.Message)"
        if ($failures -ge $MaxFailedPolls) { Complete-Watch 1 'final:unreachable' 'error' "pr-wait stopped: GitHub unreachable for $failures polls: $($e.Message)" -Failed }
    }
    $firstPoll = $false
    $elapsed = $clock.Elapsed.TotalSeconds
    if ($Once -or ($MaxWaitSec -gt 0 -and $elapsed + $IntervalSec -gt $MaxWaitSec)) {
        Complete-Watch 3 'final:pending' 'pending' "$pending after $([math]::Round($elapsed))s; run pr-wait again" -Failed:$Baseline
    }
    Start-Sleep -Seconds $IntervalSec
}
