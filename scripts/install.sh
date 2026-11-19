#!/bin/sh
# Link every skill in this repository into the folders the harnesses read (Linux, macOS).
#
#   sh <repository>/scripts/install.sh [target folder ...]
#
# Links each folder under skills/ that has a SKILL.md into every target folder with a
# symbolic link. With no target, the targets are ~/.claude/skills (Claude Code; Cursor
# reads it too) and ~/.agents/skills (Codex, Cursor). Every skill is linked, so a sibling
# reference such as ../babysit-pr/SKILL.md resolves next to the link. install.ps1 does the
# same on Windows.
#
# - A missing link is created. A link that already points into this repository is left
#   as it is, so running the script twice changes nothing.
# - A real directory or file with a skill's name is never replaced: it is reported and
#   skipped. Neither is a link that points somewhere else, including one whose target is
#   gone. Retire those yourself, then run this again.
# - Everything else in the target folders is left alone.
#
# Exit code: 0 when every skill is linked in every target, 1 when any was skipped.

set -u
here=$(cd "$(dirname "$0")" && pwd -P)
skills_dir=$(cd "$here/../skills" && pwd -P)
if [ "$#" -eq 0 ]; then set -- "$HOME/.claude/skills" "$HOME/.agents/skills"; fi

count=0
for d in "$skills_dir"/*/; do [ -f "${d}SKILL.md" ] && count=$((count + 1)); done

skipped=0
for target in "$@"; do
    mkdir -p "$target" || exit 1
    echo "== $target"
    for d in "$skills_dir"/*/; do
        [ -f "${d}SKILL.md" ] || continue
        skill=$(basename "$d")
        source="$skills_dir/$skill"
        link="$target/$skill"
        if [ -L "$link" ]; then
            points=$(cd "$link" 2>/dev/null && pwd -P) || points=$(readlink "$link")
            if [ "$points" = "$source" ]; then
                echo "already linked: $skill"
            else
                echo "skipped: $skill at $link points to $points, not $source; left alone."
                skipped=$((skipped + 1))
            fi
        elif [ -e "$link" ]; then
            echo "skipped: $skill is a real directory or file at $link; not replaced. Retire it yourself, then run this again."
            skipped=$((skipped + 1))
        else
            ln -s "$source" "$link" || exit 1
            echo "linked: $skill -> $source"
        fi
    done
done

if [ "$skipped" -gt 0 ]; then
    echo "$skipped skipped; see above."
    exit 1
fi
echo "all $count skills link to $skills_dir in $# folder(s)"
exit 0
