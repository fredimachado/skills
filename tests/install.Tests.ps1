#Requires -Version 7.2
# Pester 5 tests for scripts/install.ps1 (Windows) and scripts/install.sh (Linux, macOS),
# always against temporary target folders. TEST_SCRIPT_KINDS picks which run
# (comma-separated: ps1, sh); by default ps1 on Windows and sh elsewhere.

BeforeAll {
    $script:Repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:SkillsDir = Join-Path $Repo 'skills'
    $script:Pwsh = (Get-Process -Id $PID).Path
    $script:Root = Join-Path ([IO.Path]::GetTempPath()) "install tests $([guid]::NewGuid().ToString('N').Substring(0, 8))"
    $script:Skills = @(Get-ChildItem -LiteralPath $SkillsDir -Directory | Where-Object { Test-Path (Join-Path $_.FullName 'SKILL.md') } | ForEach-Object Name)
    $script:Kinds = if ($env:TEST_SCRIPT_KINDS) { $env:TEST_SCRIPT_KINDS -split ',' } elseif ($IsWindows) { @('ps1') } else { @('sh') }

    function script:New-Target {
        $t = Join-Path $Root "skills target $([guid]::NewGuid().ToString('N').Substring(0, 6))"
        New-Item -ItemType Directory -Force $t | Out-Null
        $t
    }
    # Runs the script with a sandbox home (so the role file is never the real one) and piped
    # input: the answers, one per line, or none. -Ask sets INSTALL_ROLES_PROMPT=1, which makes
    # the script ask although its input is not a terminal.
    function script:Invoke-Install([string] $Kind, [string[]] $Targets, [string] $HomeDir = (New-Target), [string[]] $Answers = @(), [switch] $Ask) {
        $saved = @{ HOME = $env:HOME; USERPROFILE = $env:USERPROFILE; INSTALL_ROLES_PROMPT = $env:INSTALL_ROLES_PROMPT }
        $env:HOME = $HomeDir; $env:USERPROFILE = $HomeDir
        $env:INSTALL_ROLES_PROMPT = if ($Ask) { '1' } else { $null }
        try {
            $out = if ($Kind -eq 'ps1') { $Answers | & $Pwsh -NoProfile -File (Join-Path $Repo 'scripts/install.ps1') @Targets 2>&1 }
                   else { $Answers | & sh (Join-Path $Repo 'scripts/install.sh') @Targets 2>&1 }
            $code = $LASTEXITCODE
        } finally { foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) } }
        [pscustomobject]@{ Out = @($out | ForEach-Object { "$_" }); Code = $code; Text = (@($out | ForEach-Object { "$_" }) -join "`n") }
    }
    function script:Get-RoleFile([string] $HomeDir) { Join-Path $HomeDir '.agents/roles.json' }
    function script:Read-RoleFile([string] $HomeDir) { Get-Content -LiteralPath (Get-RoleFile $HomeDir) -Raw | ConvertFrom-Json -AsHashtable }
    $script:RolesFlag = @{ ps1 = '-Roles'; sh = '--roles' }
    # The menu the scripts offer, read from the same file (no model ids in the tests).
    $script:Menu = @{}
    foreach ($line in Get-Content -LiteralPath (Join-Path $Repo 'scripts/models.txt')) {
        $f = @(-split $line)
        if ($f.Count -lt 2 -or $f[0].StartsWith('#')) { continue }
        if (-not $Menu.Contains($f[0])) { $Menu[$f[0]] = [Collections.Generic.List[string]]::new() }
        $Menu[$f[0]].Add($f[1])
    }
    function script:Get-LinkTarget([string] $Path) {
        $item = Get-Item -LiteralPath $Path -Force
        if (-not $item.LinkType) { return $null }
        $item.ResolveLinkTarget($true).FullName.TrimEnd('\', '/')
    }
    function script:New-Link([string] $Path, [string] $Target) {
        if ($IsWindows) { New-Item -ItemType Junction -Path $Path -Target $Target | Out-Null }
        else { New-Item -ItemType SymbolicLink -Path $Path -Target $Target | Out-Null }
    }
}

