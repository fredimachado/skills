#!/bin/sh
# Link every skill in this repository into the folders the harnesses read, and set up the
# role file (Linux, macOS).
#
#   sh <repository>/scripts/install.sh [target folder ...]
#   sh <repository>/scripts/install.sh --roles
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
# Then the role file, ~/.agents/roles.json, which tells the delegate skill which harness,
# model and effort runs each role (needs jq). When it is missing and this runs in a
# terminal, it offers to ask for each role and write the file. --roles asks again, with
# the current values as defaults, and does nothing else: use it to change models later.
# The file is written only after you confirm it, and the previous version is kept as
# roles.json.bak. Keys the questions do not cover (such as $comment) are kept.
#
# Exit code: 0 when every skill is linked in every target, 1 when any was skipped or the
# role file is not valid JSON, 2 when the questions could not be asked or answered.

set -u
here=$(cd "$(dirname "$0")" && pwd -P)
skills_dir=$(cd "$here/../skills" && pwd -P)
role_file="$HOME/.agents/roles.json"
roles='planner coder-simple coder-complex reviewer council-a council-b'
new_comment='Role file for the delegate skill. install.ps1 -Roles (Windows) or install.sh --roles (Linux, macOS) asks again to change it; the shape is in skills/delegate/roles.example.json.'

roles_only=false
n=$#
while [ "$n" -gt 0 ]; do
    a=$1; shift; n=$((n - 1))
    case $a in
        --roles | -roles | -Roles) roles_only=true ;;
        *) set -- "$@" "$a" ;;
    esac
done

say() { printf '%s\n' "$*"; }
describe() {
    case $1 in
        planner) echo 'writes the plan; read-only' ;;
        coder-simple) echo 'codes tasks the plan pins down: few files, an existing pattern' ;;
        coder-complex) echo 'codes the hard tasks: concurrency, invariants, migrations, security' ;;
        reviewer) echo 'reviews diffs; read-only' ;;
        council-a) echo 'first of two independent reviewers' ;;
        council-b) echo 'second reviewer; a model from a different provider than council-a' ;;
    esac
}
model_hint() {
    # shellcheck disable=SC2016 # the backquotes are shown, not run
    case $1 in
        claude) echo 'an id or alias Claude Code accepts, as /model shows them; it has no list command' ;;
        codex) echo 'a slug from `codex debug models`' ;;
        cursor) echo 'a name from `cursor-agent --list-models` (first column); effort goes in its own question' ;;
    esac
}
# Questions are asked only of someone at a terminal (INSTALL_ROLES_PROMPT=1 forces them, for the tests).
can_ask() { [ "${INSTALL_ROLES_PROMPT:-}" = 1 ] || [ -t 0 ]; }
ask_line() {   # prints $1, reads a line into $answer; at the end of input, stops the script
    printf '%s' "$1"
    answer=
    if ! IFS= read -r answer && [ -z "$answer" ]; then
        echo
        say "Input ended; $role_file left as it was."
        exit 2
    fi
    answer=$(printf '%s' "$answer" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
}
read_value() {   # label, current -> $value. Enter keeps the current value; - clears it.
    if [ -n "$2" ]; then ask_line "  $1 [$2]: "; else ask_line "  $1: "; fi
    case $answer in
        '') value=$2 ;;
        -) value= ;;
        *) value=$answer ;;
    esac
}
yes_no() {   # question, default (y or n); returns 0 for yes
    if [ "$2" = y ]; then ask_line "$1 [Y/n] "; else ask_line "$1 [y/N] "; fi
    case $(printf '%s' "$answer" | tr '[:upper:]' '[:lower:]') in
        '') [ "$2" = y ] ;;
        y | yes) return 0 ;;
        *) return 1 ;;
    esac
}
hinted=' '
read_entry() {   # current entry as JSON (null for none), what no harness means -> $entry ('' for none)
    cur_h=$(printf '%s' "$1" | jq -r '.harness? // empty')
    while :; do
        read_value harness "$cur_h"
        h=$value
        case $h in '' | claude | codex | cursor) break ;; esac
        say "  harness is claude, codex or cursor; - leaves the role $2."
    done
    entry=
    [ -n "$h" ] || return 0
    # The model goes to the harness exactly as typed; say once where each one lists its ids.
    case $hinted in *" $h "*) ;; *) hinted="$hinted$h "; say "  ($h model: $(model_hint "$h"))" ;; esac
    # A model and an effort belong to one harness: offer them only when it is unchanged.
    cur_m= cur_e=
    if [ "$h" = "$cur_h" ]; then
        cur_m=$(printf '%s' "$1" | jq -r '.model? // empty')
        cur_e=$(printf '%s' "$1" | jq -r '.effort? // empty')
    fi
    while :; do
        read_value model "$cur_m"
        m=$value
        [ -n "$m" ] && break
        say '  a model is needed: the id or alias that harness accepts.'
    done
    read_value 'effort (optional)' "$cur_e"
    entry=$(jq -nc --arg h "$h" --arg m "$m" --arg e "$value" \
        '{harness: $h, model: $m} + (if $e == "" then {} else {effort: $e} end)')
}

