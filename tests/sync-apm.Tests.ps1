#Requires -Version 7.2
# Pester 5 tests for scripts/sync-apm.ps1 (Windows) and scripts/sync-apm.sh (Linux, macOS),
# against a fake apm and temporary folders. TEST_SCRIPT_KINDS picks which run
# (comma-separated: ps1, sh); by default ps1 on Windows and sh elsewhere.

BeforeAll {
    $script:Pwsh = (Get-Process -Id $PID).Path
    $script:Root = Join-Path ([IO.Path]::GetTempPath()) "sync apm tests $([guid]::NewGuid().ToString('N').Substring(0, 8))"
    $script:Bin = Join-Path $Root 'fake bin'
    New-Item -ItemType Directory -Force $Bin | Out-Null
    $fake = Join-Path $Root 'fake-apm.ps1'
    # The fake records its arguments, APM_HOME and what it found there, then writes a lock
    # file there (or fails, when FAKE_APM_FAIL is set).
    Set-Content -LiteralPath $fake -Value @'
$home2 = $env:APM_HOME
Add-Content -LiteralPath $env:FAKE_APM_LOG -Value "$($args -join ' ')|$home2|$(Get-Content -LiteralPath (Join-Path $home2 'apm.yml') -Raw)|$(if (Test-Path (Join-Path $home2 'apm.lock.yaml')) { Get-Content -LiteralPath (Join-Path $home2 'apm.lock.yaml') -Raw } else { 'no-lock' })"
if ($env:FAKE_APM_FAIL) { [Console]::Error.WriteLine('fake apm failure'); exit 1 }
Set-Content -LiteralPath (Join-Path $home2 'apm.lock.yaml') -Value 'lock written by apm' -NoNewline
exit 0
'@
    if ($IsWindows) {
        Set-Content -LiteralPath (Join-Path $Bin 'apm.cmd') -Encoding ascii -Value "@`"$Pwsh`" -NoProfile -File `"$fake`" %*"
    } else {
        $p = Join-Path $Bin 'apm'
        Set-Content -LiteralPath $p -Value "#!/bin/sh`nexec `"$Pwsh`" -NoProfile -File `"$fake`" `"`$@`""
        chmod +x $p
    }

    # A copy of the repository layout: scripts/sync-apm.* and apm/apm.yml.
    function script:New-Repo {
        $r = Join-Path $Root "repo $([guid]::NewGuid().ToString('N').Substring(0, 6))"
        New-Item -ItemType Directory -Force (Join-Path $r 'scripts'), (Join-Path $r 'apm') | Out-Null
        foreach ($f in 'sync-apm.ps1', 'sync-apm.sh') {
            Copy-Item -LiteralPath (Join-Path $PSScriptRoot "../scripts/$f") -Destination (Join-Path $r 'scripts')
        }
        Set-Content -LiteralPath (Join-Path $r 'apm/apm.yml') -Value 'manifest from repo' -NoNewline
        $r
    }
    function script:Invoke-Sync([string] $Kind, [string] $Repo, [string] $ApmHome, [hashtable] $Env = @{}, [string[]] $PathDir = @($Bin), [string] $Answer = '') {
        $log = Join-Path $Root "apm-calls-$([guid]::NewGuid().ToString('N')).log"
        $sep = [IO.Path]::PathSeparator
        $path = @($PathDir) + $(if ($IsWindows) { @("$env:SystemRoot\System32") } else { @('/usr/bin', '/bin') })
        # A sandbox home, so the scripts' look into the usual install folders never finds a
        # real apm on this machine.
        $sandbox = Join-Path $Root "sandbox home $([guid]::NewGuid().ToString('N').Substring(0, 6))"
        New-Item -ItemType Directory -Force $sandbox | Out-Null
        $vars = @{ PATH = ($path -join $sep); FAKE_APM_LOG = $log; APM_HOME = $ApmHome; FAKE_APM_FAIL = $null
                   SYNC_APM_PROMPT = $null; SYNC_APM_INSTALL_COMMAND = $null
                   HOME = $sandbox; LOCALAPPDATA = $sandbox }
        foreach ($k in $Env.Keys) { $vars[$k] = $Env[$k] }
        $saved = @{}
        foreach ($k in $vars.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $vars[$k]) }
        try {
            # Both read APM_HOME; the sh script runs with /bin/sh, as a user would. Input is
            # always piped (the answer to the prompt, or nothing), so neither sees a terminal.
            $out = if ($Kind -eq 'ps1') { $Answer | & $Pwsh -NoProfile -File (Join-Path $Repo 'scripts/sync-apm.ps1') 2>&1 }
                   else { $Answer | & /bin/sh (Join-Path $Repo 'scripts/sync-apm.sh') 2>&1 }
            $code = $LASTEXITCODE
        } finally { foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) } }
        [pscustomobject]@{ Out = @($out | ForEach-Object { "$_" }); Code = $code
                           Calls = @(if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log }) }
    }
    function script:New-ApmHome { Join-Path $Root "apm home $([guid]::NewGuid().ToString('N').Substring(0, 6))" }

    # The fake apm launcher, kept outside PATH, for a fake installer to copy into a PATH folder.
    $script:Staged = Join-Path $Root 'staged'
    New-Item -ItemType Directory -Force $Staged | Out-Null
    $script:LauncherName = if ($IsWindows) { 'apm.cmd' } else { 'apm' }
    Copy-Item -LiteralPath (Join-Path $Bin $LauncherName) -Destination $Staged
    # A fake install command, in the language each script runs it with.
    function script:Get-FakeInstall([string] $Kind, [string] $IntoDir) {
        $from = Join-Path $Staged $LauncherName
        $to = Join-Path $IntoDir $LauncherName
        if ($Kind -eq 'ps1') { "Copy-Item -LiteralPath '$from' -Destination '$to'" }
        else { "cp '$from' '$to' && chmod +x '$to'" }
    }
    function script:New-EmptyDir([string] $Name) {
        $d = Join-Path $Root "$Name $([guid]::NewGuid().ToString('N').Substring(0, 6))"
        New-Item -ItemType Directory -Force $d | Out-Null
        $d
    }
}

AfterAll { Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue }

Describe 'sync-apm.<Kind>' -ForEach @(@{ Kind = 'ps1' }, @{ Kind = 'sh' }) {
    BeforeAll {
        $kinds = if ($env:TEST_SCRIPT_KINDS) { $env:TEST_SCRIPT_KINDS -split ',' } elseif ($IsWindows) { @('ps1') } else { @('sh') }
        $script:Skip = $Kind -notin $kinds
    }

    It 'copies the manifest to the APM home, runs a global install there, and brings the lock back' {
        if ($Skip) { Set-ItResult -Skipped -Because "TEST_SCRIPT_KINDS excludes $Kind"; return }
        $r = New-Repo; $apmHome = New-ApmHome
        $s = Invoke-Sync $Kind $r $apmHome
        $s.Code | Should -Be 0
        $s.Calls.Count | Should -Be 1
        $argsSeen, $homeSeen, $manifestSeen, $lockSeen = $s.Calls[0] -split '\|'
        $argsSeen | Should -Be 'install -g'
        $homeSeen | Should -Be $apmHome
        $manifestSeen | Should -Be 'manifest from repo'
        $lockSeen | Should -Be 'no-lock'
        Get-Content -LiteralPath (Join-Path $r 'apm/apm.lock.yaml') -Raw | Should -Be 'lock written by apm'
        ($s.Out -join "`n") | Should -Match 'commit it'
    }
    It 'gives APM the repository''s lock before installing, so the pinned versions are used' {
        if ($Skip) { Set-ItResult -Skipped -Because "TEST_SCRIPT_KINDS excludes $Kind"; return }
        $r = New-Repo; $apmHome = New-ApmHome
        Set-Content -LiteralPath (Join-Path $r 'apm/apm.lock.yaml') -Value 'lock from repo' -NoNewline
        $s = Invoke-Sync $Kind $r $apmHome
        ($s.Calls[0] -split '\|')[3] | Should -Be 'lock from repo'
    }
    It 'says when the lock did not change' {
        if ($Skip) { Set-ItResult -Skipped -Because "TEST_SCRIPT_KINDS excludes $Kind"; return }
        $r = New-Repo; $apmHome = New-ApmHome
        Set-Content -LiteralPath (Join-Path $r 'apm/apm.lock.yaml') -Value 'lock written by apm' -NoNewline
        $s = Invoke-Sync $Kind $r $apmHome
        $s.Code | Should -Be 0
        ($s.Out -join "`n") | Should -Match 'unchanged'
    }
    It 'a failed install leaves the repository''s lock alone and passes the exit code on' {
        if ($Skip) { Set-ItResult -Skipped -Because "TEST_SCRIPT_KINDS excludes $Kind"; return }
        $r = New-Repo; $apmHome = New-ApmHome
        Set-Content -LiteralPath (Join-Path $r 'apm/apm.lock.yaml') -Value 'lock from repo' -NoNewline
        $s = Invoke-Sync $Kind $r $apmHome -Env @{ FAKE_APM_FAIL = '1' }
        $s.Code | Should -Be 1
        Get-Content -LiteralPath (Join-Path $r 'apm/apm.lock.yaml') -Raw | Should -Be 'lock from repo'
    }
    It 'without a terminal, shows the install command and stops with exit 2, touching nothing' {
        if ($Skip) { Set-ItResult -Skipped -Because "TEST_SCRIPT_KINDS excludes $Kind"; return }
        $r = New-Repo; $apmHome = New-ApmHome
        $s = Invoke-Sync $Kind $r $apmHome -PathDir (New-EmptyDir 'empty bin')
        $s.Code | Should -Be 2
        $expected = if ($Kind -eq 'ps1' -and $IsWindows) { 'winget install --id Microsoft\.APM|aka\.ms/apm-windows' } else { 'curl -sSL https://aka\.ms/apm-unix \| sh' }
        ($s.Out -join "`n") | Should -Match $expected
        ($s.Out -join "`n") | Should -Not -Match '\[Y/n\]'
        Test-Path -LiteralPath $apmHome | Should -BeFalse
    }
    It 'asks [Y/n] with the command shown; "n" installs nothing and stops with exit 2' {
        if ($Skip) { Set-ItResult -Skipped -Because "TEST_SCRIPT_KINDS excludes $Kind"; return }
        $r = New-Repo; $apmHome = New-ApmHome
        $later = New-EmptyDir 'later bin'
        $install = Get-FakeInstall $Kind $later
        $s = Invoke-Sync $Kind $r $apmHome -PathDir $later -Answer 'n' -Env @{ SYNC_APM_PROMPT = '1'; SYNC_APM_INSTALL_COMMAND = $install }
        $s.Code | Should -Be 2
        ($s.Out -join "`n") | Should -Match '\[Y/n\]'
        ($s.Out -join "`n") | Should -Match ([regex]::Escape($install))
        Test-Path -LiteralPath (Join-Path $later $LauncherName) | Should -BeFalse
        $s.Calls.Count | Should -Be 0
    }
    It 'answer <Answer>: runs the command, finds apm and carries on with the sync' -ForEach @(@{ Answer = 'y' }, @{ Answer = '' }) {
        if ($Skip) { Set-ItResult -Skipped -Because "TEST_SCRIPT_KINDS excludes $Kind"; return }
        $r = New-Repo; $apmHome = New-ApmHome
        $later = New-EmptyDir 'later bin'
        $s = Invoke-Sync $Kind $r $apmHome -PathDir $later -Answer $Answer -Env @{ SYNC_APM_PROMPT = '1'; SYNC_APM_INSTALL_COMMAND = (Get-FakeInstall $Kind $later) }
        $s.Code | Should -Be 0
        Test-Path -LiteralPath (Join-Path $later $LauncherName) | Should -BeTrue
        $s.Calls.Count | Should -Be 1
        Get-Content -LiteralPath (Join-Path $r 'apm/apm.lock.yaml') -Raw | Should -Be 'lock written by apm'
    }
    It 'stops with exit 2 when the install command ran but apm is still not found' {
        if ($Skip) { Set-ItResult -Skipped -Because "TEST_SCRIPT_KINDS excludes $Kind"; return }
        $r = New-Repo; $apmHome = New-ApmHome
        $noop = if ($Kind -eq 'ps1') { '$null = 1' } else { 'true' }
        $s = Invoke-Sync $Kind $r $apmHome -PathDir (New-EmptyDir 'empty bin') -Answer 'y' -Env @{ SYNC_APM_PROMPT = '1'; SYNC_APM_INSTALL_COMMAND = $noop }
        $s.Code | Should -Be 2
        ($s.Out -join "`n") | Should -Match 'still not found'
    }
}
