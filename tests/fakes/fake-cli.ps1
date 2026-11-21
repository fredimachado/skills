# Fake claude / codex / cursor-agent for the agent-run.ps1 tests.
# The first argument names the CLI being faked; the rest are its arguments.
# Behaviour comes from environment variables so a test can set it per run:
#   FAKE_CLI_LOG       file to append one JSON line per call (args, cwd, stdin, guard)
#   FAKE_CLI_MODE      ok | malformed | hang | fail | refusemodel | signedout | wrongmodel | scribble
#                      (scribble writes scribble.txt in the working directory, then succeeds)
#                      quota | quota-stderr | quota-scribble | transient
#   FAKE_CLI_RESULT    final message text (default "fake result")
#   FAKE_CLI_MODELS    comma-separated models the CLI offers
#   FAKE_CLI_HELP_DROP a flag to leave out of --help output
#   FAKE_CLI_PIDFILE   file to write the hanging child's process id to

$ErrorActionPreference = 'Stop'
$cli = $args[0]
$rest = @($args | Select-Object -Skip 1)
$mode = if ($env:FAKE_CLI_MODE) { $env:FAKE_CLI_MODE } else { 'ok' }
$result = if ($env:FAKE_CLI_RESULT) { $env:FAKE_CLI_RESULT } else { 'fake result' }
$models = if ($env:FAKE_CLI_MODELS) { $env:FAKE_CLI_MODELS -split ',' } else { @('m1', 'm2') }

function Write-Help([string[]] $flags) {
    $flags | Where-Object { $_ -ne $env:FAKE_CLI_HELP_DROP } | ForEach-Object { "  $_   fake option" }
}

function Get-ArgValue([string] $name) {
    $i = [array]::IndexOf($rest, $name)
    if ($i -ge 0 -and $i + 1 -lt $rest.Count) { return $rest[$i + 1] }
    return $null
}

$isRun = ($cli -eq 'codex' -and $rest[0] -eq 'exec' -and $rest -notcontains '--help') -or
         ($cli -ne 'codex' -and ($rest -contains '-p'))
$stdin = if ($isRun) { [Console]::In.ReadToEnd() } else { '' }

if ($env:FAKE_CLI_LOG) {
    [pscustomobject]@{
        cli = $cli; args = $rest; cwd = (Get-Location).Path; stdin = $stdin
        guard = $env:AGENT_SKILLS_DELEGATE
    } | ConvertTo-Json -Compress -Depth 5 | Add-Content -LiteralPath $env:FAKE_CLI_LOG -Encoding utf8
}

if ($rest -contains '--version' -or $rest -contains '-V') { "$cli 9.9.9"; exit 0 }

# Help text: every flag the real CLI documents that agent-run.ps1 relies on.
switch ($cli) {
    'claude' {
        if ($rest -contains '--help') {
            Write-Help '-p', '--model', '--effort', '--permission-mode', '--tools', '--allowedTools',
                '--output-format', '--json-schema', '--resume', '--add-dir'
            exit 0
        }
        if ($rest[0] -eq 'auth') {
            if ($mode -eq 'signedout') { '{"loggedIn": false}'; exit 1 }
            '{"loggedIn": true}'; exit 0
        }
    }
    'codex' {
        if ($rest -contains '--help') {
            Write-Help '-m', '-s', '-C', '--json', '-o', '--output-schema', '-c', 'resume',
                '--dangerously-bypass-approvals-and-sandbox'
            exit 0
        }
        if ($rest[0] -eq 'login') {
            if ($mode -eq 'signedout') { 'Not logged in'; exit 1 }
            'Logged in using ChatGPT'; exit 0
        }
        if ($rest[0] -eq 'debug') {
            @{ models = @($models | ForEach-Object { @{ slug = $_ } }) } | ConvertTo-Json -Depth 4 -Compress
            exit 0
        }
    }
    'cursor-agent' {
        if ($rest -contains '--help') {
            Write-Help '-p', '--model', '--mode', '-f', '--sandbox', '--trust', '--workspace', '--output-format',
                '--resume', '--list-models', '--add-dir'
            exit 0
        }
        if ($rest -contains '--list-models') {
            'Available models'; ''
            $models | ForEach-Object { "$_ - $_ name" }
            exit 0
        }
        if ($rest[0] -eq 'status') {
            if ($mode -eq 'signedout') { 'Not logged in'; exit 1 }
            'Logged in as someone'; exit 0
        }
    }
}

