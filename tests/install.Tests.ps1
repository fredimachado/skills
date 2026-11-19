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
    function script:Invoke-Install([string] $Kind, [string[]] $Targets) {
        $out = if ($Kind -eq 'ps1') { & $Pwsh -NoProfile -File (Join-Path $Repo 'scripts/install.ps1') @Targets 2>&1 }
               else { & sh (Join-Path $Repo 'scripts/install.sh') @Targets 2>&1 }
        [pscustomobject]@{ Out = @($out | ForEach-Object { "$_" }); Code = $LASTEXITCODE }
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
        $saved = @{ HOME = $env:HOME; USERPROFILE = $env:USERPROFILE }
        $env:HOME = $home2; $env:USERPROFILE = $home2
        try { $r = Invoke-Install $Kind @() } finally { $env:HOME = $saved.HOME; $env:USERPROFILE = $saved.USERPROFILE }
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
}