AfterAll {
    # Remove links first, without following them into the repository.
    Get-ChildItem -LiteralPath $Root -Recurse -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object LinkType | ForEach-Object { [IO.Directory]::Delete($_.FullName, $false) }
    Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'install.<Kind>' -ForEach @(@{ Kind = 'ps1' }, @{ Kind = 'sh' }) {
    BeforeAll { $script:Skip = $Kind -notin $Kinds }

    It 'links every skill under skills/ into each target folder' {
        if ($Skip) { Set-ItResult -Skipped -Because "TEST_SCRIPT_KINDS excludes $Kind"; return }
        $Skills.Count | Should -BeGreaterThan 10
        $a = New-Target; $b = New-Target
        $r = Invoke-Install $Kind @($a, $b)
        $r.Code | Should -Be 0
        foreach ($t in $a, $b) {
            foreach ($s in $Skills) { Get-LinkTarget (Join-Path $t $s) | Should -Be (Join-Path $SkillsDir $s) }
        }
    }
    It 'with no target, uses ~/.claude/skills and ~/.agents/skills' {
        if ($Skip) { Set-ItResult -Skipped -Because "TEST_SCRIPT_KINDS excludes $Kind"; return }
        $home2 = New-Target
        $r = Invoke-Install $Kind @() -HomeDir $home2
        $r.Code | Should -Be 0
        Get-LinkTarget (Join-Path $home2 '.claude/skills/delegate') | Should -Be (Join-Path $SkillsDir 'delegate')
        Get-LinkTarget (Join-Path $home2 '.agents/skills/delegate') | Should -Be (Join-Path $SkillsDir 'delegate')
    }
    It 'uses a junction on Windows and a symbolic link elsewhere' {
        if ($Skip) { Set-ItResult -Skipped -Because "TEST_SCRIPT_KINDS excludes $Kind"; return }
        $t = New-Target
        $null = Invoke-Install $Kind @($t)
        $expected = if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }
        (Get-Item -LiteralPath (Join-Path $t 'delegate') -Force).LinkType | Should -Be $expected
    }
    It 'creates a target folder that does not exist' {
        if ($Skip) { Set-ItResult -Skipped -Because "TEST_SCRIPT_KINDS excludes $Kind"; return }
        $t = Join-Path (New-Target) 'not yet'
        (Invoke-Install $Kind @($t)).Code | Should -Be 0
        Test-Path -LiteralPath (Join-Path $t 'plan/SKILL.md') | Should -BeTrue
    }
    It 'running it twice changes nothing' {
        if ($Skip) { Set-ItResult -Skipped -Because "TEST_SCRIPT_KINDS excludes $Kind"; return }
        $t = New-Target
        $null = Invoke-Install $Kind @($t)
        $snap = { Get-ChildItem -LiteralPath $t -Force | ForEach-Object { "$($_.Name)|$($_.LinkType)|$(Get-LinkTarget $_.FullName)|$($_.CreationTimeUtc.Ticks)" } }
        $before = & $snap
        $r = Invoke-Install $Kind @($t)
        $r.Code | Should -Be 0
        ($r.Out -join "`n") | Should -Match 'already linked'
        ($r.Out -join "`n") | Should -Not -Match '(?m)^linked:'
        & $snap | Should -Be $before
    }
    It 'never replaces a real directory: reports it, skips it, and exits 1' {
        if ($Skip) { Set-ItResult -Skipped -Because "TEST_SCRIPT_KINDS excludes $Kind"; return }
        $t = New-Target
        $real = Join-Path $t 'orchestrate'
        New-Item -ItemType Directory $real | Out-Null
        Set-Content -LiteralPath (Join-Path $real 'SKILL.md') -Value 'the owner''s own copy'
        $r = Invoke-Install $Kind @($t)
        $r.Code | Should -Be 1
        ($r.Out -join "`n") | Should -Match 'orchestrate.*real directory'
        (Get-Item -LiteralPath $real -Force).LinkType | Should -BeNullOrEmpty
        Get-Content -LiteralPath (Join-Path $real 'SKILL.md') | Should -Be 'the owner''s own copy'
        Get-LinkTarget (Join-Path $t 'plan') | Should -Be (Join-Path $SkillsDir 'plan')
    }
    It 'leaves a link that points somewhere else alone, and says so' {
        if ($Skip) { Set-ItResult -Skipped -Because "TEST_SCRIPT_KINDS excludes $Kind"; return }
        $t = New-Target
        $elsewhere = Join-Path $Root "elsewhere $([guid]::NewGuid().ToString('N').Substring(0, 6))"
        New-Item -ItemType Directory $elsewhere | Out-Null
        $link = Join-Path $t 'council'
        New-Link $link $elsewhere
        $r = Invoke-Install $Kind @($t)
        $r.Code | Should -Be 1
        ($r.Out -join "`n") | Should -Match 'council.*points to'
        Get-LinkTarget $link | Should -Be $elsewhere.TrimEnd('\', '/')
    }
    It 'leaves everything else in the target folder as it is' {
        if ($Skip) { Set-ItResult -Skipped -Because "TEST_SCRIPT_KINDS excludes $Kind"; return }
        $t = New-Target
        $mine = Join-Path $t 'my-own-skill'
        New-Item -ItemType Directory $mine | Out-Null
        Set-Content -LiteralPath (Join-Path $mine 'SKILL.md') -Value 'mine'
        $null = Invoke-Install $Kind @($t)
        Get-Content -LiteralPath (Join-Path $mine 'SKILL.md') | Should -Be 'mine'
        @(Get-ChildItem -LiteralPath $t -Force).Count | Should -Be ($Skills.Count + 1)
    }
    It 'sibling references resolve through the links' {
        if ($Skip) { Set-ItResult -Skipped -Because "TEST_SCRIPT_KINDS excludes $Kind"; return }
        $t = New-Target
        $null = Invoke-Install $Kind @($t)
        Test-Path -LiteralPath (Join-Path $t 'orchestrate/../babysit-pr/SKILL.md') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $t 'delegate/scripts/agent-run.ps1') | Should -BeTrue
    }

    Context 'the role file' {
        It 'without a terminal, says how to make a missing role file and writes nothing' {
            if ($Skip) { Set-ItResult -Skipped -Because "TEST_SCRIPT_KINDS excludes $Kind"; return }
            $h = New-Target
            $r = Invoke-Install $Kind @((New-Target)) -HomeDir $h
            $r.Code | Should -Be 0
            $r.Text | Should -Match "no role file.*$([regex]::Escape($RolesFlag[$Kind]))"
            $r.Text | Should -Not -Match '\[Y/n\]'
            Test-Path -LiteralPath (Get-RoleFile $h) | Should -BeFalse
        }
        It 'leaves an existing role file alone and names the option that changes it' {
            if ($Skip) { Set-ItResult -Skipped -Because "TEST_SCRIPT_KINDS excludes $Kind"; return }
            $h = New-Target
            New-Item -ItemType Directory (Split-Path (Get-RoleFile $h)) | Out-Null
            Set-Content -LiteralPath (Get-RoleFile $h) -Value '{"roles":{}}' -NoNewline
            $r = Invoke-Install $Kind @((New-Target)) -HomeDir $h -Ask
            $r.Code | Should -Be 0
            $r.Text | Should -Match "is set up.*$([regex]::Escape($RolesFlag[$Kind]))"
            Get-Content -LiteralPath (Get-RoleFile $h) -Raw | Should -Be '{"roles":{}}'
        }
        It 'when it is missing, asks for every role and writes what was answered' {
            if ($Skip) { Set-ItResult -Skipped -Because "TEST_SCRIPT_KINDS excludes $Kind"; return }
            $h = New-Target; $t = New-Target
            $answers = @(
                'y'                                  # set it up now
                'claude', 'model-a', 'high'          # planner
                'cursor', 'model-backup'             # planner fallback
                'bogus', ''                          # coder-mechanical: left to the next coder role
                'codex', '', 'model-b', ''           # coder-simple: the model is asked again until given
                ''                                   # no coder-simple fallback
                'claude', 'model-m', ''              # coder-moderate
                ''                                   # no coder-moderate fallback
                ''                                   # coder-complex: left unavailable
                'bogus', 'cursor', 'model-c'         # reviewer: an unknown harness is asked again; cursor asks no effort
                ''                                   # no reviewer fallback
                'claude', '2', 'max'                 # council-a: the second listed model
                ''                                   # no council-a fallback
                'codex', '99', '1', 'high'           # council-b: a number off the list is asked again
                ''                                   # no council-b fallback
                '', 'n', 'y'                         # overrides: none for claude or codex; cursor has one
                '', ''                               # cursor: no planner, no coder-mechanical
                'cursor', 'model-f', 'claude', 'model-host-backup', 'high'   # coder-simple and its fallback
                '', '', '', '', ''                   # the other five: none
                ''                                   # write it
            )
            $r = Invoke-Install $Kind @($t) -HomeDir $h -Answers $answers -Ask
            $r.Code | Should -Be 0
            $r.Text | Should -Match 'harness is claude, codex or cursor; - leaves the role to the next coder role\.'
            $r.Text | Should -Match 'harness is claude, codex or cursor; - leaves the role unavailable\.'
            $r.Text | Should -Match 'a model is needed'
            $r.Text | Should -Match 'codex debug models'
            $r.Text | Should -Match 'there is no 99 in the list'
            # Piped answers are not echoed, so the menu starts on the harness question's line.
            $r.Text | Should -Match ("\s1\) $([regex]::Escape($Menu.cursor[0]))\s+2\) $([regex]::Escape($Menu.cursor[1]))\s+3\) ")
            ([regex]::Matches($r.Text, 'effort \(optional\)')).Count | Should -Be 6
            Get-LinkTarget (Join-Path $t 'plan') | Should -Be (Join-Path $SkillsDir 'plan')
            $doc = Read-RoleFile $h
            $doc['$comment'] | Should -Match ([regex]::Escape($RolesFlag[$Kind]))
            @($doc.roles.Keys) | Should -Be @('planner', 'coder-simple', 'coder-moderate', 'reviewer', 'council-a', 'council-b')
            "$($doc.roles['coder-moderate'].harness)/$($doc.roles['coder-moderate'].model)" | Should -Be 'claude/model-m'
            $doc.roles.planner | Should -BeOfType [System.Collections.IDictionary]
            "$($doc.roles.planner.harness)/$($doc.roles.planner.model)/$($doc.roles.planner.effort)" | Should -Be 'claude/model-a/high'
            "$($doc.roles.planner.fallback.harness)/$($doc.roles.planner.fallback.model)" | Should -Be 'cursor/model-backup'
            "$($doc.roles['coder-simple'].harness)/$($doc.roles['coder-simple'].model)" | Should -Be 'codex/model-b'
            $doc.roles['coder-simple'].Contains('effort') | Should -BeFalse
            $doc.roles['coder-simple'].Contains('fallback') | Should -BeFalse
            "$($doc.roles.reviewer.harness)/$($doc.roles.reviewer.model)" | Should -Be 'cursor/model-c'
            $doc.roles.reviewer.Contains('effort') | Should -BeFalse
            "$($doc.roles['council-a'].model)/$($doc.roles['council-a'].effort)" | Should -Be "$($Menu.claude[1])/max"
            "$($doc.roles['council-b'].model)/$($doc.roles['council-b'].effort)" | Should -Be "$($Menu.codex[0])/high"
            @($doc.hostOverrides.Keys) | Should -Be @('cursor')
            @($doc.hostOverrides.cursor.Keys) | Should -Be @('coder-simple')
            "$($doc.hostOverrides.cursor['coder-simple'].harness)/$($doc.hostOverrides.cursor['coder-simple'].model)" | Should -Be 'cursor/model-f'
            $doc.hostOverrides.cursor['coder-simple'].fallback.effort | Should -Be 'high'
            $doc.hostOverrides.cursor['coder-simple'].fallback.model | Should -Be 'model-host-backup'
            Test-Path -LiteralPath "$(Get-RoleFile $h).bak" | Should -BeFalse
        }
        It 'answering no to setting it up writes nothing' {
            if ($Skip) { Set-ItResult -Skipped -Because "TEST_SCRIPT_KINDS excludes $Kind"; return }
            $h = New-Target
            $r = Invoke-Install $Kind @((New-Target)) -HomeDir $h -Answers @('n') -Ask
            $r.Code | Should -Be 0
            $r.Text | Should -Match 'not set up'
            Test-Path -LiteralPath (Get-RoleFile $h) | Should -BeFalse
        }
        It 'the roles option asks again with the current values, keeps other keys, and keeps a backup' {
            if ($Skip) { Set-ItResult -Skipped -Because "TEST_SCRIPT_KINDS excludes $Kind"; return }
            $h = New-Target
            New-Item -ItemType Directory (Split-Path (Get-RoleFile $h)) | Out-Null
            $old = @'
{
  "$comment": "keep me",
  "roles": {
    "planner": { "harness": "claude", "model": "old-p", "effort": "high", "fallback": { "harness": "cursor", "model": "old-backup" } },
    "coder-simple": { "harness": "codex", "model": "old-s", "fallback": { "harness": "claude", "model": "old-s-backup" } },
    "coder-complex": { "harness": "claude", "model": "old-c", "effort": "xhigh" },
    "reviewer": { "harness": "cursor", "model": "old-r", "effort": "low" },
    "council-a": { "harness": "claude", "model": "old-a" },
    "council-b": { "harness": "codex", "model": "old-b", "effort": "high" }
  },
  "hostOverrides": { "cursor": { "coder-simple": { "harness": "cursor", "model": "old-cs" } } },
  "other": 1
}
'@
            Set-Content -LiteralPath (Get-RoleFile $h) -Value $old -NoNewline
            $answers = @(
                'codex', 'model-z', ''               # planner: a new harness offers no old model or effort
                '', ''                               # keep planner fallback
                ''                                   # coder-mechanical: new to this file, left out
                '', '', ''                           # coder-simple: kept
                '-'                                  # clear coder-simple fallback
                ''                                   # coder-moderate: new to this file, left out
                '', '', ''                           # coder-complex: kept
                ''                                   # no coder-complex fallback
                '', ''                               # reviewer: cursor asks no effort, so the old one goes
                ''                                   # no reviewer fallback
                '', '', ''                           # council-a: kept
                ''                                   # no council-a fallback
                '-'                                  # council-b: cleared
                '', '', ''                           # overrides: none for claude or codex; cursor kept (default yes)
                '', '', '', '', '', '', '', '', '', ''   # cursor: coder-simple kept (three answers) with no fallback, the other seven none
                ''                                   # write it
            )
            $r = Invoke-Install $Kind @($RolesFlag[$Kind]) -HomeDir $h -Answers $answers -Ask
            $r.Code | Should -Be 0
            $r.Text | Should -Match '\[old-s\]'
            $r.Text | Should -Not -Match '(?m)^linked:'
            Test-Path -LiteralPath (Join-Path $h '.claude') | Should -BeFalse
            $doc = Read-RoleFile $h
            @($doc.Keys) | Should -Be @('$comment', 'roles', 'hostOverrides', 'other')
            $doc['$comment'] | Should -Be 'keep me'
            $doc.other | Should -Be 1
            @($doc.roles.Keys) | Should -Be @('planner', 'coder-simple', 'coder-complex', 'reviewer', 'council-a')
            "$($doc.roles.planner.harness)/$($doc.roles.planner.model)" | Should -Be 'codex/model-z'
            $doc.roles.planner.Contains('effort') | Should -BeFalse
            $doc.roles.planner.fallback.model | Should -Be 'old-backup'
            $doc.roles['coder-simple'].Contains('fallback') | Should -BeFalse
            "$($doc.roles['coder-complex'].model)/$($doc.roles['coder-complex'].effort)" | Should -Be 'old-c/xhigh'
            $doc.roles.reviewer.Contains('effort') | Should -BeFalse
            "$($doc.hostOverrides.cursor['coder-simple'].model)" | Should -Be 'old-cs'
            Get-Content -LiteralPath "$(Get-RoleFile $h).bak" -Raw | Should -Be $old
        }
        It 'answering no at the end leaves the role file as it was' {
            if ($Skip) { Set-ItResult -Skipped -Because "TEST_SCRIPT_KINDS excludes $Kind"; return }
            $h = New-Target
            New-Item -ItemType Directory (Split-Path (Get-RoleFile $h)) | Out-Null
            Set-Content -LiteralPath (Get-RoleFile $h) -Value '{"roles":{}}' -NoNewline
            $answers = @('claude', 'model-a', '', '') + @('') * 7 + @('', '', '') + @('n')
            $r = Invoke-Install $Kind @($RolesFlag[$Kind]) -HomeDir $h -Answers $answers -Ask
            $r.Code | Should -Be 0
            $r.Text | Should -Match 'Not written'
            Get-Content -LiteralPath (Get-RoleFile $h) -Raw | Should -Be '{"roles":{}}'
            Test-Path -LiteralPath "$(Get-RoleFile $h).bak" | Should -BeFalse
        }
        It 'the roles option without a terminal stops with exit 2' {
            if ($Skip) { Set-ItResult -Skipped -Because "TEST_SCRIPT_KINDS excludes $Kind"; return }
            $h = New-Target
            $r = Invoke-Install $Kind @($RolesFlag[$Kind]) -HomeDir $h
            $r.Code | Should -Be 2
            $r.Text | Should -Match 'need a terminal'
            Test-Path -LiteralPath (Get-RoleFile $h) | Should -BeFalse
        }
        It 'input that ends early writes nothing and stops with exit 2' {
            if ($Skip) { Set-ItResult -Skipped -Because "TEST_SCRIPT_KINDS excludes $Kind"; return }
            $h = New-Target
            $r = Invoke-Install $Kind @($RolesFlag[$Kind]) -HomeDir $h -Answers @('claude', 'model-a') -Ask
            $r.Code | Should -Be 2
            $r.Text | Should -Match 'Input ended'
            Test-Path -LiteralPath (Get-RoleFile $h) | Should -BeFalse
        }
        It 'a role file that is not JSON is reported and left alone' {
            if ($Skip) { Set-ItResult -Skipped -Because "TEST_SCRIPT_KINDS excludes $Kind"; return }
            $h = New-Target
            New-Item -ItemType Directory (Split-Path (Get-RoleFile $h)) | Out-Null
            Set-Content -LiteralPath (Get-RoleFile $h) -Value 'not json' -NoNewline
            $r = Invoke-Install $Kind @($RolesFlag[$Kind]) -HomeDir $h -Ask
            $r.Code | Should -Be 1
            $r.Text | Should -Match 'not a JSON object'
            Get-Content -LiteralPath (Get-RoleFile $h) -Raw | Should -Be 'not json'
        }
    }
}
