#Requires -Version 7.2
# Pester 5 tests for delegate/scripts/agent-run.ps1 (Windows) and agent-run.sh (Linux, macOS),
# run against fake CLIs. TEST_SCRIPT_KINDS picks which run (comma-separated: ps1, sh);
# by default ps1 on Windows and sh elsewhere.

BeforeAll {
    $script:Kinds = if ($env:TEST_SCRIPT_KINDS) { $env:TEST_SCRIPT_KINDS -split ',' } elseif ($IsWindows) { @('ps1') } else { @('sh') }
    $script:Fake = (Resolve-Path (Join-Path $PSScriptRoot 'fakes/fake-cli.ps1')).Path
    $script:Pwsh = (Get-Process -Id $PID).Path
    $script:Root = Join-Path ([IO.Path]::GetTempPath()) "agent run tests $([guid]::NewGuid().ToString('N').Substring(0, 8))"
    $script:Bin = Join-Path $Root 'fake bin'
    $script:EmptyBin = Join-Path $Root 'empty bin'
    New-Item -ItemType Directory -Force $Bin, $EmptyBin | Out-Null

    # One launcher per CLI name, the way each operating system finds commands.
    foreach ($name in 'claude', 'codex', 'cursor-agent') {
        if ($IsWindows) {
            Set-Content -LiteralPath (Join-Path $Bin "$name.cmd") -Encoding ascii `
                -Value "@`"$Pwsh`" -NoProfile -File `"$Fake`" $name %*"
        } else {
            $path = Join-Path $Bin $name
            Set-Content -LiteralPath $path -Value "#!/bin/sh`nexec `"$Pwsh`" -NoProfile -File `"$Fake`" $name `"`$@`""
            chmod +x $path
        }
    }

    # A repository with a linked worktree, both with spaces in their paths.
    $script:Repo = Join-Path $Root 'work repo'
    $script:Worktree = Join-Path $Root 'work tree'
    git init -q $Repo
    Set-Content -LiteralPath (Join-Path $Repo 'a.txt') -Value 'a'
    git -C $Repo add a.txt
    git -C $Repo -c user.name=t -c user.email=t@example.invalid commit -qm init
    git -C $Repo worktree add -q $Worktree -b wt 2>$null

    $script:Prompt = Join-Path $Root 'the brief.md'
    Set-Content -LiteralPath $Prompt -Value 'Review the diff. UNIQUE-PROMPT-TEXT' -NoNewline

    $script:RoleFile = Join-Path $Root 'roles file.json'
    @{
        roles = @{
            'coder-simple' = @{
                harness = 'claude'; model = 'small'; effort = 'xhigh'
                fallback = @{ harness = 'codex'; model = 'm1' }
            }
            'coder-complex' = @{ harness = 'codex'; model = 'm2' }
            'reviewer'     = @{}
            'council-b'    = @{ harness = 'codex'; model = 'm1'; effort = 'high' }
            'planner'      = @{ harness = 'codex'; model = 'm2' }
        }
        hostOverrides = @{
            cursor = @{
                'coder-simple' = @{ harness = 'cursor'; model = 'm2' }
                'planner' = @{ harness = 'cursor'; model = 'm1'; fallback = @{ harness = 'claude'; model = 'm2'; effort = 'high' } }
            }
        }
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $RoleFile

    $script:Git = Split-Path (Get-Command git -CommandType Application | Select-Object -First 1).Source
    # agent-run.sh needs jq; keep its folder on the narrowed PATH (it may live outside /usr/bin).
    $jq = Get-Command jq -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $script:JqDir = if ($jq -and -not $IsWindows) { Split-Path $jq.Source } else { $null }

    function script:Invoke-AgentRun {
        param([string[]] $Arguments, [hashtable] $Env = @{}, [string] $PathDir = $Bin)
        $log = Join-Path $Root "log-$([guid]::NewGuid().ToString('N')).jsonl"
        $sep = [IO.Path]::PathSeparator
        $path = @($PathDir, $Git) + $(if ($IsWindows) { @("$env:SystemRoot\System32") } else { @('/usr/bin', '/bin') })
        if ($JqDir) { $path += $JqDir }
        $vars = @{
            PATH = ($path -join $sep); FAKE_CLI_LOG = $log; AGENT_SKILLS_DELEGATE = $null
            HOME = $Root; USERPROFILE = $Root
        }
        foreach ($k in $Env.Keys) { $vars[$k] = $Env[$k] }
        $saved = @{}
        foreach ($k in $vars.Keys) {
            $saved[$k] = [Environment]::GetEnvironmentVariable($k)
            [Environment]::SetEnvironmentVariable($k, $vars[$k])
        }
        try {
            $stderrFile = Join-Path $Root 'stderr.txt'
            $stdout = if ($Kind -eq 'ps1') { & $Pwsh -NoProfile -File $AgentRun @Arguments 2>$stderrFile }
                      else { & sh $AgentRun @Arguments 2>$stderrFile }
            $code = $LASTEXITCODE
        } finally {
            foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
        }
        $calls = if (Test-Path -LiteralPath $log) { @(Get-Content -LiteralPath $log | ForEach-Object { $_ | ConvertFrom-Json }) } else { @() }
        $lines = @($stdout | Where-Object { $_ -ne '' })
        [pscustomobject]@{
            Lines = $lines
            Json = if ($lines.Count -eq 1) { $lines[0] | ConvertFrom-Json } else { $null }
            ExitCode = $code
            Calls = $calls
            Run = $calls | Where-Object { $_.stdin } | Select-Object -Last 1
        }
    }

    function script:New-OutFile { Join-Path $Root "out file $([guid]::NewGuid().ToString('N').Substring(0, 6)).txt" }

    # The same folder can have two names (on macOS /var is a link to /private/var), so
    # compare folders by their real path.
    function script:Get-RealDir([string] $Path) {
        if ($IsWindows) { return (Resolve-Path -LiteralPath $Path).Path }
        (& /bin/sh -c 'cd "$1" && pwd -P' sh $Path)
    }

    function script:Base([string] $Harness, [string] $Mode = 'read-only', [string] $Dir = $Repo) {
        @('-Harness', $Harness, '-Model', 'm1', '-Mode', $Mode, '-WorkDir', $Dir,
          '-PromptFile', $Prompt, '-OutFile', (New-OutFile), '-TimeoutSec', '60')
    }
}

AfterAll {
    git -C $Repo worktree remove --force $Worktree 2>$null
    # Remove links first, without following them into the repository.
    Get-ChildItem -LiteralPath $Root -Recurse -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object LinkType | ForEach-Object { [IO.Directory]::Delete($_.FullName, $false) }
    Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'agent-run.<Kind>' -ForEach @(@{ Kind = 'ps1' }, @{ Kind = 'sh' }) {
    BeforeAll {
        $script:Kind = $Kind
        $script:AgentRun = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "../skills/delegate/scripts/agent-run.$Kind"))
    }
    BeforeEach { if ($Kind -notin $Kinds) { Set-ItResult -Skipped -Because "TEST_SCRIPT_KINDS excludes $Kind" } }

    Context 'stdout' {
        It 'prints exactly one JSON object with the contract fields' {
            $r = Invoke-AgentRun (Base 'claude')
            $r.Lines.Count | Should -Be 1
            $r.ExitCode | Should -Be 0
            $names = $r.Json.PSObject.Properties.Name
            foreach ($f in 'status', 'harness', 'model', 'sessionId', 'outFile', 'durationSec', 'exitCode', 'error') {
                $names | Should -Contain $f
            }
            $r.Json.status | Should -Be 'ok'
        }
    }

    Context 'the brief travels on stdin, never as an argument' -ForEach @(
        @{ H = 'claude' }, @{ H = 'codex' }, @{ H = 'cursor' }
    ) {
        It '<H>' {
            $r = Invoke-AgentRun (Base $H)
            $r.Json.status | Should -Be 'ok'
            $r.Run.stdin | Should -Match 'UNIQUE-PROMPT-TEXT'
            ($r.Run.args -join ' ') | Should -Not -Match 'UNIQUE-PROMPT-TEXT'
        }
    }

    Context 'paths with spaces' -ForEach @(
        @{ H = 'claude' }, @{ H = 'codex' }, @{ H = 'cursor' }
    ) {
        It '<H> runs in the work directory and writes the out file' {
            $out = New-OutFile
            $a = @('-Harness', $H, '-Model', 'm1', '-WorkDir', $Repo, '-PromptFile', $Prompt, '-OutFile', $out)
            $r = Invoke-AgentRun $a -Env @{ FAKE_CLI_RESULT = 'hello from the delegate' }
            $r.Json.status | Should -Be 'ok'
            $r.Json.outFile | Should -Be $out
            Get-Content -LiteralPath $out -Raw | Should -Be 'hello from the delegate'
            if ($H -eq 'codex') { $r.Run.args | Should -Contain $Repo }
            elseif ($H -eq 'cursor') { $r.Run.args | Should -Contain $Repo }
            else { Get-RealDir $r.Run.cwd | Should -Be (Get-RealDir $Repo) }
        }
    }

    Context 'read-only is enforced with each CLI''s own flag' {
        It 'claude: dontAsk with a fixed tool list, never a write mode' {
            $r = Invoke-AgentRun (Base 'claude')
            $a = $r.Run.args
            $a[[array]::IndexOf($a, '--permission-mode') + 1] | Should -Be 'dontAsk'
            $a[[array]::IndexOf($a, '--tools') + 1] | Should -Not -Match 'Edit|Write'
            $a | Should -Not -Contain 'bypassPermissions'
        }
        It 'codex: read-only sandbox, never the bypass flag' {
            $a = (Invoke-AgentRun (Base 'codex')).Run.args
            $a[[array]::IndexOf($a, '-s') + 1] | Should -Be 'read-only'
            $a | Should -Not -Contain '--dangerously-bypass-approvals-and-sandbox'
        }
        It 'cursor: plan mode, no -f and no sandbox switch' {
            $a = (Invoke-AgentRun (Base 'cursor')).Run.args
            $a[[array]::IndexOf($a, '--mode') + 1] | Should -Be 'plan'
            $a | Should -Not -Contain '-f'
            $a | Should -Not -Contain '--sandbox'
        }
        It 'fails a read-only run that changed the work directory' {
            $r = Invoke-AgentRun (Base 'cursor') -Env @{ FAKE_CLI_MODE = 'scribble' }
            Remove-Item -LiteralPath (Join-Path $Repo 'scribble.txt') -ErrorAction SilentlyContinue
            $r.Json.status | Should -Be 'failed'
            $r.Json.error | Should -Match 'read-only'
        }
    }

    Context 'write mode is full access, with each CLI''s own flag' {
        It 'refuses a work directory that is not a linked worktree' {
            $r = Invoke-AgentRun (Base 'claude' 'write' $Repo)
            $r.Json.status | Should -Be 'failed'
            $r.Json.error | Should -Match 'worktree'
            $r.Run | Should -BeNullOrEmpty
        }
        It 'claude: bypassPermissions, with no tool list' {
            $a = (Invoke-AgentRun (Base 'claude' 'write' $Worktree)).Run.args
            $a[[array]::IndexOf($a, '--permission-mode') + 1] | Should -Be 'bypassPermissions'
            $a | Should -Not -Contain '--tools'
        }
        It 'codex: bypasses approvals and the sandbox' {
            $a = (Invoke-AgentRun (Base 'codex' 'write' $Worktree)).Run.args
            $a | Should -Contain '--dangerously-bypass-approvals-and-sandbox'
            $a | Should -Not -Contain '-s'
        }
        It 'codex: a resumed run is still full access' {
            $a = (Invoke-AgentRun ((Base 'codex' 'write' $Worktree) + @('-ResumeId', 'abc-123'))).Run.args
            $a[1] | Should -Be 'resume'
            $a | Should -Contain '--dangerously-bypass-approvals-and-sandbox'
            ($a -join ' ') | Should -Not -Match 'sandbox_mode'
        }
        It 'cursor: -f with the sandbox off, and no plan mode' {
            $a = (Invoke-AgentRun (Base 'cursor' 'write' $Worktree)).Run.args
            $a | Should -Contain '-f'
            $a[[array]::IndexOf($a, '--sandbox') + 1] | Should -Be 'disabled'
            $a | Should -Not -Contain '--mode'
        }
    }

    Context 'directories the delegate may read' {
        BeforeAll {
            $script:SkillsRoot = (Resolve-Path (Join-Path $PSScriptRoot '../skills')).Path
            $script:Extra = Join-Path $Root 'plan dir'
            New-Item -ItemType Directory -Force $Extra | Out-Null
        }
        It '<H> always gets the skills folder, plus each -ReadDir' -ForEach @(@{ H = 'claude' }, @{ H = 'cursor' }) {
            $r = Invoke-AgentRun ((Base $H) + @('-ReadDir', $Extra))
            $a = $r.Run.args
            $a | Should -Contain '--add-dir'
            $a | Should -Contain $SkillsRoot
            $a | Should -Contain $Extra
        }
        It 'claude still gets its permission mode after the directory list' {
            $a = (Invoke-AgentRun ((Base 'claude') + @('-ReadDir', $Extra))).Run.args
            [array]::IndexOf($a, '--permission-mode') | Should -BeGreaterThan ([array]::IndexOf($a, $Extra))
        }
        It 'also allows the real folder behind each linked skill' {
            # A project skill folder whose skills are links into a checkout, as when testing a branch.
            $linked = Join-Path $Root 'linked skills'
            New-Item -ItemType Directory -Force $linked | Out-Null
            foreach ($skill in 'delegate', 'coding-standards') {
                $target = (Resolve-Path (Join-Path $SkillsRoot $skill)).Path
                $link = Join-Path $linked $skill
                if (-not (Test-Path -LiteralPath $link)) {
                    if ($IsWindows) { New-Item -ItemType Junction -Path $link -Target $target | Out-Null }
                    else { New-Item -ItemType SymbolicLink -Path $link -Target $target | Out-Null }
                }
            }
            $viaLink = Join-Path $linked "delegate/scripts/agent-run.$Kind"
            $saved = $script:AgentRun
            $script:AgentRun = $viaLink
            try { $a = (Invoke-AgentRun (Base 'claude')).Run.args } finally { $script:AgentRun = $saved }
            $a | Should -Contain $linked
            $a | Should -Contain (Resolve-Path (Join-Path $SkillsRoot 'coding-standards')).Path
        }
        It 'rejects a -ReadDir that does not exist' {
            $r = Invoke-AgentRun ((Base 'claude') + @('-ReadDir', (Join-Path $Root 'missing dir')))
            $r.ExitCode | Should -Be 2
        }
    }

    Context 'model and effort' {
        It 'claude passes --model and --effort' {
            $r = Invoke-AgentRun @('-Harness', 'claude', '-Model', 'small', '-Effort', 'high', '-WorkDir', $Repo, '-PromptFile', $Prompt, '-OutFile', (New-OutFile))
            $a = $r.Run.args
            $a[[array]::IndexOf($a, '--model') + 1] | Should -Be 'small'
            $a[[array]::IndexOf($a, '--effort') + 1] | Should -Be 'high'
            $r.Json.model | Should -Be 'claude-small-9'
        }
        It 'codex passes -m and the reasoning effort key' {
            $r = Invoke-AgentRun @('-Harness', 'codex', '-Model', 'm2', '-Effort', 'high', '-WorkDir', $Repo, '-PromptFile', $Prompt, '-OutFile', (New-OutFile))
            $r.Run.args | Should -Contain 'model_reasoning_effort=high'
            $r.Json.model | Should -Be 'm2'
        }
        It 'cursor puts effort inside the model string' {
            $r = Invoke-AgentRun @('-Harness', 'cursor', '-Model', 'm2', '-Effort', 'high', '-WorkDir', $Repo, '-PromptFile', $Prompt, '-OutFile', (New-OutFile))
            $r.Run.args | Should -Contain 'm2[effort=high]'
        }
    }

    Context 'roles' {
        It 'resolves a role from the role file' {
            $r = Invoke-AgentRun @('-Role', 'council-b', '-HostHarness', 'claude', '-RoleFile', $RoleFile, '-WorkDir', $Repo, '-PromptFile', $Prompt, '-OutFile', (New-OutFile))
            $r.Json.status | Should -Be 'ok'
            $r.Json.harness | Should -Be 'codex'
            $r.Run.args | Should -Contain 'model_reasoning_effort=high'
        }
        It 'a host override replaces the whole role, so no effort leaks across harnesses' {
            $r = Invoke-AgentRun @('-Role', 'coder-simple', '-HostHarness', 'cursor', '-RoleFile', $RoleFile, '-WorkDir', $Repo, '-PromptFile', $Prompt, '-OutFile', (New-OutFile))
            $r.Json.harness | Should -Be 'cursor'
            $r.Run.args | Should -Contain 'm2'
            ($r.Run.args -join ' ') | Should -Not -Match 'effort'
        }
        It 'a CLI that refuses the model is unavailable' {
            $r = Invoke-AgentRun (Base 'cursor') -Env @{ FAKE_CLI_MODE = 'refusemodel' }
            $r.Json.status | Should -Be 'unavailable'
        }
        It 'reports an empty role as unavailable' {
            $r = Invoke-AgentRun @('-Role', 'reviewer', '-HostHarness', 'claude', '-RoleFile', $RoleFile, '-WorkDir', $Repo, '-PromptFile', $Prompt, '-OutFile', (New-OutFile))
            $r.Json.status | Should -Be 'unavailable'
            $r.Calls | Should -BeNullOrEmpty
        }
        It 'reports a missing role file as unavailable' {
            $r = Invoke-AgentRun @('-Role', 'reviewer', '-HostHarness', 'claude', '-RoleFile', (Join-Path $Root 'nope.json'), '-WorkDir', $Repo, '-PromptFile', $Prompt, '-OutFile', (New-OutFile))
            $r.Json.status | Should -Be 'unavailable'
        }
    }

    Context 'coder roles the role file leaves out' {
        BeforeAll {
            function script:Invoke-Role([string] $Role, [string] $HostHarness, [string] $File = $RoleFile, [string[]] $More = @()) {
                Invoke-AgentRun (@('-Role', $Role, '-HostHarness', $HostHarness, '-RoleFile', $File, '-WorkDir', $Repo,
                                   '-PromptFile', $Prompt, '-OutFile', (New-OutFile)) + $More)
            }
        }
        It 'run as the next coder role above that the file has, and stderr says which' {
            $r = Invoke-Role 'coder-mechanical' 'claude'
            $r.Json.status | Should -Be 'ok'
            $r.Json.harness | Should -Be 'claude'
            $r.Run.args | Should -Contain 'small'
            $r.Run.args | Should -Contain 'xhigh'
            Get-Content -LiteralPath (Join-Path $Root 'stderr.txt') -Raw | Should -Match "'coder-mechanical' is not in .*running it as 'coder-simple'"
            $r = Invoke-Role 'coder-moderate' 'claude'
            $r.Json.status | Should -Be 'ok'
            $r.Json.harness | Should -Be 'codex'
            $r.Run.args | Should -Contain 'm2'
        }
        It 'a role the file has runs as itself, with no note' {
            $r = Invoke-Role 'coder-simple' 'claude'
            $r.Run.args | Should -Contain 'small'
            Get-Content -LiteralPath (Join-Path $Root 'stderr.txt') -Raw | Should -Not -Match 'running it as'
        }
        It 'take the host override of the role above before any default role' {
            $r = Invoke-Role 'coder-mechanical' 'cursor'
            $r.Json.harness | Should -Be 'cursor'
            $r.Run.args | Should -Contain 'm2'
        }
        It 'take the fallback of the role they ran as' {
            $r = Invoke-Role 'coder-mechanical' 'codex' -More @('-Fallback')
            $r.Json.status | Should -Be 'ok'
            $r.Run.cli | Should -Be 'codex'
            $r.Run.args | Should -Contain 'm1'
        }
        It 'never run as a lower coder role, and an entry without a model does not pass the work up' {
            $file = Join-Path $Root 'low roles.json'
            @{ roles = @{
                'coder-mechanical' = @{}
                'coder-simple' = @{ harness = 'claude'; model = 'small' }
                'coder-complex' = @{ harness = 'codex'; model = 'm2' }
            } } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $file
            $r = Invoke-Role 'coder-mechanical' 'claude' $file
            $r.Json.status | Should -Be 'unavailable'
            $r.Calls | Should -BeNullOrEmpty
            @{ roles = @{ 'coder-simple' = @{ harness = 'claude'; model = 'small' } } } |
                ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $file
            foreach ($role in 'coder-moderate', 'coder-complex') {
                $r = Invoke-Role $role 'claude' $file
                $r.Json.status | Should -Be 'unavailable'
                $r.Json.error | Should -Match $role
                $r.Calls | Should -BeNullOrEmpty
            }
        }
        It 'no other role runs as a coder role' {
            $r = Invoke-Role 'council-a' 'claude'
            $r.Json.status | Should -Be 'unavailable'
            $r.Calls | Should -BeNullOrEmpty
        }
    }

    Context 'quota and fallback selection' {
        It '<H> reports quota exhaustion from the provider error' -ForEach @(@{ H = 'claude' }, @{ H = 'codex' }, @{ H = 'cursor' }) {
            $r = Invoke-AgentRun (Base $H) -Env @{ FAKE_CLI_MODE = 'quota' }
            $r.Json.status | Should -Be 'quota-exhausted'
            $r.ExitCode | Should -Be 1
            $r.Json.sessionId | Should -Be '11111111-2222-3333-4444-555555555555'
        }
        It 'distinguishes an explicit quota message on stderr from a generic 429' {
            $quota = Invoke-AgentRun (Base 'cursor') -Env @{ FAKE_CLI_MODE = 'quota-stderr' }
            $transient = Invoke-AgentRun (Base 'cursor') -Env @{ FAKE_CLI_MODE = 'transient' }
            $quota.Json.status | Should -Be 'quota-exhausted'
            $transient.Json.status | Should -Be 'failed'
        }
        It 'does not mistake a successful reply for a provider error' {
            $r = Invoke-AgentRun (Base 'claude') -Env @{ FAKE_CLI_RESULT = "You've hit your usage limit." }
            $r.Json.status | Should -Be 'ok'
        }
        It 'reports a read-only violation even when the delegate also hits quota' {
            try {
                $r = Invoke-AgentRun (Base 'claude') -Env @{ FAKE_CLI_MODE = 'quota-scribble' }
                $r.Json.status | Should -Be 'failed'
                $r.Json.error | Should -Match 'read-only'
            } finally {
                Remove-Item -LiteralPath (Join-Path $Repo 'scribble.txt') -ErrorAction SilentlyContinue
            }
        }
        It 'reports primary quota, then runs the selected fallback as a fresh session in the same worktree' {
            $a = @('-Role', 'coder-simple', '-HostHarness', 'codex', '-RoleFile', $RoleFile,
                   '-Mode', 'write', '-WorkDir', $Worktree, '-PromptFile', $Prompt)
            $partial = Join-Path $Worktree 'scribble.txt'
            try {
                $primary = Invoke-AgentRun ($a + @('-OutFile', (New-OutFile))) -Env @{ FAKE_CLI_MODE = 'quota-scribble' }
                $primary.Json.status | Should -Be 'quota-exhausted'
                @($primary.Calls | Where-Object stdin).Count | Should -Be 1
                $fallback = Invoke-AgentRun ($a + @('-OutFile', (New-OutFile), '-Fallback'))
                $fallback.Json.status | Should -Be 'ok'
                $fallback.Json.harness | Should -Be 'codex'
                $fallback.Run.cwd | Should -Be (Get-RealDir $Worktree)
                $fallback.Run.args | Should -Not -Contain 'resume'
                ($fallback.Run.args -join ' ') | Should -Not -Match 'effort'
                Get-Content -LiteralPath $partial | Should -Be 'x'
            } finally {
                Remove-Item -LiteralPath $partial -ErrorAction SilentlyContinue
            }
        }
        It 'uses the host override fallback settings, and never inherits the default role fallback' {
            $a = @('-Role', 'planner', '-HostHarness', 'cursor', '-RoleFile', $RoleFile,
                   '-WorkDir', $Repo, '-PromptFile', $Prompt, '-OutFile', (New-OutFile), '-Fallback')
            $override = Invoke-AgentRun $a
            $override.Json.status | Should -Be 'ok'
            $override.Run.cli | Should -Be 'claude'
            $override.Run.args | Should -Contain 'm2'
            $override.Run.args | Should -Contain 'high'
            $a[1] = 'coder-simple'
            $missing = Invoke-AgentRun $a
            $missing.Json.status | Should -Be 'unavailable'
            $missing.Calls | Should -BeNullOrEmpty
        }
    }

    Context 'unavailable, never substituted' {
        It 'a missing CLI' {
            $r = Invoke-AgentRun (Base 'codex') -PathDir $EmptyBin
            $r.Json.status | Should -Be 'unavailable'
            $r.Json.error | Should -Match 'not installed|not found'
        }
        It '<H> signed out' -ForEach @(@{ H = 'claude' }, @{ H = 'codex' }, @{ H = 'cursor' }) {
            $r = Invoke-AgentRun (Base $H) -Env @{ FAKE_CLI_MODE = 'signedout' }
            $r.Json.status | Should -Be 'unavailable'
            $r.Run | Should -BeNullOrEmpty
        }
        It '<H> model not offered' -ForEach @(@{ H = 'codex' }, @{ H = 'cursor' }) {
            $r = Invoke-AgentRun (Base $H) -Env @{ FAKE_CLI_MODELS = 'x1,x2' }
            $r.Json.status | Should -Be 'unavailable'
            $r.Json.error | Should -Match 'm1'
            $r.Run | Should -BeNullOrEmpty
        }
        It 'claude reporting a different model than the one asked for' {
            $r = Invoke-AgentRun (Base 'claude') -Env @{ FAKE_CLI_MODE = 'wrongmodel' }
            $r.Json.status | Should -Be 'unavailable'
            $r.Json.model | Should -Be 'some-other-model'
        }
    }

    Context 'timeout' {
        It 'kills the whole process tree and reports timeout' {
            $pidFile = Join-Path $Root 'child pid.txt'
            $a = @('-Harness', 'cursor', '-Model', 'm1', '-WorkDir', $Repo, '-PromptFile', $Prompt, '-OutFile', (New-OutFile), '-TimeoutSec', '8')
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $r = Invoke-AgentRun $a -Env @{ FAKE_CLI_MODE = 'hang'; FAKE_CLI_PIDFILE = $pidFile }
            $sw.Elapsed.TotalSeconds | Should -BeLessThan 60
            $r.Json.status | Should -Be 'timeout'
            $childId = [int](Get-Content -LiteralPath $pidFile)
            Start-Sleep -Milliseconds 500
            Get-Process -Id $childId -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        }
    }

    Context 'failures' -ForEach @(@{ H = 'claude' }, @{ H = 'codex' }, @{ H = 'cursor' }) {
        It '<H>: malformed output is invalid-output' {
            $r = Invoke-AgentRun (Base $H) -Env @{ FAKE_CLI_MODE = 'malformed' }
            $r.Json.status | Should -Be 'invalid-output'
            $r.ExitCode | Should -Not -Be 0
        }
        It '<H>: a non-zero exit is failed, with the exit code' {
            $r = Invoke-AgentRun (Base $H) -Env @{ FAKE_CLI_MODE = 'fail' }
            $r.Json.status | Should -Be 'failed'
            $r.Json.exitCode | Should -Be 3
        }
    }

    Context 'schema' {
        BeforeAll {
            $script:Schema = Join-Path $Root 'result schema.json'
            '{"type":"object","properties":{"verdict":{"type":"string","enum":["APPROVE","CHANGES"]}},"required":["verdict"]}' |
                Set-Content -LiteralPath $Schema
        }
        It '<H>: a valid result is ok and the out file holds the JSON' -ForEach @(@{ H = 'claude' }, @{ H = 'codex' }, @{ H = 'cursor' }) {
            $out = New-OutFile
            $a = @('-Harness', $H, '-Model', 'm1', '-WorkDir', $Repo, '-PromptFile', $Prompt, '-OutFile', $out, '-SchemaFile', $Schema)
            $r = Invoke-AgentRun $a -Env @{ FAKE_CLI_RESULT = '{"verdict":"APPROVE"}' }
            $r.Json.status | Should -Be 'ok'
            (Get-Content -LiteralPath $out -Raw | ConvertFrom-Json).verdict | Should -Be 'APPROVE'
        }
        It '<H>: a result that fails the schema is invalid-output' -ForEach @(@{ H = 'claude' }, @{ H = 'codex' }, @{ H = 'cursor' }) {
            $a = @('-Harness', $H, '-Model', 'm1', '-WorkDir', $Repo, '-PromptFile', $Prompt, '-OutFile', (New-OutFile), '-SchemaFile', $Schema)
            $r = Invoke-AgentRun $a -Env @{ FAKE_CLI_RESULT = '{"verdict":"MAYBE"}' }
            $r.Json.status | Should -Be 'invalid-output'
        }
        It 'uses the CLI''s own schema flag where it has one' {
            $a = @('-Harness', 'codex', '-Model', 'm1', '-WorkDir', $Repo, '-PromptFile', $Prompt, '-OutFile', (New-OutFile), '-SchemaFile', $Schema)
            (Invoke-AgentRun $a -Env @{ FAKE_CLI_RESULT = '{"verdict":"APPROVE"}' }).Run.args | Should -Contain '--output-schema'
            $a[1] = 'claude'
            (Invoke-AgentRun $a -Env @{ FAKE_CLI_RESULT = '{"verdict":"APPROVE"}' }).Run.args | Should -Contain '--json-schema'
        }
        It 'cursor has no schema flag, so the schema goes into the brief' {
            $a = @('-Harness', 'cursor', '-Model', 'm1', '-WorkDir', $Repo, '-PromptFile', $Prompt, '-OutFile', (New-OutFile), '-SchemaFile', $Schema)
            $r = Invoke-AgentRun $a -Env @{ FAKE_CLI_RESULT = '{"verdict":"APPROVE"}' }
            $r.Run.stdin | Should -Match '"enum"'
        }
    }

    Context 'resume' {
        It 'claude resumes with --resume and returns the session id' {
            $r = Invoke-AgentRun ((Base 'claude') + @('-ResumeId', 'abc-123'))
            $a = $r.Run.args
            $a[[array]::IndexOf($a, '--resume') + 1] | Should -Be 'abc-123'
            $r.Json.sessionId | Should -Be 'abc-123'
        }
        It 'codex resumes with exec resume, keeps the sandbox, and runs in the work directory' {
            $r = Invoke-AgentRun ((Base 'codex') + @('-ResumeId', 'abc-123'))
            $a = $r.Run.args
            $a[1] | Should -Be 'resume'
            $a | Should -Contain 'abc-123'
            $a | Should -Contain 'sandbox_mode=read-only'
            Get-RealDir $r.Run.cwd | Should -Be (Get-RealDir $Repo)
            $r.Json.sessionId | Should -Be 'abc-123'
        }
        It 'cursor resumes with --resume' {
            $a = (Invoke-AgentRun ((Base 'cursor') + @('-ResumeId', 'abc-123'))).Run.args
            $a[[array]::IndexOf($a, '--resume') + 1] | Should -Be 'abc-123'
        }
        It 'a new run returns the session id the CLI reports' -ForEach @(@{ H = 'claude' }, @{ H = 'codex' }, @{ H = 'cursor' }) {
            (Invoke-AgentRun (Base $H)).Json.sessionId | Should -Be '11111111-2222-3333-4444-555555555555'
        }
    }

    Context 'recursion guard' {
        It 'refuses to start when AGENT_SKILLS_DELEGATE is set' {
            $r = Invoke-AgentRun (Base 'claude') -Env @{ AGENT_SKILLS_DELEGATE = '1' }
            $r.Json.status | Should -Be 'failed'
            $r.Json.error | Should -Match 'AGENT_SKILLS_DELEGATE'
            $r.Calls | Should -BeNullOrEmpty
        }
        It 'sets AGENT_SKILLS_DELEGATE for the delegate' {
            (Invoke-AgentRun (Base 'claude')).Run.guard | Should -Be '1'
        }
    }

    Context 'bad arguments' {
        It 'exits 2 with a JSON error' {
            $r = Invoke-AgentRun @('-Harness', 'emacs', '-Model', 'm1', '-WorkDir', $Repo, '-PromptFile', $Prompt, '-OutFile', (New-OutFile))
            $r.ExitCode | Should -Be 2
            $r.Json.status | Should -Be 'failed'
        }
        It 'a missing prompt file' {
            $r = Invoke-AgentRun @('-Harness', 'claude', '-Model', 'm1', '-WorkDir', $Repo, '-PromptFile', (Join-Path $Root 'none.md'), '-OutFile', (New-OutFile))
            $r.ExitCode | Should -Be 2
        }
    }

    Context '-Check' {
        It 'reports every installed CLI and passes when all flags exist' {
            $r = Invoke-AgentRun @('-Check')
            $r.Json.status | Should -Be 'ok'
            @($r.Json.clis).Count | Should -Be 3
            $r.Json.clis | ForEach-Object { $_.installed | Should -BeTrue; @($_.missingFlags).Count | Should -Be 0 }
        }
        It 'names a flag that has gone missing' {
            $r = Invoke-AgentRun @('-Check') -Env @{ FAKE_CLI_HELP_DROP = '--json-schema' }
            $r.Json.status | Should -Be 'failed'
            ($r.Json.clis | Where-Object harness -EQ 'claude').missingFlags | Should -Contain '--json-schema'
        }
        It 'lists a CLI that is not installed without failing' {
            $r = Invoke-AgentRun @('-Check') -PathDir $EmptyBin
            $r.Json.status | Should -Be 'ok'
            $r.Json.clis | ForEach-Object { $_.installed | Should -BeFalse }
        }
    }
}
