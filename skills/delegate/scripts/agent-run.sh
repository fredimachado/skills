#!/bin/sh
# Run one delegate on another harness's command line and report the result as one JSON object
# (Linux, macOS). agent-run.ps1 does the same on Windows; the contract is the same.
#
# Start it as: sh <absolute path>/agent-run.sh -Harness claude -Model <model> ...
# Parameters (spelled as in agent-run.ps1, case-insensitive):
#   -Role <role> -HostHarness claude|codex|cursor   resolve harness, model, effort from -RoleFile
#   -Harness claude|codex|cursor -Model <model> -Effort <level>
#   -Mode read-only|write -WorkDir <dir> -PromptFile <file> -OutFile <file>
#   -SchemaFile <file> -ResumeId <id> -ReadDir <dir:dir...> -TimeoutSec <n> (default 1800)
#   -RoleFile <file> (default ~/.agents/roles.json) -Check
# stdout carries exactly one JSON object:
#   { status: ok|failed|timeout|unavailable|invalid-output, harness, model, sessionId,
#     outFile, durationSec, exitCode, error }
# Diagnostics go to stderr. The CLI's raw output is kept next to the out file as <OutFile>.log.
# Exit code: 0 when status is ok, 2 for bad arguments, 1 otherwise.
#
# Needs: POSIX sh and utilities, git, jq (1.6 or later), pgrep. Paths must not contain newlines.
# This script never chooses or substitutes a model and never handles credentials.
# See ../SKILL.md and ../references/<harness>-cli.md.

set -u
unset CDPATH
GUARD=AGENT_SKILLS_DELEGATE
HARNESSES='claude codex cursor'
started=$(date +%s)
nl='
'

Role='' HostHarness='' Harness='' Model='' Effort='' Mode='read-only' WorkDir='' PromptFile=''
OutFile='' SchemaFile='' ResumeId='' ReadDir='' TimeoutSec=1800 RoleFile="$HOME/.agents/roles.json"
Check=0

# ---------------------------------------------------------------- result

r_status=failed r_harness='' r_model='' r_session='' r_outfile='' r_exit=0
tmp=''
cli_pid=''

json_fallback() {   # a JSON string without jq: drop control characters, escape \ and "
    printf '"%s"' "$(printf '%s' "$1" | tr -d '\000-\037' | sed 's/\\/\\\\/g; s/"/\\"/g')"
}

finish() {   # status [error] [exit code]
    r_status=$1
    err=${2-}
    code=${3-}
    duration=$(( $(date +%s) - started ))
    if command -v jq >/dev/null 2>&1; then
        jq -nc --arg status "$r_status" --arg harness "$r_harness" --arg model "$r_model" \
            --arg sessionId "$r_session" --arg outFile "$r_outfile" --argjson durationSec "$duration" \
            --argjson exitCode "$r_exit" --arg error "$err" \
            '{status: $status, harness: $harness, model: $model, sessionId: $sessionId,
              outFile: $outFile, durationSec: $durationSec, exitCode: $exitCode, error: $error}'
    else
        printf '{"status":%s,"harness":%s,"model":%s,"sessionId":%s,"outFile":%s,"durationSec":%s,"exitCode":%s,"error":%s}\n' \
            "$(json_fallback "$r_status")" "$(json_fallback "$r_harness")" "$(json_fallback "$r_model")" \
            "$(json_fallback "$r_session")" "$(json_fallback "$r_outfile")" "$duration" "$r_exit" \
            "$(json_fallback "$err")"
    fi
    if [ -z "$code" ]; then
        if [ "$r_status" = ok ]; then code=0; else code=1; fi
    fi
    exit "$code"
}

fail_arguments() { finish failed "$1" 2; }

# ---------------------------------------------------------------- arguments

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