# A run.
switch ($mode) {
    'hang' {
        # Start a child that would outlive us, to prove the whole tree is killed.
        $child = Start-Process -FilePath (Get-Process -Id $PID).Path -PassThru -NoNewWindow `
            -ArgumentList '-NoProfile', '-Command', 'Start-Sleep -Seconds 120'
        if ($env:FAKE_CLI_PIDFILE) { Set-Content -LiteralPath $env:FAKE_CLI_PIDFILE -Value $child.Id }
        Start-Sleep -Seconds 120
        exit 0
    }
    'fail' { [Console]::Error.WriteLine('fake failure'); exit 3 }
    'transient' { [Console]::Error.WriteLine('HTTP 429: rate limit exceeded'); exit 1 }
    'quota-stderr' { [Console]::Error.WriteLine("Error: You've hit your usage limit."); exit 1 }
    'refusemodel' { [Console]::Error.WriteLine('Cannot use this model: m1. Available models: x'); exit 1 }
    'malformed' { 'this is not json {'; exit 0 }
    'scribble' { Set-Content -LiteralPath (Join-Path (Get-Location) 'scribble.txt') -Value 'x' }
    'quota-scribble' { Set-Content -LiteralPath (Join-Path (Get-Location) 'scribble.txt') -Value 'x' }
}

$session = '11111111-2222-3333-4444-555555555555'
if ($mode -in 'quota', 'quota-scribble') {
    switch ($cli) {
        'claude' {
            @{ type = 'result'; is_error = $true; session_id = $session
               result = "You’ve hit your 5-hour limit · resets 3:45pm" } | ConvertTo-Json -Compress
            exit 0
        }
        'codex' {
            "{`"type`":`"thread.started`",`"thread_id`":`"$session`"}"
            '{"type":"turn.failed","error":{"code":"usage_limit_reached","message":"Cannot start a turn."}}'
            exit 1
        }
        'cursor-agent' {
            @{ type = 'result'; is_error = $true; session_id = $session
               result = "You've hit your usage limit." } | ConvertTo-Json -Compress
            exit 1
        }
    }
}

switch ($cli) {
    'claude' {
        $model = Get-ArgValue '--model'
        $reported = if ($mode -eq 'wrongmodel') { 'some-other-model' } else { "claude-$model-9" }
        $out = [ordered]@{ type = 'result'; subtype = 'success'; is_error = $false; result = $result
            session_id = (Get-ArgValue '--resume') ?? $session; modelUsage = @{ $reported = @{ outputTokens = 5 } } }
        if ($rest -contains '--json-schema') { $out.structured_output = ($result | ConvertFrom-Json) }
        $out | ConvertTo-Json -Depth 5 -Compress
    }
    'codex' {
        $outFile = Get-ArgValue '-o'
        $thread = if ($rest[1] -eq 'resume') { $rest[-2] } else { $session }
        '{"type":"thread.started","thread_id":"' + $thread + '"}'
        '{"type":"turn.started"}'
        '{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"done"}}'
        '{"type":"turn.completed","usage":{"output_tokens":5}}'
        if ($outFile) { Set-Content -LiteralPath $outFile -Value $result -Encoding utf8 -NoNewline }
    }
    'cursor-agent' {
        [ordered]@{ type = 'result'; subtype = 'success'; is_error = $false; result = $result
            session_id = (Get-ArgValue '--resume') ?? $session } | ConvertTo-Json -Compress
    }
}
exit 0
