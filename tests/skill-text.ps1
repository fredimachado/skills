#Requires -Version 7.2
# Checks on the skill texts themselves, used by skill-text.Tests.ps1. Each function returns
# one line per problem and nothing when all is well.
#
# Dot-source this file for the functions. Run it as a script to print every problem; it
# exits 1 when there is one:
#   pwsh -NoProfile -File tests/skill-text.ps1
param([string] $Root = (Join-Path $PSScriptRoot '..'))

function Get-SkillFolder([string] $Root) {
    Get-ChildItem -LiteralPath (Join-Path $Root 'skills') -Directory |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'SKILL.md') }
}

function Get-SkillMarkdown([string] $Root) {
    Get-SkillFolder $Root | ForEach-Object {
        $skill = $_
        Get-ChildItem -LiteralPath $skill.FullName -Recurse -File -Filter '*.md' | ForEach-Object {
            [pscustomobject]@{
                Path  = $_.FullName
                Dir   = $_.DirectoryName
                Skill = $skill.FullName
                Label = [IO.Path]::GetRelativePath($Root, $_.FullName).Replace('\', '/')
                Text  = Get-Content -LiteralPath $_.FullName -Raw
            }
        }
    }
}

# Every SKILL.md starts with front matter whose name is its folder's name, and has a
# description.
function Get-SkillFrontMatterProblem([string] $Root) {
    foreach ($skill in Get-SkillFolder $Root) {
        $text = Get-Content -LiteralPath (Join-Path $skill.FullName 'SKILL.md') -Raw
        if ($text -notmatch '(?s)\A---\r?\n(.*?)\r?\n---\r?\n') {
            "skills/$($skill.Name)/SKILL.md: no front matter"
            continue
        }
        $front = $Matches[1]
        if ($front -notmatch "(?m)^name:\s*$([regex]::Escape($skill.Name))\s*$") {
            "skills/$($skill.Name)/SKILL.md: name is not '$($skill.Name)'"
        }
        if ($front -notmatch '(?m)^description:\s*\S') {
            "skills/$($skill.Name)/SKILL.md: no description"
        }
    }
}

# README.md lists every skill, and every skill it links to exists.
function Get-ReadmeProblem([string] $Root) {
    $readme = Get-Content -LiteralPath (Join-Path $Root 'README.md') -Raw
    foreach ($skill in Get-SkillFolder $Root) {
        if (-not $readme.Contains("(skills/$($skill.Name)/SKILL.md)")) {
            "README.md: no link to skills/$($skill.Name)/SKILL.md"
        }
    }
    foreach ($m in [regex]::Matches($readme, '\((skills/[^)\s]+)\)')) {
        if (-not (Test-Path -LiteralPath (Join-Path $Root $m.Groups[1].Value))) {
            "README.md: link to $($m.Groups[1].Value), which does not exist"
        }
    }
}

# README.md's diagram has a box for every skill, and no box for a skill that is gone. A
# skill's box is written ["name"] or ["name<br>note"]; a step that is no skill is written
# ("...") and a group's title has capitals or spaces, so neither counts as a box.
function Get-ReadmeDiagramProblem([string] $Root) {
    $readme = Get-Content -LiteralPath (Join-Path $Root 'README.md') -Raw
    if ($readme -notmatch '(?s)```mermaid\r?\n(.*?)\r?\n```') {
        'README.md: no mermaid diagram'
        return
    }
    $boxes = @([regex]::Matches($Matches[1], '\["([a-z0-9-]+)(?:<br>[^"]*)?"\]') | ForEach-Object { $_.Groups[1].Value })
    $skills = @(Get-SkillFolder $Root | ForEach-Object Name)
    foreach ($name in $skills) {
        if ($name -notin $boxes) { "README.md: the diagram has no box for $name" }
    }
    foreach ($name in $boxes) {
        if ($name -notin $skills) { "README.md: the diagram has a box for $name, which is not a skill" }
    }
}

# Every skill has a guide, docs/<name>.md, with the three headings every guide has, and
# README.md links to it. Every guide is named after a skill, and its links to other files
# resolve.
function Get-GuideProblem([string] $Root) {
    $docs = Join-Path $Root 'docs'
    $readme = Get-Content -LiteralPath (Join-Path $Root 'README.md') -Raw
    $skills = @(Get-SkillFolder $Root | ForEach-Object Name)
    foreach ($name in $skills) {
        $path = Join-Path $docs "$name.md"
        if (-not (Test-Path -LiteralPath $path)) {
            "docs/$name.md: missing"
            continue
        }
        if (-not $readme.Contains("(docs/$name.md)")) { "README.md: no link to docs/$name.md" }
        $text = Get-Content -LiteralPath $path -Raw
        foreach ($heading in 'What it solves', 'How it works', 'How it connects') {
            if ($text -notmatch "(?m)^## $heading\s*$") { "docs/$name.md: no heading '## $heading'" }
        }
    }
    if (-not (Test-Path -LiteralPath $docs)) { return }
    foreach ($file in Get-ChildItem -LiteralPath $docs -File -Filter '*.md') {
        if ($file.BaseName -notin $skills) { "docs/$($file.Name): no skill is named $($file.BaseName)" }
        $text = Get-Content -LiteralPath $file.FullName -Raw
        foreach ($m in [regex]::Matches($text, '\]\(([^)\s#]+)(?:#[^)\s]*)?\)')) {
            $target = $m.Groups[1].Value
            if ($target -match '^[a-z][a-z0-9+.-]*:') { continue }
            if (-not (Test-Path -LiteralPath (Join-Path $docs $target))) {
                "docs/$($file.Name): link to $target, which does not exist"
            }
        }
    }
}

# A path in backticks that starts with ../, references/ or scripts/ and names a .md, .json,
# .ps1 or .sh file exists, relative to the file that names it or to that file's skill.
function Get-PathReferenceProblem([string] $Root) {
    foreach ($file in Get-SkillMarkdown $Root) {
        $seen = @{}
        foreach ($m in [regex]::Matches($file.Text, '`((?:\.\./|references/|scripts/)[^`\s<>*{}]+\.(?:md|json|ps1|sh))`')) {
            $ref = $m.Groups[1].Value
            if ($seen[$ref]) { continue }
            $seen[$ref] = $true
            $found = $false
            foreach ($base in $file.Dir, $file.Skill, $Root) {
                if (Test-Path -LiteralPath (Join-Path $base $ref)) { $found = $true; break }
            }
            if (-not $found) { "$($file.Label): ``$ref`` does not exist" }
        }
    }
}

# The files a token names: a path to a .md file (a <placeholder> in it stands for any
# name, and every match counts), a bare file name that is unique among the skills, or a
# skill's name, which means its SKILL.md. IsReference is false for any other token.
function Resolve-SkillReference([string] $Root, $File, [string] $Token, [switch] $PathOnly) {
    $paths = @()
    if ($Token -match '\.md$') {
        $pattern = $Token -replace '<[^>]+>', '*'
        foreach ($base in $File.Dir, $File.Skill, (Join-Path $File.Skill 'references')) {
            $paths = @(Get-Item -Path (Join-Path ([WildcardPattern]::Escape($base)) $pattern) -ErrorAction SilentlyContinue |
                    ForEach-Object FullName)
            if ($paths.Count) { break }
        }
        if (-not $paths.Count -and $Token -notmatch '[\\/<]') {
            $hits = @(Get-ChildItem -LiteralPath (Join-Path $Root 'skills') -Recurse -File -Filter $Token)
            if ($hits.Count -eq 1) { $paths = @($hits[0].FullName) }
        }
        return @{ IsReference = $true; Paths = $paths }
    }
    if (-not $PathOnly -and $Token -match '^[a-z0-9-]+$') {
        $p = Join-Path $Root "skills/$Token/SKILL.md"
        if (Test-Path -LiteralPath $p) { return @{ IsReference = $true; Paths = @($p) } }
    }
    @{ IsReference = $false; Paths = $paths }
}

# A reference to a section, written as `file or skill`, "words" or as "words" in `file.md`,
# names words that stand in a heading or a bold lead-in of that file.
function Get-SectionReferenceProblem([string] $Root) {
    foreach ($file in Get-SkillMarkdown $Root) {
        $flat = $file.Text -replace '\s*\r?\n\s*', ' '
        $refs = @()
        foreach ($m in [regex]::Matches($flat, '`([^`]{1,80})`, "([^"]{2,80})"')) {
            $refs += , @($m.Groups[1].Value, $m.Groups[2].Value, $false)
        }
        foreach ($m in [regex]::Matches($flat, '"([^"]{2,80})" in `([^`]{1,80}\.md)`')) {
            $refs += , @($m.Groups[2].Value, $m.Groups[1].Value, $true)
        }
        foreach ($ref in $refs) {
            $token, $words, $pathOnly = $ref
            $target = Resolve-SkillReference $Root $file $token -PathOnly:$pathOnly
            if (-not $target.IsReference) { continue }
            if (-not $target.Paths.Count) {
                "$($file.Label): ``$token``, `"$words`": cannot find the file"
                continue
            }
            foreach ($path in $target.Paths) {
                $text = Get-Content -LiteralPath $path -Raw
                $places = @([regex]::Matches($text, '(?m)^#{1,6}\s+(.+?)\s*$') | ForEach-Object { $_.Groups[1].Value })
                $places += @([regex]::Matches($text, '(?s)\*\*(.+?)\*\*') | ForEach-Object { $_.Groups[1].Value -replace '\s+', ' ' })
                if (-not ($places | Where-Object { $_.IndexOf($words, [StringComparison]::OrdinalIgnoreCase) -ge 0 })) {
                    $name = [IO.Path]::GetRelativePath($Root, $path).Replace('\', '/')
                    "$($file.Label): ``$token``, `"$words`": no heading or bold lead-in with these words in $name"
                }
            }
        }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $rootPath = (Resolve-Path -LiteralPath $Root).Path
    $problems = @(
        Get-SkillFrontMatterProblem $rootPath
        Get-ReadmeProblem $rootPath
        Get-ReadmeDiagramProblem $rootPath
        Get-GuideProblem $rootPath
        Get-PathReferenceProblem $rootPath
        Get-SectionReferenceProblem $rootPath
    )
    $problems | ForEach-Object { $_ }
    if ($problems.Count) { exit 1 }
    'skill texts: no problems'
}