while [ "$#" -gt 0 ]; do
    name=$(lower "$1")
    case $name in
        -check) Check=1; shift; continue ;;
        -role|-hostharness|-harness|-model|-effort|-mode|-workdir|-promptfile|-outfile|-schemafile|-resumeid|-readdir|-timeoutsec|-rolefile) ;;
        *) fail_arguments "A parameter cannot be found that matches parameter name '$1'." ;;
    esac
    [ "$#" -ge 2 ] || fail_arguments "Missing an argument for parameter '$1'."
    value=$2
    shift 2
    case $name in
        -role) Role=$value ;;
        -hostharness) HostHarness=$value ;;
        -harness) Harness=$value ;;
        -model) Model=$value ;;
        -effort) Effort=$value ;;
        -mode) Mode=$value ;;
        -workdir) WorkDir=$value ;;
        -promptfile) PromptFile=$value ;;
        -outfile) OutFile=$value ;;
        -schemafile) SchemaFile=$value ;;
        -resumeid) ResumeId=$value ;;
        -readdir) ReadDir=$value ;;
        -timeoutsec)
            case $value in ''|*[!0-9]*) fail_arguments "-TimeoutSec must be a whole number of seconds, not '$value'." ;; esac
            TimeoutSec=$value ;;
        -rolefile) RoleFile=$value ;;
    esac
done
r_harness=$Harness r_model=$Model r_outfile=$OutFile

command -v jq >/dev/null 2>&1 || finish failed "jq is required on Linux and macOS and was not found on PATH."

# ---------------------------------------------------------------- processes

