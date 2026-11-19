#Requires -Version 7.2
# Pester 5 tests for babysit-pr/scripts/pr-wait.ps1, run against a fake gh that replays fixtures.

BeforeAll {
    $script:PrWait = (Resolve-Path (Join-Path $PSScriptRoot '../skills/babysit-pr/scripts/pr-wait.ps1')).Path
    $script:FakeGh = (Resolve-Path (Join-Path $PSScriptRoot 'fakes/fake-gh.ps1')).Path
    $script:Pwsh = (Get-Process -Id $PID).Path
    $script:Root = Join-Path ([IO.Path]::GetTempPath()) "pr wait tests $([guid]::NewGuid().ToString('N').Substring(0, 8))"
    $script:Bin = Join-Path $Root 'fake bin'
    New-Item -ItemType Directory -Force $Bin | Out-Null
    if ($IsWindows) {
        Set-Content -LiteralPath (Join-Path $Bin 'gh.cmd') -Encoding ascii -Value "@`"$Pwsh`" -NoProfile -File `"$FakeGh`" %*"
    } else {
        $p = Join-Path $Bin 'gh'
        Set-Content -LiteralPath $p -Value "#!/bin/sh`nexec `"$Pwsh`" -NoProfile -File `"$FakeGh`" `"`$@`""
        chmod +x $p
    }

    $script:HeadA = 'aaaaaaa1111111111111111111111111111111111'
    $script:HeadB = 'bbbbbbb2222222222222222222222222222222222'
    $script:Base1 = 'ccccccc3333333333333333333333333333333333'

    function script:Write-Fixture([string] $Dir, [string] $Key, $Value, [int] $Seq = 0, [switch] $Err) {
        $ext = if ($Err) { 'err' } else { 'json' }
        $name = if ($Seq -gt 0) { "$Key.$Seq.$ext" } else { "$Key.$ext" }
        $text = if ($Err -or $Value -is [string]) { [string]$Value } else { ConvertTo-Json -InputObject $Value -Depth 20 }
        Set-Content -LiteralPath (Join-Path $Dir $name) -Value $text -NoNewline
    }

    function script:Pr([string] $Head = $HeadA, [string] $State = 'open', [bool] $Merged = $false, [string] $Mergeable = 'clean') {
        @{ number = 7; state = $State; merged = $Merged; html_url = 'https://github.com/o/r/pull/7'
           head = @{ sha = $Head }; base = @{ ref = 'main' }; user = @{ login = 'author' }; mergeable_state = $Mergeable }
    }
    function script:Run([string] $Name, [string] $Bucket = 'success', [int] $AppId = 15368) {
        $status = if ($Bucket -eq 'pending') { 'in_progress' } else { 'completed' }
        $conclusion = if ($Bucket -eq 'pending') { $null } else { $Bucket }
        @{ name = $Name; status = $status; conclusion = $conclusion; html_url = "https://ci.example/$Name"; app = @{ id = $AppId; slug = 'github-actions' } }
    }
    function script:CheckPages([object[]] $Runs) { , @(, @{ total_count = $Runs.Count; check_runs = @($Runs) }) }
    function script:Comment([int] $Id, [string] $Login = 'bob', [string] $Body = 'please look') {
        @{ id = $Id; user = @{ login = $Login; type = 'User' }; body = $Body; html_url = "https://github.com/o/r/pull/7#c$Id" }
    }
    function script:Threads([object[]] $Nodes = @()) {
        , @(, @{ data = @{ repository = @{ pullRequest = @{ reviewThreads = @{
            pageInfo = @{ hasNextPage = $false; endCursor = $null }; nodes = @($Nodes) } } } } })
    }

    # An open PR at HeadA with one passing CI check, no protection, nothing said yet.
    function script:New-Scenario {
        $d = Join-Path $Root "scenario $([guid]::NewGuid().ToString('N').Substring(0, 6))"
        New-Item -ItemType Directory -Force $d | Out-Null
        Write-Fixture $d 'auth_status' 'Logged in'
        Write-Fixture $d 'user' @{ login = 'me' }
        Write-Fixture $d 'repos_o_r_pulls_7' (Pr)
        Write-Fixture $d 'repos_o_r_branches_main' @{ commit = @{ sha = $Base1 } }
        Write-Fixture $d 'repos_o_r_rules_branches_main' '[]'
        Write-Fixture $d 'repos_o_r_branches_main_protection_required_status_checks' 'gh: Branch not protected (HTTP 404)' -Err
        Write-Fixture $d "repos_o_r_commits_$($HeadA)_check-runs" (CheckPages @(Run 'build'))
        Write-Fixture $d "repos_o_r_commits_$($HeadA)_status" (, @(, @{ state = 'success'; statuses = @() }))
        Write-Fixture $d "repos_o_r_commits_$($HeadB)_check-runs" (CheckPages @(Run 'build'))
        Write-Fixture $d "repos_o_r_commits_$($HeadB)_status" (, @(, @{ state = 'success'; statuses = @() }))
        Write-Fixture $d 'repos_o_r_issues_7_comments' (, @(, @()))
        Write-Fixture $d 'repos_o_r_pulls_7_reviews' (, @(, @()))
        Write-Fixture $d 'repos_o_r_pulls_7_files' (, @(, @(@{ filename = 'src/a.js' })))
        Write-Fixture $d 'graphql' (Threads)
        $d
    }

    function script:Invoke-PrWait([string] $Scenario, [string[]] $Arguments, [string] $StateDir) {
        if (-not $StateDir) { $StateDir = Join-Path $Scenario 'state dir' }
        $sep = [IO.Path]::PathSeparator
        $path = @($Bin) + $(if ($IsWindows) { @("$env:SystemRoot\System32") } else { @('/usr/bin', '/bin') })
        $vars = @{ PATH = ($path -join $sep); FAKE_GH_DIR = $Scenario; FAKE_GH_LOG = (Join-Path $Scenario 'calls.log')
                   PR_WAIT_STATE_DIR = $StateDir; PR_WAIT_BACKOFF_SEC = '0' }
        $saved = @{}
        foreach ($k in $vars.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $vars[$k]) }
        try {
            $errFile = Join-Path $Scenario 'stderr.txt'
            $out = & $Pwsh -NoProfile -File $PrWait @Arguments 2>$errFile
            $code = $LASTEXITCODE
        } finally {
            foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
        }
        [pscustomobject]@{ Out = @($out | Where-Object { $_ -ne '' }); Code = $code
                           Err = (Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue) }
    }
}

AfterAll { if (-not $env:KEEP_TEST_FILES) { Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue } }

Describe 'bad arguments' {
    It 'exits 2 without a PR' {
        (Invoke-PrWait (New-Scenario) @('-Repo', 'o/r', '-Once')).Code | Should -Be 2
    }
    It 'exits 2 for something that is not a PR' {
        (Invoke-PrWait (New-Scenario) @('seven', '-Repo', 'o/r', '-Once')).Code | Should -Be 2
    }
    It 'exits 2 for an unknown PR' {
        $s = New-Scenario
        Remove-Item -LiteralPath (Join-Path $s 'repos_o_r_pulls_7.json')
        Write-Fixture $s 'repos_o_r_pulls_7' 'gh: Not Found (HTTP 404)' -Err
        (Invoke-PrWait $s @('7', '-Repo', 'o/r', '-Once')).Code | Should -Be 2
    }
    It 'takes the repository from a PR URL' {
        $r = Invoke-PrWait (New-Scenario) @('https://github.com/o/r/pull/7', '-Until', 'green', '-Once')
        $r.Code | Should -Be 0
    }
}

Describe 'green and ready' {
    It 'exits 0 with one green line on stdout when checks pass' {
        $r = Invoke-PrWait (New-Scenario) @('7', '-Repo', 'o/r', '-Until', 'green', '-Once')
        $r.Code | Should -Be 0
        $r.Out.Count | Should -Be 1
        $r.Out[0] | Should -Match '^#7 green on aaaaaaa'
    }
    It 'ready with no gating bots means green and no unresolved threads' {
        $r = Invoke-PrWait (New-Scenario) @('7', '-Repo', 'o/r', '-Until', 'ready', '-Once')
        $r.Code | Should -Be 0
        $r.Out[-1] | Should -Match 'ready on aaaaaaa'
    }
    It 'ready is blocked by an unresolved thread (exit 1)' {
        $s = New-Scenario
        Write-Fixture $s 'graphql' (Threads @(@{ isResolved = $false; path = 'src/a.js'; line = 3
            comments = @{ nodes = @(@{ id = 'T1'; url = 'https://github.com/o/r/pull/7#t1'; body = 'hm'; author = @{ login = 'bob' } }) } }))
        $r = Invoke-PrWait $s @('7', '-Repo', 'o/r', '-Until', 'ready', '-Once')
        $r.Code | Should -Be 1
        $r.Out[-1] | Should -Match 'unresolved'
    }
    It 'ready waits for a configured gating bot to review the current head' {
        $s = New-Scenario
        $r = Invoke-PrWait $s @('7', '-Repo', 'o/r', '-Until', 'ready', '-Once', '-GatingBots', 'reviewbot')
        $r.Code | Should -Be 3
        Write-Fixture $s 'repos_o_r_pulls_7_reviews' (, @(, @(@{ id = 9; user = @{ login = 'reviewbot[bot]'; type = 'Bot' }
            state = 'COMMENTED'; body = 'looks fine'; commit_id = $HeadA; html_url = 'https://github.com/o/r/pull/7#r9' })))
        $r = Invoke-PrWait $s @('7', '-Repo', 'o/r', '-Until', 'ready', '-Once', '-GatingBots', 'reviewbot')
        $r.Code | Should -Be 0
        $r.Out -join "`n" | Should -Match 'reviewbot finished on aaaaaaa'
    }
}