# Asks for every role, shows the result and writes it on a yes. Returns the exit code.
role_setup() {
    if ! command -v jq >/dev/null 2>&1; then
        say "roles: setting up $role_file needs jq; install it, then run install.sh --roles."
        return 2
    fi
    if [ -f "$role_file" ]; then
        if ! doc=$(jq -c . "$role_file" 2>/dev/null) || [ "$(printf '%s' "$doc" | jq -r type 2>/dev/null)" != object ]; then
            say "roles: $role_file is not a JSON object; fix or move it, then run this again."
            return 1
        fi
    else
        doc=$(jq -nc --arg c "$new_comment" '{"$comment": $c}')
    fi
    say ''
    say "Roles for the delegate skill, saved in $role_file."
    say 'For each role: the harness (claude, codex or cursor), the model exactly as that harness'
    say 'takes it (an id, not a display name: nothing translates it), and an effort level if you'
    say 'want one. Enter keeps the value in [brackets]; - clears it. A role with no harness is'
    say 'unavailable: skills stop and ask instead of picking a model.'
    new_roles='{}'
    for role in $roles; do
        say ''
        say "$role: $(describe "$role")"
        read_entry "$(printf '%s' "$doc" | jq -c --arg r "$role" '.roles[$r]? // null')" unavailable
        if [ -n "$entry" ]; then
            new_roles=$(printf '%s' "$new_roles" | jq -c --arg r "$role" --argjson e "$entry" '.[$r] = $e')
        fi
    done

    say ''
    say 'A host override replaces a role when that harness runs the session, for example other'
    say 'models when Cursor is the host. Enter on an empty [] means no override for that role.'
    new_ov=$(printf '%s' "$doc" | jq -c '(.hostOverrides? // {}) | if type == "object"
        then with_entries(select(.key != "claude" and .key != "codex" and .key != "cursor")) else {} end')
    for host in claude codex cursor; do
        cur=$(printf '%s' "$doc" | jq -c --arg h "$host" '(.hostOverrides? // {})[$h]? // {} | if type == "object" then . else {} end')
        def=n
        [ "$cur" != '{}' ] && def=y
        say ''
        yes_no "Different roles when $host runs the session?" "$def" || continue
        host_roles='{}'
        for role in $roles; do
            say "  $role"
            read_entry "$(printf '%s' "$cur" | jq -c --arg r "$role" '.[$r]? // null')" 'without an override'
            if [ -n "$entry" ]; then
                host_roles=$(printf '%s' "$host_roles" | jq -c --arg r "$role" --argjson e "$entry" '.[$r] = $e')
            fi
        done
        if [ "$host_roles" != '{}' ]; then
            new_ov=$(printf '%s' "$new_ov" | jq -c --arg h "$host" --argjson o "$host_roles" '.[$h] = $o')
        fi
    done

    # Keep every other key, in place; roles and hostOverrides go where they were.
    json=$(printf '%s' "$doc" | jq --argjson r "$new_roles" --argjson o "$new_ov" \
        '.roles = $r | if $o == {} then del(.hostOverrides) else .hostOverrides = $o end')
    say ''
    say "$json"
    if ! yes_no "Write it to $role_file?" y; then
        say "Not written; $role_file left as it was."
        return 0
    fi
    mkdir -p "$(dirname "$role_file")" || return 1
    kept=
    if [ -f "$role_file" ]; then
        cp "$role_file" "$role_file.bak" || return 1
        kept="; the previous version is in $role_file.bak"
    fi
    { printf '%s\n' "$json" > "$role_file.tmp" && mv -f "$role_file.tmp" "$role_file"; } || return 1
    say "roles: wrote $role_file$kept."
    return 0
}

if [ "$roles_only" = true ]; then
    if ! can_ask; then
        say "roles: the questions need a terminal; run install.sh --roles in one."
        exit 2
    fi
    role_setup
    exit $?
fi

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

code=0
if [ "$skipped" -gt 0 ]; then
    echo "$skipped skipped; see above."
    code=1
else
    echo "all $count skills link to $skills_dir in $# folder(s)"
fi

if [ -f "$role_file" ]; then
    say "roles: $role_file is set up; install.sh --roles asks again to change it."
elif ! can_ask; then
    say "roles: no role file at $role_file, so the delegate skill has no models. Run install.sh --roles in a terminal to make one."
elif yes_no "No role file at $role_file, so the delegate skill has no models. Set it up now?" y; then
    role_setup
    r=$?
    if [ "$r" -ne 0 ] && [ "$code" -eq 0 ]; then code=$r; fi
else
    say "roles: not set up; install.sh --roles asks later."
fi
exit "$code"
