#Requires -Version 7.2
# Pester 5 tests for the skill texts: front matter, the README's list, and the paths and
# sections one skill file names in another. No script is under test, so TEST_SCRIPT_KINDS
# does not apply and these run on every system. The checks are in skill-text.ps1.

BeforeAll {
    . (Join-Path $PSScriptRoot 'skill-text.ps1')
    $script:RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
}

Describe 'skill texts' {
    It 'finds the skills' {
        @(Get-SkillFolder $RepoRoot).Count | Should -BeGreaterThan 0
    }

    It 'gives every skill front matter with its folder name and a description' {
        @(Get-SkillFrontMatterProblem $RepoRoot) -join "`n" | Should -BeNullOrEmpty
    }

    It 'lists every skill in README.md, and links only to skills that exist' {
        @(Get-ReadmeProblem $RepoRoot) -join "`n" | Should -BeNullOrEmpty
    }

    It 'gives every skill a box in the README.md diagram, and no box to a skill that is gone' {
        @(Get-ReadmeDiagramProblem $RepoRoot) -join "`n" | Should -BeNullOrEmpty
    }

    It 'gives every skill a guide in docs/ that README.md links to, with links that work' {
        @(Get-GuideProblem $RepoRoot) -join "`n" | Should -BeNullOrEmpty
    }

    It 'names only files that exist' {
        @(Get-PathReferenceProblem $RepoRoot) -join "`n" | Should -BeNullOrEmpty
    }

    It 'names only sections that exist' {
        @(Get-SectionReferenceProblem $RepoRoot) -join "`n" | Should -BeNullOrEmpty
    }
}

Describe 'the checks themselves' {
    BeforeAll {
        $script:Fake = Join-Path ([IO.Path]::GetTempPath()) "skill text tests $([guid]::NewGuid().ToString('N').Substring(0, 8))"
        New-Item -ItemType Directory -Force (Join-Path $Fake 'skills/one/references'), (Join-Path $Fake 'skills/two') | Out-Null
        Set-Content -LiteralPath (Join-Path $Fake 'README.md') -Value @'
[one](skills/one/SKILL.md) [gone](skills/gone/SKILL.md)

```mermaid
flowchart TB
    subgraph group["A group"]
        one["one<br>the first"]
        step("two<br>a step, not a box")
        gone["gone"]
    end
```
'@
        Set-Content -LiteralPath (Join-Path $Fake 'skills/one/SKILL.md') -Value @'
---
name: one
description: The first.
---
See `references/notes.md` and `references/missing.md`.
Good: (`two`, "Real heading") and (`notes.md`, "Lead-in").
Bad: (`two`, "No such heading") and "Nowhere" in `references/notes.md`.
'@
        Set-Content -LiteralPath (Join-Path $Fake 'skills/one/references/notes.md') -Value "# Notes`n`n**Lead-in.** Text."
        New-Item -ItemType Directory -Force (Join-Path $Fake 'docs') | Out-Null
        Set-Content -LiteralPath (Join-Path $Fake 'docs/one.md') -Value @'
# one
## What it solves
## How it works
See [the skill](../skills/one/SKILL.md), [a site](https://example.com) and [nothing](missing.md).
'@
        Set-Content -LiteralPath (Join-Path $Fake 'docs/stray.md') -Value '# stray'
        Set-Content -LiteralPath (Join-Path $Fake 'skills/two/SKILL.md') -Value "---`nname: other`n---`n## A real heading here`n"
    }
    AfterAll {
        Remove-Item -LiteralPath $Fake -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'reports a name that is not the folder name, and a missing description' {
        $problems = @(Get-SkillFrontMatterProblem $Fake)
        $problems | Should -HaveCount 2
        $problems -join "`n" | Should -Match "skills/two/SKILL.md: name is not 'two'"
        $problems -join "`n" | Should -Match 'skills/two/SKILL.md: no description'
    }

    It 'reports a skill the README leaves out, and a link to a skill that is gone' {
        $problems = @(Get-ReadmeProblem $Fake)
        $problems | Should -HaveCount 2
        $problems -join "`n" | Should -Match 'no link to skills/two/SKILL.md'
        $problems -join "`n" | Should -Match 'skills/gone/SKILL.md, which does not exist'
    }

    It 'reports a skill the diagram leaves out, and a box for a skill that is gone' {
        $problems = @(Get-ReadmeDiagramProblem $Fake)
        $problems | Should -HaveCount 2
        $problems -join "`n" | Should -Match 'no box for two'
        $problems -join "`n" | Should -Match 'a box for gone, which is not a skill'
    }

    It 'reports a README.md with no diagram' {
        $bare = Join-Path $Fake 'bare'
        New-Item -ItemType Directory -Force (Join-Path $bare 'skills') | Out-Null
        Set-Content -LiteralPath (Join-Path $bare 'README.md') -Value 'No diagram here.'
        @(Get-ReadmeDiagramProblem $bare) | Should -Be 'README.md: no mermaid diagram'
    }

    It 'reports a missing guide, an unlinked one, a missing heading, a dead link and a stray file' {
        $problems = @(Get-GuideProblem $Fake)
        $problems | Should -HaveCount 5
        $problems -join "`n" | Should -Match 'docs/two.md: missing'
        $problems -join "`n" | Should -Match 'README.md: no link to docs/one.md'
        $problems -join "`n" | Should -Match "docs/one.md: no heading '## How it connects'"
        $problems -join "`n" | Should -Match 'docs/one.md: link to missing.md, which does not exist'
        $problems -join "`n" | Should -Match 'docs/stray.md: no skill is named stray'
    }

    It 'reports only the path that does not exist' {
        $problems = @(Get-PathReferenceProblem $Fake)
        $problems | Should -HaveCount 1
        $problems[0] | Should -Match 'references/missing.md'
    }

    It 'reports only the sections that do not exist' {
        $problems = @(Get-SectionReferenceProblem $Fake)
        $problems | Should -HaveCount 2
        $problems -join "`n" | Should -Match 'No such heading'
        $problems -join "`n" | Should -Match 'Nowhere'
    }
}