Describe 'failures' {
    It 'a failed check exits 1 and names it' {
        $s = New-Scenario
        Write-Fixture $s "repos_o_r_commits_$($HeadA)_check-runs" (CheckPages @((Run 'build'), (Run 'lint' 'failure')))
        $r = Invoke-PrWait $s @('7', '-Repo', 'o/r', '-Until', 'green', '-Once')
        $r.Code | Should -Be 1
        $r.Out -join "`n" | Should -Match 'check failed: lint https://ci.example/lint'
    }
    It 'a conflicting branch exits 1' {
        $s = New-Scenario
        Write-Fixture $s 'repos_o_r_pulls_7' (Pr -Mergeable 'dirty')
        $r = Invoke-PrWait $s @('7', '-Repo', 'o/r', '-Until', 'green', '-Once')
        $r.Code | Should -Be 1
        $r.Out[-1] | Should -Match 'DIRTY'
    }
    It 'a merged PR exits 0' {
        $s = New-Scenario
        Write-Fixture $s 'repos_o_r_pulls_7' (Pr -State 'closed' -Merged $true)
        $r = Invoke-PrWait $s @('7', '-Repo', 'o/r', '-Once')
        $r.Code | Should -Be 0
        $r.Out[-1] | Should -Match 'merged'
    }
    It 'a closed PR exits 1' {
        $s = New-Scenario
        Write-Fixture $s 'repos_o_r_pulls_7' (Pr -State 'closed')
        (Invoke-PrWait $s @('7', '-Repo', 'o/r', '-Once')).Code | Should -Be 1
    }
}