cleanup() {
    [ -n "$cli_pid" ] && kill_tree "$cli_pid"
    [ -n "$tmp" ] && rm -rf "$tmp"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
tmp=$(mktemp -d "${TMPDIR:-/tmp}/agent-run.XXXXXX") || finish failed "Could not create a temporary directory."

tree_pids=''
collect_tree() {   # stop a process so it cannot fork, then do the same for its children
    kill -STOP "$1" 2>/dev/null || return 0
    tree_pids="$tree_pids $1"
    for child in $(pgrep -P "$1" 2>/dev/null); do collect_tree "$child"; done
}

kill_tree() {   # kill a process and every descendant
    tree_pids=''
    collect_tree "$1"
    # shellcheck disable=SC2086
    [ -n "$tree_pids" ] && kill -KILL $tree_pids 2>/dev/null
    return 0
}

resolve_launcher() {   # print the path of an executable on PATH
    p=$(command -v "$1" 2>/dev/null) || return 1
    case $p in /*) [ -f "$p" ] && [ -x "$p" ] && printf '%s\n' "$p" && return 0 ;; esac
    return 1
}

# run_cli <cwd> <stdin file> <seconds> <command> [args...]
# Sets run_code (-1 on timeout) and run_timed_out; output lands in $tmp/stdout and $tmp/stderr.
run_cli() {
    _cwd=$1 _in=$2 _secs=$3
    shift 3
    rm -f "$tmp/code"
    (
        cd -- "$_cwd" || exit 127
        AGENT_SKILLS_DELEGATE=1
        export AGENT_SKILLS_DELEGATE
        "$@"
        echo "$?" >"$tmp/code"
    ) <"$_in" >"$tmp/stdout" 2>"$tmp/stderr" &
    cli_pid=$!
    run_timed_out=0
    _waited=0
    while [ ! -f "$tmp/code" ] && kill -0 "$cli_pid" 2>/dev/null; do
        if [ "$_waited" -ge "$_secs" ]; then
            run_timed_out=1
            kill_tree "$cli_pid"
            break
        fi
        sleep 1
        _waited=$((_waited + 1))
    done
    wait "$cli_pid" 2>/dev/null
    _status=$?
    cli_pid=''
    if [ "$run_timed_out" = 1 ]; then
        run_code=-1
    elif [ -s "$tmp/code" ]; then
        run_code=$(cat "$tmp/code")
    else
        run_code=$_status
    fi
}

: >"$tmp/empty"
run_quick() { run_cli "$PWD" "$tmp/empty" 60 "$@"; }   # a status, version or help call

# ---------------------------------------------------------------- adapters
# One adapter per CLI: the command, the flags it uses (checked by -Check), how to tell it is
# signed in, which models it offers, how to build a run, and how to read the result.

CLAUDE_READ_ONLY_TOOLS='Read,Grep,Glob,Bash'

adapter_command() {
    case $1 in claude) echo claude ;; codex) echo codex ;; cursor) echo cursor-agent ;; esac
}

# Help probes: lines of "<help arguments>|<flags>", split on spaces.
adapter_help() {
    case $1 in
        claude) echo '--help|-p --model --effort --permission-mode --tools --allowedTools --output-format --json-schema --resume --add-dir' ;;
        codex)
            echo 'exec --help|-m -s -C --json -o --output-schema -c resume'
            echo 'exec resume --help|-m --json -o --output-schema -c' ;;
        cursor) echo '--help|-p --model --mode -f --trust --workspace --output-format --resume --list-models --add-dir' ;;
    esac
}

signed_in() {   # harness launcher
    case $1 in
        claude)
            run_quick "$2" auth status
            [ "$run_code" = 0 ] && jq -e '.loggedIn == true' "$tmp/stdout" >/dev/null 2>&1 ;;
        codex)
            run_quick "$2" login status
            [ "$run_code" = 0 ] && ! cat "$tmp/stdout" "$tmp/stderr" | grep -qi 'not logged in' ;;
        cursor)
            run_quick "$2" status
            [ "$run_code" = 0 ] && ! cat "$tmp/stdout" "$tmp/stderr" | grep -qiE 'not (logged|signed) in|unauthenticated' ;;
    esac
}

# Prints the models the CLI offers, one per line, and returns 0; returns 1 when it has no list
# (claude: an unknown model fails the run instead).
offered_models() {   # harness launcher
    case $1 in
        claude) return 1 ;;
        codex)
            run_quick "$2" debug models
            jq -e . "$tmp/stdout" >/dev/null 2>&1 || return 1
            jq -r '(if type == "object" and .models then .models else . end)
                   | (if type == "array" then .[] else . end)
                   | objects | .slug // empty | tostring' "$tmp/stdout" 2>/dev/null ;;
        cursor)
            run_quick "$2" --list-models
            [ "$run_code" = 0 ] || return 1
            tr -d '\r' <"$tmp/stdout" |
                sed -n 's/^[[:space:]]*\([^[:space:]]\{1,\}\)[[:space:]]\{1,\}-[[:space:]].*/\1/p' ;;
    esac
}

# Writes the CLI arguments to $tmp/args, one per line, and sets run_stdin to the brief to pipe in.
build_args() {
    case $Harness in
        claude)
            set -- -p --output-format json --model "$Model"
            [ -n "$Effort" ] && set -- "$@" --effort "$Effort"
            [ -n "$ResumeId" ] && set -- "$@" --resume "$ResumeId"
            [ -n "$schema" ] && set -- "$@" --json-schema "$schema"
            # Claude reads only inside its working directories: add the ones the brief points to.
            set -- "$@" --add-dir
            set -f; IFS=$nl
            for d in $read_dirs; do set -- "$@" "$d"; done
            unset IFS; set +f
            if [ "$Mode" = write ]; then
                set -- "$@" --permission-mode auto
            else
                set -- "$@" --permission-mode dontAsk --tools "$CLAUDE_READ_ONLY_TOOLS" --allowedTools \
                    'Bash(git diff:*)' 'Bash(git log:*)' 'Bash(git show:*)' 'Bash(git status:*)' 'Bash(git rev-parse:*)'
            fi
            run_stdin=$PromptFile ;;
        codex)
            if [ "$Mode" = write ]; then sandbox=workspace-write; else sandbox=read-only; fi
            last_message="$tmp/last-message.txt"
            set -- --json -o "$last_message" -m "$Model"
            [ -n "$Effort" ] && set -- "$@" -c "model_reasoning_effort=$Effort"
            [ -n "$schema_file" ] && set -- "$@" --output-schema "$schema_file"
            if [ -n "$ResumeId" ]; then
                # exec resume has no -s or -C: set the sandbox by config and run in the work directory.
                set -- exec resume "$@" -c "sandbox_mode=$sandbox" "$ResumeId" -
            else
                set -- exec "$@" -s "$sandbox" -C "$WorkDir" -
            fi
            run_stdin=$PromptFile ;;
        cursor)
            cursor_model=$Model
            [ -n "$Effort" ] && cursor_model="${Model}[effort=${Effort}]"
            set -- -p --output-format json --trust --model "$cursor_model" --workspace "$WorkDir"
            [ -n "$ResumeId" ] && set -- "$@" --resume "$ResumeId"
            set -f; IFS=$nl
            for d in $read_dirs; do set -- "$@" --add-dir "$d"; done
            unset IFS; set +f
            if [ "$Mode" = write ]; then set -- "$@" -f; else set -- "$@" --mode plan; fi
            run_stdin=$PromptFile
            if [ -n "$schema" ]; then
                # Cursor has no schema flag: ask for the shape in the brief and validate afterwards.
                run_stdin="$tmp/brief.md"
                {
                    cat "$PromptFile"
                    printf '\n\nReply with only one JSON object, no other text, that validates against this JSON Schema:\n%s\n' "$schema"
                } >"$run_stdin"
            fi ;;
    esac
    # Hand the arguments back one per line (none contains a newline: the schema is compact JSON).
    : >"$tmp/args"
    for a in "$@"; do printf '%s\n' "$a" >>"$tmp/args"; done
}

