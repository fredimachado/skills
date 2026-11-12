# Agent skills

| Skill | What it does |
| --- | --- |
| [csharp-modernization](skills/csharp-modernization/SKILL.md) | Modernizes C# code using features from C# 9 through C# 15, with guidance on language versions, runtime requirements, and behavior changes. |

## Install

Run this from your project directory and choose your agent when prompted.

~~~sh
npx skills@latest add fredimachado/skills --skill csharp-modernization
~~~

Add `--global` to make the skill available across projects.

## Update

Run the same install command again to fetch the current version. Use the same project directory or the same `--global` option as before.

## Use

Ask your agent to use `csharp-modernization` on the code you want to change. For example, "Use csharp-modernization to simplify this class while keeping it compatible with C# 12."