Describe 'the head changes during a poll' {
    It 'discards the poll and reports only the new head' {
        $s = New-Scenario
        # HeadA has a failing check, but the head moves to HeadB before the poll ends.
        Write-Fixture $s "repos_o_r_commits_$($HeadA)_check-runs" (CheckPages @(Run 'build' 'failure'))
        Remove-Item -LiteralPath (Join-Path $s 'repos_o_r_pulls_7.json')
        Write-Fixture $s 'repos_o_r_pulls_7' (Pr -Head $HeadA) -Seq 1
        Write-Fixture $s 'repos_o_r_pulls_7' (Pr -Head $HeadB) -Seq 2
        $r = Invoke-PrWait $s @('7', '-Repo', 'o/r', '-Until', 'green', '-Once')
        $r.Code | Should -Be 0
        $r.Out[-1] | Should -Match 'green on bbbbbbb'
        $r.Out -join "`n" | Should -Not -Match 'failed'
    }
}

Describe 'required checks' {
    It 'a required check that has not started yet keeps it pending (exit 3)' {
        $s = New-Scenario
        Write-Fixture $s 'repos_o_r_rules_branches_main' (, @(@{ type = 'required_status_checks'
            parameters = @{ required_status_checks = @(@{ context = 'e2e' }) } }))
        $r = Invoke-PrWait $s @('7', '-Repo', 'o/r', '-Until', 'green', '-MaxWaitSec', '3', '-IntervalSec', '1')
        $r.Code | Should -Be 3
        $r.Out[-1] | Should -Match 'still pending'
    }
    It 'matches a required check on the app GitHub names, not the name alone' {
        $s = New-Scenario
        Write-Fixture $s 'repos_o_r_rules_branches_main' (, @(@{ type = 'required_status_checks'
            parameters = @{ required_status_checks = @(@{ context = 'build'; integration_id = 999 }) } }))
        # 'build' passes, but from app 15368, not the required app 999.
        (Invoke-PrWait $s @('7', '-Repo', 'o/r', '-Until', 'green', '-Once')).Code | Should -Be 3
    }
    It 'unreadable branch protection gates on every CI check and says so' {
        $s = New-Scenario
        Write-Fixture $s 'repos_o_r_branches_main_protection_required_status_checks' 'gh: Resource not accessible by integration (HTTP 403)' -Err
        Write-Fixture $s "repos_o_r_commits_$($HeadA)_check-runs" (CheckPages @((Run 'build'), (Run 'optional-lint' 'failure')))
        $r = Invoke-PrWait $s @('7', '-Repo', 'o/r', '-Until', 'green', '-Once')
        $r.Code | Should -Be 1
        $r.Err | Should -Match 'unknown'
        $r.Out -join "`n" | Should -Match 'optional-lint'
        $r.Out[-1] | Should -Match 'required checks unknown'
    }
    It 'commit statuses count as checks' {
        $s = New-Scenario
        Write-Fixture $s "repos_o_r_commits_$($HeadA)_status" (, @(, @{ state = 'failure'
            statuses = @(@{ context = 'ci/legacy'; state = 'failure'; target_url = 'https://ci.example/legacy' }) }))
        $r = Invoke-PrWait $s @('7', '-Repo', 'o/r', '-Until', 'green', '-Once')
        $r.Code | Should -Be 1
        $r.Out -join "`n" | Should -Match 'ci/legacy'
    }
}