# The last stdout line that is a JSON object with type "result", or nothing.
result_object() {
    jq -cR 'fromjson? | select(type == "object" and .type == "result")' "$tmp/stdout" 2>/dev/null | tail -n 1
}

# Sets p_invalid, p_error, p_session, p_model and p_has_text; writes the text to $tmp/text.
parse_run() {
    p_invalid='' p_error='' p_session='' p_model='' p_has_text=0
    as_text='def as_text: if . == null then "" elif type == "string" then . else tojson end; '
    case $Harness in
        claude)
            result_object >"$tmp/result.json"
            if [ ! -s "$tmp/result.json" ]; then p_invalid='no JSON result on stdout'; return; fi
            # The model that wrote the most output tokens is the one that ran.
            p_model=$(jq -r '(.modelUsage // {}) | if type == "object" then to_entries
                | sort_by(-((.value.outputTokens? // 0) | (tonumber? // 0))) | (first | .key) // "" else "" end' \
                "$tmp/result.json")
            if [ -n "$schema" ]; then
                jq -j '.structured_output | if . == null then "" elif type == "string" then tojson else . end' \
                    "$tmp/result.json" >"$tmp/text"
            else
                jq -j "$as_text"'.result | as_text' "$tmp/result.json" >"$tmp/text"
            fi
            p_has_text=1
            p_session=$(jq -r "$as_text"'.session_id | as_text' "$tmp/result.json")
            if [ "$(jq -r '.is_error == true' "$tmp/result.json")" = true ]; then
                p_error="claude reported an error: $(cat "$tmp/text")"
            fi ;;
        codex)
            thread=$(jq -rR 'fromjson? | objects | select(.type == "thread.started") | .thread_id // "" | tostring' \
                "$tmp/stdout" 2>/dev/null | tail -n 1)
            failure=$(jq -rR 'fromjson? | objects
                | if .type == "turn.failed" then tojson elif .type == "error" then (.message // "" | tostring) else empty end' \
                "$tmp/stdout" 2>/dev/null | tail -n 1)
            # An empty final message counts as none.
            has_message=0
            [ -s "$last_message" ] && has_message=1
            if [ -z "$thread" ] && [ "$has_message" = 0 ]; then p_invalid='no session events and no final message'; return; fi
            if [ "$has_message" = 0 ] && [ -z "$failure" ]; then p_invalid='no final message'; return; fi
            if [ "$has_message" = 1 ]; then cp "$last_message" "$tmp/text"; else : >"$tmp/text"; fi
            p_has_text=1
            p_session=${thread:-$ResumeId}
            [ -n "$failure" ] && p_error="codex reported a failure: $failure" ;;
        cursor)
            result_object >"$tmp/result.json"
            if [ ! -s "$tmp/result.json" ]; then p_invalid='no JSON result on stdout'; return; fi
            # With a schema, keep the text from the first { to the last }.
            jq -j --arg schema "$schema" "$as_text"'.result | as_text
                | if $schema != "" then
                    explode as $c | ($c | indices(123)) as $open | ($c | indices(125)) as $close
                    | if ($open | length) > 0 and ($close | length) > 0 and $close[-1] > $open[0]
                      then $c[$open[0]:$close[-1] + 1] | implode else . end
                  else . end' "$tmp/result.json" >"$tmp/text"
            p_has_text=1
            p_session=$(jq -r "$as_text"'.session_id | as_text' "$tmp/result.json")
            if [ "$(jq -r '.is_error == true' "$tmp/result.json")" = true ]; then
                p_error="cursor reported an error: $(cat "$tmp/text")"
            fi ;;
    esac
}

# The subset of JSON Schema that result schemas use: type, enum, const, required, properties,
# additionalProperties (false or a schema), items. Other keywords are not checked.
SCHEMA_JQ='
def has_type($t):
  if $t == "integer" then type == "number" and . == floor
  else type == $t end;
def valid($s):
  . as $x
  | if ($s | type) == "boolean" then $s
    elif ($s | type) != "object" then true
    else
      ( if $s.type == null then true
        elif ($s.type | type) == "array" then any($s.type[]; . as $t | $x | has_type($t))
        else $x | has_type($s.type) end )
      and ( if $s.enum == null then true else any($s.enum[]; . == $x) end )
      and ( if ($s | has("const")) then $s.const == $x else true end )
      and ( if ($x | type) != "object" then true
            else
              all(($s.required // [])[]; . as $k | $x | has($k))
              and all(($s.properties // {}) | to_entries[];
                      .key as $k | .value as $p | if ($x | has($k)) then ($x[$k] | valid($p)) else true end)
              and ( (if ($s | has("additionalProperties")) then $s.additionalProperties else true end) as $ap
                    | if $ap == true then true
                      else all($x | to_entries[];
                               .key as $k | .value as $v
                               | if (($s.properties // {}) | has($k)) then true else ($v | valid($ap)) end)
                      end )
            end )
      and ( if ($x | type) != "array" or $s.items == null then true
            elif ($s.items | type) == "array" then true
            else all($x[]; valid($s.items)) end )
    end;
length == 1 and (.[0] | valid($schema[0]))
'

# ---------------------------------------------------------------- -Check

help_has_flag() {   # help text file, flag (letters and dashes only)
    grep -qE "(^|[[:space:],[])$2(\$|[[:space:],=<[])" "$1"
}

if [ "$Check" = 1 ]; then
    : >"$tmp/clis"
    bad=0
    for h in $HARNESSES; do
        cmd=$(adapter_command "$h")
        if ! launcher=$(resolve_launcher "$cmd"); then
            jq -nc --arg h "$h" --arg c "$cmd" \
                '{harness: $h, command: $c, installed: false, version: "", missingFlags: []}' >>"$tmp/clis"
            continue
        fi
        run_quick "$launcher" --version
        version=$(tr -d '\r' <"$tmp/stdout" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | grep -v '^$')
        : >"$tmp/missing"
        adapter_help "$h" >"$tmp/probes"
        while IFS='|' read -r probe_args flags; do
            # shellcheck disable=SC2086
            run_quick "$launcher" $probe_args
            { cat "$tmp/stdout"; echo; cat "$tmp/stderr"; } | tr -d '\r' >"$tmp/help"
            for flag in $flags; do
                help_has_flag "$tmp/help" "$flag" || {
                    grep -qxF -- "$flag" "$tmp/missing" || printf '%s\n' "$flag" >>"$tmp/missing"
                }
            done
        done <"$tmp/probes"
        [ -s "$tmp/missing" ] && bad=1
        jq -nc --arg h "$h" --arg c "$cmd" --arg v "$version" --rawfile m "$tmp/missing" \
            '{harness: $h, command: $c, installed: true, version: $v,
              missingFlags: ($m | split("\n") | map(select(length > 0)))}' >>"$tmp/clis"
    done
    jq -sc '{status: (if any(.[]; (.missingFlags | length) > 0) then "failed" else "ok" end), clis: .}' "$tmp/clis"
    exit "$bad"
fi

# ---------------------------------------------------------------- arguments

if [ -n "${AGENT_SKILLS_DELEGATE-}" ]; then
    finish failed "$GUARD is set: this process is already a delegate and must not start another one."
fi
case $Mode in read-only|write) ;; *) fail_arguments "-Mode must be read-only or write, not '$Mode'." ;; esac
if [ -z "$WorkDir" ] || [ ! -d "$WorkDir" ]; then fail_arguments "-WorkDir '$WorkDir' is not a directory."; fi
if [ -z "$PromptFile" ] || [ ! -f "$PromptFile" ]; then fail_arguments "-PromptFile '$PromptFile' does not exist."; fi
[ -n "$OutFile" ] || fail_arguments '-OutFile is required.'
if [ -n "$SchemaFile" ] && [ ! -f "$SchemaFile" ]; then fail_arguments "-SchemaFile '$SchemaFile' does not exist."; fi
if [ -n "$HostHarness" ]; then
    case $HostHarness in claude|codex|cursor) ;; *) fail_arguments "-HostHarness must be one of claude, codex, cursor." ;; esac
fi
WorkDir=$(cd -- "$WorkDir" && pwd) || fail_arguments "-WorkDir '$WorkDir' is not a directory."
r_outfile=$OutFile

# The skills folder is always readable, so briefs can point at the standards and references.
script_dir=$(cd -- "$(dirname -- "$0")" && pwd)
skills_root=$(cd -- "$script_dir/../.." && pwd)
read_dirs=$skills_root
add_read_dir() {
    case "$nl$read_dirs$nl" in *"$nl$1$nl"*) ;; *) read_dirs="$read_dirs$nl$1" ;; esac
}
# Skills reached through links live elsewhere; briefs may name either path.
for child in "$skills_root"/*; do
    if [ -L "$child" ] && [ -d "$child" ]; then
        real=$(cd -P -- "$child" && pwd -P) && add_read_dir "$real"
    fi
done
if [ -n "$ReadDir" ]; then
    set -f; IFS=:
    # shellcheck disable=SC2086
    set -- $ReadDir
    unset IFS; set +f
    for d in "$@"; do
        [ -n "$d" ] || continue
        [ -d "$d" ] || fail_arguments "-ReadDir '$d' is not a directory."
        read_dirs="$read_dirs$nl$(cd -- "$d" && pwd)"
    done
fi

if [ -n "$Role" ]; then
    [ -n "$HostHarness" ] || fail_arguments '-Role needs -HostHarness, to apply hostOverrides.'
    [ -f "$RoleFile" ] || finish unavailable "Role file '$RoleFile' not found."
    jq -e 'type == "object"' "$RoleFile" >/dev/null 2>&1 || finish unavailable "Role file '$RoleFile' is not valid JSON."
    # A host override replaces the whole role: effort levels belong to one harness.
    role_field() {
        jq -r --arg host "$HostHarness" --arg role "$Role" --arg f "$1" '
            (try .hostOverrides[$host][$role] catch null) as $o
            | (if $o != null then $o else (try .roles[$role] catch null) end) as $e
            | if ($e | type) == "object" and $e[$f] != null
              then ($e[$f] | if type == "string" then . else tojson end) else "" end' "$RoleFile" 2>/dev/null
    }
    [ -n "$Harness" ] || Harness=$(role_field harness)
    [ -n "$Model" ] || Model=$(role_field model)
    [ -n "$Effort" ] || Effort=$(role_field effort)
    r_harness=$Harness r_model=$Model
    if [ -z "$Harness" ] || [ -z "$Model" ]; then
        finish unavailable "Role '$Role' on host '$HostHarness' has no harness and model in '$RoleFile'."
    fi
fi
case $Harness in
    claude|codex|cursor) ;;
    *) fail_arguments "-Harness must be one of claude, codex, cursor, not '$Harness'." ;;
esac
[ -n "$Model" ] || fail_arguments 'Pass -Model or a -Role that sets one.'

# ---------------------------------------------------------------- work directory guards

git_state() {   # one hash of HEAD, status and diff; fails outside a repository
    git -C "$1" rev-parse --show-toplevel >/dev/null 2>&1 || return 1
    {
        git -C "$1" rev-parse HEAD
        git -C "$1" status --porcelain=v1 --untracked-files=all
        git -C "$1" diff HEAD --binary
    } 2>/dev/null | git hash-object --stdin
}

if [ "$Mode" = write ]; then
    # Write mode runs only in a linked worktree, never in a main checkout.
    # Resolve the paths ourselves: --path-format=absolute needs git 2.31 or later.
    not_worktree="Write mode needs a linked git worktree (git worktree add); '$WorkDir' is not one."
    git -C "$WorkDir" rev-parse --git-dir --git-common-dir >"$tmp/gitdirs" 2>/dev/null || finish failed "$not_worktree"
    git_dirs=''
    while IFS= read -r g; do
        case $g in /*) ;; *) g="$WorkDir/$g" ;; esac
        g=$(cd -- "$g" 2>/dev/null && pwd -P) || finish failed "$not_worktree"
        git_dirs="$git_dirs$g$nl"
    done <"$tmp/gitdirs"
    git_dir=$(printf '%s' "$git_dirs" | sed -n 1p)
    common_dir=$(printf '%s' "$git_dirs" | sed -n 2p)
    if [ -z "$git_dir" ] || [ -z "$common_dir" ] || [ "$git_dir" = "$common_dir" ]; then
        finish failed "$not_worktree"
    fi
fi

# ---------------------------------------------------------------- run

cmd=$(adapter_command "$Harness")
launcher=$(resolve_launcher "$cmd") || finish unavailable "$cmd is not installed (not found on PATH)."
signed_in "$Harness" "$launcher" ||
    finish unavailable "$cmd is not signed in. Sign in to it yourself; this script never handles credentials."
if offered_models "$Harness" "$launcher" >"$tmp/models"; then
    tr -d '\r' <"$tmp/models" | grep -qixF -- "$Model" || finish unavailable "$cmd does not offer model '$Model'."
fi

schema='' schema_file=''
if [ -n "$SchemaFile" ]; then
    schema_file="$(cd -- "$(dirname -- "$SchemaFile")" && pwd)/$(basename -- "$SchemaFile")"
    schema=$(jq -c . "$schema_file" 2>/dev/null) || fail_arguments "-SchemaFile '$SchemaFile' is not valid JSON."
fi
last_message=''
before=''
[ "$Mode" = read-only ] && before=$(git_state "$WorkDir")

build_args
set --
while IFS= read -r a; do set -- "$@" "$a"; done <"$tmp/args"
echo "agent-run: $cmd $*" >&2
run_cli "$WorkDir" "$run_stdin" "$TimeoutSec" "$launcher" "$@"
r_exit=$run_code

out_dir=$(dirname -- "$OutFile")
mkdir -p -- "$out_dir" 2>/dev/null
{ printf '# stdout\n'; cat "$tmp/stdout"; printf '\n# stderr\n'; cat "$tmp/stderr"; printf '\n'; } >"$OutFile.log"

[ "$run_timed_out" = 1 ] && finish timeout "No result after $TimeoutSec seconds; the process tree was killed."

parse_run
[ -n "$p_model" ] && r_model=$p_model
[ -n "$p_session" ] && r_session=$p_session
[ "$p_has_text" = 1 ] && cp "$tmp/text" "$OutFile"

if [ "$run_code" != 0 ]; then
    if [ -n "$p_error" ]; then
        why=$p_error
    else   # the last five lines of stderr, trimmed, on one line
        why=$(tr -d '\r' <"$tmp/stderr" | awk '
            { line[NR] = $0 }
            END {
                first = 1; last = NR
                while (first <= last && line[first] ~ /^[[:space:]]*$/) first++
                while (last >= first && line[last] ~ /^[[:space:]]*$/) last--
                if (first > last) exit
                sub(/^[[:space:]]+/, "", line[first]); sub(/[[:space:]]+$/, "", line[last])
                start = last - 4; if (start < first) start = first
                out = line[start]
                for (i = start + 1; i <= last; i++) out = out " " line[i]
                print out
            }')
    fi
    why=$(jq -nr --arg w "$why" 'if ($w | length) > 600 then $w[:600] + " ..." else $w end')
    if cat "$tmp/stderr" "$tmp/stdout" | grep -qiE 'cannot use this model|model[^[:alnum:]_](.*[^[:alnum:]_])?(not (found|available|supported)|does not exist|invalid|unknown)'; then
        finish unavailable "$cmd rejected model '$Model': $why"
    fi
    finish failed "$cmd exited with $run_code: $why"
fi
[ -n "$p_invalid" ] && finish invalid-output "$p_invalid"
[ -n "$p_error" ] && finish failed "$p_error"

if [ -n "$p_model" ] && ! printf '%s\n' "$p_model" | grep -qiF -- "$Model"; then
    finish unavailable "Asked for model '$Model' but $cmd ran '$p_model'. Not substituting."
fi

if [ "$Mode" = read-only ] && [ -n "$before" ] && [ "$(git_state "$WorkDir")" != "$before" ]; then
    finish failed "The read-only delegate changed '$WorkDir'. Check git status there before trusting it."
fi

if [ -n "$SchemaFile" ]; then
    if [ ! -s "$tmp/text" ] || ! jq -se --slurpfile schema "$schema_file" "$SCHEMA_JQ" "$tmp/text" >/dev/null 2>&1; then
        finish invalid-output 'The result does not validate against -SchemaFile.'
    fi
fi

finish ok
