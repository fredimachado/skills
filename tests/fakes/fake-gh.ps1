# Fake gh for the pr-wait.ps1 tests. Replays fixtures from $env:FAKE_GH_DIR.
#
# Each call maps to a key: `api <path>` uses the path without its query string, with
# '/' replaced by '_' (for example repos_o_r_pulls_7); `api graphql` is `graphql`;
# other commands join their first two words (auth_status, repo_view).
# For a key, the fake prints <key>.json, or when numbered files exist, the Nth call
# gets <key>.N.json or <key>.N.err (the last number repeats). An .err file's text goes
# to stderr and the call exits 1. A missing fixture is an error that names the key.
# Every call is appended to $env:FAKE_GH_LOG when it is set.

$ErrorActionPreference = 'Stop'
$dir = $env:FAKE_GH_DIR
$a = @($args)

if ($a[0] -eq 'api') {
    $path = ''
    for ($i = 1; $i -lt $a.Count; $i++) {
        if ($a[$i] -in '-f', '-F', '--method', '-X', '-H', '--jq', '-q') { $i++; continue }
        if ($a[$i].StartsWith('-')) { continue }
        $path = $a[$i]; break
    }
    $key = ($path -replace '\?.*$', '') -replace '[/:]', '_'
} else {
    $key = "$($a[0])_$($a[1])"
}

if ($env:FAKE_GH_LOG) { Add-Content -LiteralPath $env:FAKE_GH_LOG -Value "$key $($a -join ' ')" }

$numbered = @(Get-ChildItem -LiteralPath $dir -File | Where-Object { $_.Name -match "^$([regex]::Escape($key))\.(\d+)\.(json|err)$" })
if ($numbered.Count -gt 0) {
    $counter = Join-Path $dir ".count-$key"
    $n = 1 + $(if (Test-Path -LiteralPath $counter) { [int](Get-Content -LiteralPath $counter) } else { 0 })
    Set-Content -LiteralPath $counter -Value $n
    $max = ($numbered | ForEach-Object { [int]($_.Name -replace '^.*\.(\d+)\.(json|err)$', '$1') } | Measure-Object -Maximum).Maximum
    $n = [math]::Min($n, $max)
    $file = $numbered | Where-Object { $_.Name -match "\.$n\.(json|err)$" } | Select-Object -First 1
} else {
    $file = Get-Item -LiteralPath (Join-Path $dir "$key.json") -ErrorAction SilentlyContinue
    if (-not $file) { $file = Get-Item -LiteralPath (Join-Path $dir "$key.err") -ErrorAction SilentlyContinue }
}

if (-not $file) { [Console]::Error.WriteLine("fake gh: no fixture for key '$key'"); exit 1 }
$text = Get-Content -LiteralPath $file.FullName -Raw
if ($file.Extension -eq '.err') { [Console]::Error.WriteLine($text.Trim()); exit 1 }
[Console]::Out.Write($text)
exit 0