Describe 'events' {
    It 'the first run records a baseline; a restart reports what arrived in between' {
        $s = New-Scenario
        Write-Fixture $s 'repos_o_r_issues_7_comments' (, @(, @(Comment 1 'bob' 'old news')))
        $r = Invoke-PrWait $s @('7', '-Repo', 'o/r', '-Until', 'any-change', '-Once')
        $r.Out -join "`n" | Should -Not -Match 'old news'
        Write-Fixture $s 'repos_o_r_issues_7_comments' (, @(, @((Comment 1 'bob' 'old news'), (Comment 2 'carol' 'new news'))))
        $r = Invoke-PrWait $s @('7', '-Repo', 'o/r', '-Until', 'any-change', '-Once')
        $r.Code | Should -Be 0
        $r.Out -join "`n" | Should -Match 'comment from carol: new news'
        $r.Out -join "`n" | Should -Not -Match 'old news'
    }
    It 'skips the PR author, the gh user and CI bots' {
        $s = New-Scenario
        $null = Invoke-PrWait $s @('7', '-Repo', 'o/r', '-Until', 'any-change', '-Once')
        Write-Fixture $s 'repos_o_r_issues_7_comments' (, @(, @((Comment 1 'author'), (Comment 2 'me'),
            (Comment 3 'github-actions[bot]'), (Comment 4 'dave' 'real one'))))
        $r = Invoke-PrWait $s @('7', '-Repo', 'o/r', '-Until', 'any-change', '-Once')
        @($r.Out | Where-Object { $_ -match 'comment from' }).Count | Should -Be 1
        $r.Out -join "`n" | Should -Match 'dave'
    }
    It 'pages through more than 100 comments' {
        $s = New-Scenario
        $page1 = @(1..100 | ForEach-Object { Comment $_ 'bob' "c$_" })
        Write-Fixture $s 'repos_o_r_issues_7_comments' (, @(, $page1))
        $null = Invoke-PrWait $s @('7', '-Repo', 'o/r', '-Until', 'any-change', '-Once')
        $page2 = @(101..150 | ForEach-Object { Comment $_ 'bob' "c$_" })
        Write-Fixture $s 'repos_o_r_issues_7_comments' (, @($page1, $page2))
        $r = Invoke-PrWait $s @('7', '-Repo', 'o/r', '-Until', 'any-change', '-Once')
        @($r.Out | Where-Object { $_ -match 'comment from bob' }).Count | Should -Be 50
        $r.Out -join "`n" | Should -Match 'c150'
    }
    It '-Json prints one JSON object per event, each with a stable id' {
        $s = New-Scenario
        $null = Invoke-PrWait $s @('7', '-Repo', 'o/r', '-Until', 'any-change', '-Once')
        Write-Fixture $s 'repos_o_r_issues_7_comments' (, @(, @(Comment 5 'erin' 'json please')))
        $r = Invoke-PrWait $s @('7', '-Repo', 'o/r', '-Until', 'any-change', '-Once', '-Json')
        $events = $r.Out | ForEach-Object { $_ | ConvertFrom-Json }
        ($events | Where-Object id -EQ 'c:5').text | Should -Match 'json please'
        $events | ForEach-Object { $_.id | Should -Not -BeNullOrEmpty }
    }
    It 'stdout carries events only; progress goes to stderr' {
        $r = Invoke-PrWait (New-Scenario) @('7', '-Repo', 'o/r', '-Until', 'green', '-Once')
        $r.Out | ForEach-Object { $_ | Should -Match '^#7 ' }
        $r.Err | Should -Match 'watching o/r#7'
    }
}

Describe 'GitHub trouble' {
    It 'backs off on a rate limit and carries on' {
        $s = New-Scenario
        Remove-Item -LiteralPath (Join-Path $s 'repos_o_r_issues_7_comments.json')
        Write-Fixture $s 'repos_o_r_issues_7_comments' 'gh: API rate limit exceeded for user (HTTP 403)' -Seq 1 -Err
        Write-Fixture $s 'repos_o_r_issues_7_comments' (, @(, @())) -Seq 2
        $r = Invoke-PrWait $s @('7', '-Repo', 'o/r', '-Until', 'green', '-Once')
        $r.Code | Should -Be 0
        $r.Err | Should -Match 'rate limit'
        $r.Out -join "`n" | Should -Not -Match 'rate limit'
    }
    It 'stays unreachable: exit 1' {
        $s = New-Scenario
        Remove-Item -LiteralPath (Join-Path $s 'repos_o_r_issues_7_comments.json')
        Write-Fixture $s 'repos_o_r_issues_7_comments' 'gh: HTTP 502 Bad Gateway' -Err
        $r = Invoke-PrWait $s @('7', '-Repo', 'o/r', '-Until', 'green', '-IntervalSec', '1', '-MaxWaitSec', '120')
        $r.Code | Should -Be 1
        $r.Out[-1] | Should -Match 'unreachable'
    }
}

Describe 'one watcher per PR' {
    It 'a second watcher exits 2 while the first holds the lock' {
        $s = New-Scenario
        Write-Fixture $s "repos_o_r_commits_$($HeadA)_check-runs" (CheckPages @(Run 'build' 'pending'))
        $state = Join-Path $s 'state dir'
        $sep = [IO.Path]::PathSeparator
        $env:FAKE_GH_DIR = $s; $env:PR_WAIT_STATE_DIR = $state; $env:PR_WAIT_BACKOFF_SEC = '0'
        $oldPath = $env:PATH; $env:PATH = "$Bin$sep$oldPath"
        try {
            $first = Start-Process -FilePath $Pwsh -PassThru -NoNewWindow -RedirectStandardOutput (Join-Path $s 'first.out') `
                -RedirectStandardError (Join-Path $s 'first.err') `
                -ArgumentList '-NoProfile', '-File', "`"$PrWait`"", '7', '-Repo', 'o/r', '-Until', 'green', '-IntervalSec', '1', '-MaxWaitSec', '60'
            $deadline = (Get-Date).AddSeconds(30)
            while (-not (Get-ChildItem -LiteralPath $state -Filter '*.pid' -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 200 }
        } finally { $env:PATH = $oldPath }
        try {
            $r = Invoke-PrWait $s @('7', '-Repo', 'o/r', '-Until', 'green', '-Once')
            $r.Code | Should -Be 2
            $r.Out -join "`n" | Should -Match 'already watches'
        } finally {
            Stop-Process -Id $first.Id -Force -ErrorAction SilentlyContinue
        }
        # The OS released the lock when the first watcher died.
        Start-Sleep -Milliseconds 500
        (Invoke-PrWait $s @('7', '-Repo', 'o/r', '-Until', 'green', '-Once')).Code | Should -Be 3
    }
}

Describe 'bounded runs' {
    It '-MaxWaitSec gives exit 3 while still pending' {
        $s = New-Scenario
        Write-Fixture $s "repos_o_r_commits_$($HeadA)_check-runs" (CheckPages @(Run 'build' 'pending'))
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $r = Invoke-PrWait $s @('7', '-Repo', 'o/r', '-Until', 'green', '-IntervalSec', '1', '-MaxWaitSec', '3')
        $r.Code | Should -Be 3
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 40
    }
    It 'state lives under a path with spaces' {
        $s = New-Scenario
        $state = Join-Path $s 'a state folder with spaces'
        $null = Invoke-PrWait $s @('7', '-Repo', 'o/r', '-Until', 'green', '-Once') -StateDir $state
        @(Get-ChildItem -LiteralPath $state -Filter '*.json').Count | Should -Be 1
    }
}

Describe 'base branch and merge state' {
    It 'reports a base branch that moved onto this PR''s files' {
        $s = New-Scenario
        Write-Fixture $s "repos_o_r_commits_$($HeadA)_check-runs" (CheckPages @(Run 'build' 'pending'))
        $null = Invoke-PrWait $s @('7', '-Repo', 'o/r', '-Until', 'any-change', '-Once')
        Write-Fixture $s 'repos_o_r_branches_main' @{ commit = @{ sha = 'ddddddd4444444444444444444444444444444444' } }
        Write-Fixture $s "repos_o_r_compare_$($Base1)...ddddddd4444444444444444444444444444444444" @{ files = @(@{ filename = 'src/a.js' }, @{ filename = 'README.md' }) }
        $r = Invoke-PrWait $s @('7', '-Repo', 'o/r', '-Until', 'any-change', '-Once')
        $r.Out -join "`n" | Should -Match 'main moved to ddddddd and touches files in this PR: src/a.js'
    }
    It 'reports a branch that fell behind, and ready exits 1 on it' {
        $s = New-Scenario
        Write-Fixture $s 'repos_o_r_pulls_7' (Pr -Mergeable 'behind')
        $r = Invoke-PrWait $s @('7', '-Repo', 'o/r', '-Until', 'ready', '-Once')
        $r.Code | Should -Be 1
        $r.Out[-1] | Should -Match 'BEHIND'
    }
}
