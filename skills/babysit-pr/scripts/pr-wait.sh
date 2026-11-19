#!/bin/sh
# Watch one GitHub pull request and print one line per real event.
#
# sh <skill dir>/scripts/pr-wait.sh <pr number or URL>
#    [-Repo owner/name] [-Until green|ready|any-change] [-IntervalSec 20]
#    [-MaxWaitSec <n>] [-Once] [-GatingBots <names>] [-Json]
#
# The Linux and macOS twin of pr-wait.ps1: same arguments, output, exit codes and
# state. Needs gh and jq (1.6 or later); runs under any POSIX sh (dash, macOS sh).
#
# stdout carries one line per real event and nothing else; progress goes to stderr.
# -Until
#   green       the gating checks passed on the current head. Gating checks are the
#               required checks; when none are required, or the rules cannot be read,
#               every CI check gates.
#   ready       green, every gating bot (-GatingBots, comma-separated, default none)
#               reviewed the current head, no unresolved review thread, and the branch
#               is not behind (default)
#   any-change  stop after the first poll that prints an event
# Exit codes
#   0  the -Until condition is met on the current head, or the PR merged
#   1  action needed: a gating check failed, conflicts, PR closed, ready blocked by
#      unresolved threads or a branch that is behind, or GitHub stayed unreachable
#   2  bad arguments, unknown PR, gh or jq missing, gh signed out, or another watcher
#      holds this PR
#   3  still pending when -MaxWaitSec ran out, or after -Once. Run it again.
#
# State lives in $XDG_STATE_HOME/pr-wait or ~/.local/state/pr-wait ($PR_WAIT_STATE_DIR
# overrides). The first run for a PR records what exists and reports only what comes
# after; a restart reports what arrived while nothing was watching. One watcher per PR,
# through a lock directory (<repo>__<pr>.lock.d) that holds the watcher's pid; a lock
# whose pid no longer runs is free. It does not exclude a pr-wait.ps1 run on the same PR.

set -u

STALE_STATE_MIN=360
MAX_FAILED_POLLS=10
GH_TIMEOUT_SEC=60
BACKOFF=${PR_WAIT_BACKOFF_SEC:-2}
TRANSIENT='HTTP (5[0-9][0-9]|429)|rate limit|timed? ?out|connection (reset|refused)|(^|[^[:alnum:]_])EOF([^[:alnum:]_]|$)|temporar|could not resolve host|TLS handshake|Something went wrong'
RATE_LIMIT='rate limit|HTTP 429'
THREAD_QUERY='query($owner: String!, $name: String!, $number: Int!, $endCursor: String) { repository(owner: $owner, name: $name) { pullRequest(number: $number) { reviewThreads(first: 100, after: $endCursor) { pageInfo { hasNextPage endCursor } nodes { isResolved path line comments(first: 100) { nodes { id url body author { login } } } } } } } }'
START=$(date +%s)

PR='' REPO='' UNTIL=ready INTERVAL=20 MAX_WAIT=0 ONCE=false GATING_BOTS='' JSON=false
T='' LOCK_DIR='' STEM='' NUMBER=0

log() { printf 'pr-wait: %s\n' "$1" >&2; }

# Fatal messages go to stdout so a monitor shows the agent why it stopped.
stop_early() {
    if [ "$JSON" = true ] && command -v jq >/dev/null 2>&1; then
        jq -cn --arg id "error:${2:-2}" --arg pr "$PR" --arg text "$1" '{id: $id, pr: $pr, type: "error", text: $text}'
    else
        printf 'pr-wait: %s\n' "$1"
    fi
    exit "${2:-2}"
}

cleanup() {
    if [ -n "$LOCK_DIR" ] && [ "$(cat "$LOCK_DIR/pid" 2>/dev/null)" = "$$" ]; then
        [ "$(cat "$STEM.pid" 2>/dev/null)" = "$$" ] && rm -f "$STEM.pid"
        rm -rf "$LOCK_DIR"
    fi
    [ -n "$T" ] && rm -rf "$T"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# ---------------------------------------------------------------- arguments

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
trim() { _t=$1; _t=${_t#"${_t%%[![:space:]]*}"}; _t=${_t%"${_t##*[![:space:]]}"}; printf '%s' "$_t"; }
# Sets WHOLE to a whole number without leading zeros (sh arithmetic reads 010 as octal).
whole() {
    case $2 in ''|*[!0-9]*) stop_early "$1 must be a whole number, not '$2'." ;; esac
    WHOLE=${2#"${2%%[!0]*}"}
    [ ${#WHOLE} -le 9 ] || stop_early "$1 is too large: '$2'."
    WHOLE=${WHOLE:-0}
}

for _a in "$@"; do [ "$(lower "$_a")" = -json ] && JSON=true; done
_have_pr=false
while [ $# -gt 0 ]; do
    _opt=$(lower "$1")
    case $_opt in
        -repo|-until|-intervalsec|-maxwaitsec|-gatingbots)
            [ $# -ge 2 ] || stop_early "$1 needs a value."
            case $_opt in
                -repo) REPO=$2 ;;
                -until) UNTIL=$2 ;;
                -intervalsec) whole -IntervalSec "$2"; INTERVAL=$WHOLE ;;
                -maxwaitsec) whole -MaxWaitSec "$2"; MAX_WAIT=$WHOLE ;;
                -gatingbots) GATING_BOTS=$2 ;;
            esac
            shift 2 ;;
        -once) ONCE=true; shift ;;
        -json) JSON=true; shift ;;
        -*) stop_early "unknown argument '$1'. Usage: pr-wait.sh <pr> [-Repo owner/name] [-Until green|ready|any-change] [-IntervalSec n] [-MaxWaitSec n] [-Once] [-GatingBots a,b] [-Json]" ;;
        *)
            [ "$_have_pr" = false ] || stop_early "unexpected argument '$1': give one PR."
            PR=$1; _have_pr=true; shift ;;
    esac
done

command -v gh >/dev/null 2>&1 || stop_early 'gh is not installed (not found on PATH).'
command -v jq >/dev/null 2>&1 || stop_early 'jq is not installed (not found on PATH).'

_pr=$(trim "$PR")
[ -n "$_pr" ] || stop_early 'missing PR number. Did a variable expand to nothing? Usage: pr-wait.sh <pr> [-Repo owner/name]'
UNTIL=$(lower "$UNTIL")
case $UNTIL in green|ready|any-change) ;; *) stop_early "-Until must be green, ready or any-change, not '$UNTIL'." ;; esac
[ "$INTERVAL" -ge 1 ] || INTERVAL=1
_url=$(printf '%s\n' "$_pr" | sed -n -e 's#^[hH][tT][tT][pP][sS]\{0,1\}://[gG][iI][tT][hH][uU][bB]\.[cC][oO][mM]/\([^/[:space:]]\{1,\}/[^/[:space:]]\{1,\}\)/[pP][uU][lL][lL]/\([0-9]\{1,\}\).*$#\1 \2#p' | head -n 1)
if [ -n "$_url" ]; then
    [ -n "$REPO" ] || REPO=${_url% *}
    _digits=${_url#* }
else
    _digits=${_pr#\#}
    case $_digits in ''|*[!0-9]*) stop_early "'$PR' is not a PR number or PR URL." ;; esac
fi
_n=${_digits#"${_digits%%[!0]*}"}
{ [ -n "$_n" ] && [ ${#_n} -le 9 ]; } || stop_early "'$PR' is not a valid PR number."
NUMBER=$_n

GATING=$(printf '%s' "$GATING_BOTS" | jq -Rsc 'split(",") | map(match("^\\s*(.*?)\\s*$").captures[0].string // "" | ascii_downcase | select(. != ""))')

T=$(mktemp -d "${TMPDIR:-/tmp}/pr-wait.XXXXXX") || stop_early 'cannot create a temporary folder.'
: >"$T/printed"
: >"$T/required.json"

# ---------------------------------------------------------------- gh

# Run gh once, killing it after GH_TIMEOUT_SEC; sets GH_CODE. gh_once OUT ERR args...
gh_once() {
    _out=$1 _err=$2
    shift 2
    GH_PROMPT_DISABLED=1 gh "$@" >"$_out" 2>"$_err" </dev/null &
    _gh=$!
    (
        _s=''
        trap 'kill "$_s" 2>/dev/null; exit 0' TERM
        sleep "$GH_TIMEOUT_SEC" &
        _s=$!
        if wait "$_s"; then
            echo "gh timed out after $GH_TIMEOUT_SEC s" >>"$_err"
            kill "$_gh" 2>/dev/null
        fi
    ) </dev/null >/dev/null 2>&1 &
    _killer=$!
    wait "$_gh"
    GH_CODE=$?
    kill "$_killer" 2>/dev/null
    wait "$_killer" 2>/dev/null
    return 0
}

# Run gh into a file; retry transient failures with backoff, and back off longer on
# rate limits. On failure sets GH_MSG, GH_TRANSIENT and GH_NOTFOUND and returns 1.
gh_call() {
    _dst=$1
    shift
    _delay=$BACKOFF
    _attempt=1
    while :; do
        gh_once "$_dst" "$T/gh.err" "$@"
        [ "$GH_CODE" -eq 0 ] && return 0
        GH_MSG=$(sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$T/gh.err" | sed '/^$/d' | tail -n 1)
        [ -n "$GH_MSG" ] || GH_MSG="gh exited $GH_CODE"
        # A gh that died without saying why (a crash, a kill) is worth another try.
        if grep -Eiq "$TRANSIENT" "$T/gh.err" || ! grep -q '[^[:space:]]' "$T/gh.err"; then GH_TRANSIENT=1; else GH_TRANSIENT=0; fi
        if grep -Eiq 'HTTP 404|Not Found' "$T/gh.err"; then GH_NOTFOUND=1; else GH_NOTFOUND=0; fi
        { [ "$GH_TRANSIENT" = 1 ] && [ "$_attempt" -lt 5 ]; } || return 1
        if grep -Eiq "$RATE_LIMIT" "$T/gh.err"; then
            _wait=$(awk -v d="$_delay" 'BEGIN { print d * 15 }')
        else
            _wait=$_delay
        fi
        log "gh $1 ${2-}: $GH_MSG; retry in $(awk -v w="$_wait" 'BEGIN { printf "%d", w + 0.5 }')s"
        if awk -v w="$_wait" 'BEGIN { exit !(w > 0) }'; then sleep "$_wait"; fi
        _delay=$(awk -v d="$_delay" 'BEGIN { print d * 2 }')
        _attempt=$((_attempt + 1))
    done
}

# jq could not read what gh returned: not worth retrying.
bad_reply() { GH_MSG="gh returned something that is not JSON ($1)"; GH_TRANSIENT=0; GH_NOTFOUND=0; return 1; }

_auth_out=$T/auth.out
gh_once "$_auth_out" "$T/auth.err" auth status
[ "$GH_CODE" -eq 0 ] || stop_early 'gh is not signed in. Run `gh auth login` yourself; this script never handles credentials.'
if [ -z "$REPO" ]; then
    gh_call "$T/repo.json" repo view --json nameWithOwner ||
        stop_early "no -Repo given and the current directory has no GitHub repo ($GH_MSG)"
    REPO=$(jq -r '.nameWithOwner // ""' "$T/repo.json" 2>/dev/null)
fi
case $REPO in
    */*/*|/*|*/|*[!A-Za-z0-9_./-]*) stop_early "'$REPO' is not owner/name." ;;
    */*) ;;
    *) stop_early "'$REPO' is not owner/name." ;;
esac

# ---------------------------------------------------------------- state and lock

if [ -n "${PR_WAIT_STATE_DIR:-}" ]; then STATE_DIR=$PR_WAIT_STATE_DIR
elif [ -n "${XDG_STATE_HOME:-}" ]; then STATE_DIR=$XDG_STATE_HOME/pr-wait
else STATE_DIR=$HOME/.local/state/pr-wait
fi
case $STATE_DIR in /*) ;; *) STATE_DIR=./$STATE_DIR ;; esac
mkdir -p "$STATE_DIR" || stop_early "cannot create the state folder $STATE_DIR."
STEM=$STATE_DIR/$(printf '%s' "$REPO" | sed 's#/#__#')__$NUMBER
STATE_PATH=$STEM.json

# One watcher per PR. mkdir is atomic; the lock directory holds the owner's pid, and a
# lock whose pid no longer runs (a killed watcher never ran its exit trap) is free.
_lock=$STEM.lock.d
if ! mkdir "$_lock" 2>/dev/null; then
    _other=$(cat "$_lock/pid" 2>/dev/null)
    # The owner writes its pid right after mkdir; give it a moment.
    [ -n "$_other" ] || { sleep 1; _other=$(cat "$_lock/pid" 2>/dev/null); }
    if [ -n "$_other" ] && kill -0 "$_other" 2>/dev/null; then
        stop_early "pid $_other already watches $REPO#$NUMBER, so this watcher exits to avoid duplicate events. If no events reach you from it, stop pid $_other and start again."
    fi
    rm -rf "$_lock"
    mkdir "$_lock" 2>/dev/null ||
        stop_early "another watcher took the lock for $REPO#$NUMBER first, so this watcher exits to avoid duplicate events."
fi
LOCK_DIR=$_lock
echo $$ >"$LOCK_DIR/pid"
echo $$ >"$STEM.pid"

if [ -f "$STATE_PATH" ] && [ -n "$(find "$STATE_PATH" -mmin -"$STALE_STATE_MIN" 2>/dev/null)" ] &&
    jq -c 'if type == "object" then {reported: [(.reported // [])[] | select(. != null) | tostring], baseOid: (.baseOid // null), mergeState: (.mergeState // null)} else error("not state") end' \
        "$STATE_PATH" >"$T/state.json" 2>/dev/null; then
    BASELINE=false
else
    BASELINE=true
    echo '{"reported":[],"baseOid":null,"mergeState":null}' >"$T/state.json"
fi

save_state() {
    cp "$T/state.json" "$STATE_PATH.tmp" && mv -f "$STATE_PATH.tmp" "$STATE_PATH"
}

write_line() { # id type text
    grep -Fxq -- "$3" "$T/printed" && return 0
    printf '%s\n' "$3" >>"$T/printed"
    if [ "$JSON" = true ]; then
        jq -cn --arg id "$1" --argjson pr "$NUMBER" --arg type "$2" --arg text "$3" '{id: $id, pr: $pr, type: $type, text: $text}'
    else
        printf '#%s %s\n' "$NUMBER" "$3"
    fi
}

complete() { # code id type text [failed]
    [ -n "$4" ] && write_line "$2" "$3" "$4"
    # A first run that never finished a poll has no baseline worth keeping: saving an
    # empty one would make the next run report everything that exists as new.
    { [ "${5-}" = failed ] && [ "$BASELINE" = true ]; } || save_state
    exit "$1"
}

# ---------------------------------------------------------------- reading GitHub

# Required checks for the base branch: known, none, or unknown (rules unreadable).
read_required() {
    _unknown=''
    if ! gh_call "$T/rules.json" api "repos/$REPO/rules/branches/$BASE"; then
        [ "$GH_NOTFOUND" = 1 ] || _unknown="rulesets: $GH_MSG"
        echo null >"$T/rules.json"
    fi
    if ! gh_call "$T/protection.json" api "repos/$REPO/branches/$BASE/protection/required_status_checks"; then
        # "Branch not protected" and "Required status checks not enabled" mean none.
        printf '%s' "$GH_MSG" | grep -Eiq 'not protected|not enabled' ||
            _unknown="${_unknown:+$_unknown; }branch protection: $GH_MSG"
        echo null >"$T/protection.json"
    fi
    jq -n --arg why "$_unknown" --slurpfile rules "$T/rules.json" --slurpfile prot "$T/protection.json" '
        def expand: if . == null then empty elif type == "array" then .[] | expand else . end;
        def lc: if . == null then "" else tostring | ascii_downcase end;
        if $why != "" then {state: "unknown", checks: [], why: $why} else
        [$rules[0] | expand | select(type == "object" and .type == "required_status_checks")
         | (.parameters.required_status_checks? // [])[] | select(. != null)
         | {name: (.context // ""), app: (.integration_id // null)}] as $ruleset
        | ($prot[0] // {}) as $p
        | [($p.checks? // [])[] | select(. != null) | {name: (.context // ""), app: (.app_id // null)}] as $classic
        | (reduce $classic[] as $c ({}; .[$c.name | lc] = true)) as $seen
        | [($p.contexts? // [])[] | select(. != null and . != "" and ($seen[lc] | not)) | {name: ., app: null}] as $contexts
        | ($ruleset + $classic + $contexts) as $all
        | if ($all | length) > 0 then {state: "known", checks: $all, why: ""} else {state: "none", checks: [], why: ""} end
        end' >"$T/required.json" || bad_reply 'required checks' || return 1
    _g=$(jq -r 'if .state == "known" then ([.checks[].name] | join(", "))
                elif .state == "none" then "none set, so every CI check gates"
                else "unknown (\(.why)), so every CI check gates" end' "$T/required.json")
    log "watching $REPO#$NUMBER until $UNTIL; required checks: $_g"
}

short() { printf '%s' "$1" | cut -c1-7; }

# Every check, review and approval belongs to a head. If the head moves while we read,
# the snapshot mixes two heads: discard it and read again.
snapshot() {
    _try=1
    while [ "$_try" -le 3 ]; do
        gh_call "$T/pr.json" api "repos/$REPO/pulls/$NUMBER" || return 1
        _vars=$(jq -r '@sh "SNAP=\(if .merged == true then "merged" elif .state != "open" then "closed" else "open" end) PR_URL=\(.html_url // "") HEAD=\(.head.sha // "") BASE=\(.base.ref // "")"' "$T/pr.json") ||
            bad_reply "repos/$REPO/pulls/$NUMBER" || return 1
        eval "$_vars"
        [ "$SNAP" = open ] || return 0
        if [ ! -s "$T/required.json" ]; then read_required || return 1; fi
        gh_call "$T/runs.json" api --paginate --slurp "repos/$REPO/commits/$HEAD/check-runs?per_page=100" || return 1
        gh_call "$T/statuses.json" api --paginate --slurp "repos/$REPO/commits/$HEAD/status?per_page=100" || return 1
        gh_call "$T/comments.json" api --paginate --slurp "repos/$REPO/issues/$NUMBER/comments?per_page=100" || return 1
        gh_call "$T/reviews.json" api --paginate --slurp "repos/$REPO/pulls/$NUMBER/reviews?per_page=100" || return 1
        gh_call "$T/threads.json" api graphql --paginate --slurp -f "query=$THREAD_QUERY" \
            -F "owner=${REPO%%/*}" -F "name=${REPO#*/}" -F "number=$NUMBER" || return 1
        gh_call "$T/branch.json" api "repos/$REPO/branches/$BASE" || return 1
        BASE_OID=$(jq -r '.commit.sha // ""' "$T/branch.json") || bad_reply "repos/$REPO/branches/$BASE" || return 1
        gh_call "$T/pr-again.json" api "repos/$REPO/pulls/$NUMBER" || return 1
        _again=$(jq -r '.head.sha // ""' "$T/pr-again.json") || bad_reply "repos/$REPO/pulls/$NUMBER" || return 1
        [ "$_again" = "$HEAD" ] && return 0
        log "head moved from $(short "$HEAD") to $(short "$_again") during a poll; reading again"
        _try=$((_try + 1))
    done
    GH_MSG='the head kept moving during three reads'
    GH_TRANSIENT=1
    GH_NOTFOUND=0
    return 1
}

# ---------------------------------------------------------------- one poll

# Everything a poll decides, from the snapshot files. Output: the lines to print, the
# texts they carry, the new state, the exit code when the watch ends, the pending line.
POLL_JQ='
def s: if . == null then "" else tostring end;
def lc: s | ascii_downcase;
def expand($items):
    if . == null then empty
    elif type == "array" then .[] | expand($items)
    elif $items != "" and type == "object" and has($items) then .[$items] | expand("")
    else . end;
def rank: {fail: 4, cancel: 3, pending: 2, pass: 1, skipping: 0}[.];
def bucket($status; $conclusion):
    if $status != "completed" then "pending"
    elif $conclusion == "success" or $conclusion == "neutral" then "pass"
    elif $conclusion == "skipped" then "skipping"
    elif $conclusion == "cancelled" then "cancel"
    else "fail" end;
# The text between markers, dropping each marked span; a span that never closes stays.
def drop($open; $close; $min):
    split($open) as $p
    | reduce $p[1:][] as $piece ({out: [$p[0]], pend: null};
        ($piece | split($close)) as $q
        | if ($q | length) <= 1 then .pend = ((.pend // "") + $open + $piece)
          elif .pend == null and ($q[0] | length) < $min then .out += [$open + $piece]
          else .out += [" ", ($q[1:] | join($close))] | .pend = null end)
    | (.out + [.pend // ""]) | add;
# HTML comments and tags out, whitespace collapsed, at most 100 characters. Built from
# splits and one match, not gsub, which is quadratic in jq 1.6.
def snippet:
    s | drop("<!--"; "-->"; 0) | drop("<"; ">"; 1)
    | [limit(101; match("\\S+"; "g") | .string)] | join(" ")
    | if length <= 100 then . else .[0:97] + "..." end;
def botname: lc as $l | first($gating[] | select(. as $b | $l | contains($b))) // null;
def statusbot: lc as $l | any(("github-actions", "vercel", "netlify", "railway", "cloudflare"); . as $b | $l | contains($b));
def line($id; $type; $text):
    if .printed[$text] then . else
        .printed[$text] = true | .texts += [$text]
        | .lines += [if $json then ({id: $id, pr: $number, type: $type, text: $text} | tojson) else "#\($number) \($text)" end]
    end;
# Print an event once per PR, across restarts. The first run only records.
def send($key; $type; $text):
    if .final != null or .reported[$key] then . else
        .reported[$key] = true | if $baseline then . else .events += 1 | line($key; $type; $text) end
    end;
def remember($key): if .final != null then . else .reported[$key] = true end;
def finish($code; $id; $type; $text):
    if .final != null then . else (if $text != "" then line($id; $type; $text) else . end) | .final = $code end;

$pr[0] as $p
| ($p.head.sha | s) as $head | $head[0:7] as $short | ($p.base.ref | s) as $base
| ([$p.user.login, $viewer] | map(lc)) as $mine
| def skip($login): ($login | lc) as $l | any($mine[]; . == $l) or ($login | botname) != null or ($login | statusbot);
  $required[0] as $req
| (if $req.state == "unknown" then " (required checks unknown: gated on every CI check)" else "" end) as $note
| ([$runs[0] | expand("check_runs") | select(type == "object")
    | {name: (.name | s), bucket: bucket(.status; .conclusion), link: (.html_url | s), app: (.app.id? // null)}]
   + [$statuses[0] | expand("statuses") | select(type == "object")
    | {name: (.context | s), bucket: (if .state == "success" then "pass" elif .state == "pending" then "pending" else "fail" end),
       link: (.target_url | s), app: null}]) as $checks
# Collapse duplicate names to the worst bucket.
| (reduce $checks[] as $c ({}; ($c.name | lc) as $k
    | if .[$k] == null then .[$k] = $c
      elif ($c.bucket | rank) > (.[$k].bucket | rank) then .[$k] = ($c + {name: .[$k].name})
      else . end)) as $byName
# Gating checks: the required set (matched on the app where GitHub names one), else every CI check.
| (if $req.state == "known" then
     reduce $req.checks[] as $r ({}; ($r.name | lc) as $k
       | ([$checks[] | select((.name | lc) == $k and ($r.app == null or $r.app == -1 or .app == $r.app))]
          | reduce .[] as $m (null; if . == null or ($m.bucket | rank) > (.bucket | rank) then $m else . end)) as $worst
       | .[$k] = {name: (.[$k].name // ($r.name | s)), bucket: ($worst.bucket // "pending"), link: ($worst.link // "")})
   else $byName | with_entries(select((.value.name | botname) == null)) end) as $gate
| (if $req.state == "known" then "required check" else "check" end) as $checkWord
| [$gate | to_entries | sort_by(.key)[] | .value | select(.bucket == "fail" or .bucket == "cancel")
   | {key: "fail:\($head):\(.name):\(.link)", text: (if .link == "" then "\($checkWord) failed: \(.name)" else "\($checkWord) failed: \(.name) \(.link)" end)}] as $fails
| (($gate | length) > 0 and ([$gate[] | select(.bucket == "pending")] | length) == 0) as $gateDone
| ($gateDone and ([$byName[] | select(.bucket == "pending")] | length) == 0) as $allDone
| ($byName | to_entries | sort_by(.key) | map("\(.value.name)=\(.value.bucket)") | join(";")) as $fingerprint
# Checks register a few seconds after a push: when watching, two identical polls in a
# row guard against calling a half-registered set finished.
| ($once or $fingerprint == $prev) as $stable
| ($gateDone and $stable and ($fails | length) == 0) as $green
| [$comments[0] | expand("") | select(type == "object")] as $cs
| [$reviews[0] | expand("") | select(type == "object")] as $rs
| [$threads[0] | expand("") | select(type == "object") | .data.repository.pullRequest.reviewThreads.nodes? // [] | .[] | select(type == "object")] as $ts
| [$ts[] | select((.isResolved | not) and ((.comments.nodes? // []) | length) > 0) | .comments.nodes[0].url | s] as $unresolved
| ($p.mergeable_state | s | ascii_upcase) as $ms
| "merge state is DIRTY: the branch conflicts with \($base), rebase it" as $dirty
| "merge state is BEHIND: update the branch from \($base) before merging" as $behind
| {reported: (reduce $state[0].reported[] as $k ({}; .[$k] = true)),
   printed: (reduce ($printed | split("\n") | .[] | select(. != "")) as $t ({}; .[$t] = true)),
   lines: [], texts: [], events: 0, final: null, reviewed: [],
   baseOid: $state[0].baseOid, mergeState: $state[0].mergeState}
| reduce $fails[] as $f (.; send($f.key; "check-failed"; $f.text))
# People talking. Comment edits are never events.
| reduce $cs[] as $c (.; ($c.user.login? | s) as $login
    | if skip($login) then . else
        send("c:\($c.id | s)"; "comment"; "comment from \($login): \($c.body | snippet) \($c.html_url | s)") end)
| reduce $rs[] as $r (.; ($r.user.login? | s) as $login | ($r.state | s | ascii_upcase) as $st
    | if skip($login) then .
      elif $st == "APPROVED" or $st == "CHANGES_REQUESTED" or ($r.body | s | test("\\S")) then
        send("r:\($r.id | s)"; "review"; "review from \($login) (\($st | ascii_downcase | split("_") | join(" "))): \($r.body | snippet) \($r.html_url | s)")
      else . end)
| reduce $ts[] as $t (.; [($t.comments.nodes? // [])[]] as $nodes
    | (if ($t.line // 0) != 0 then "\($t.path | s):\($t.line)" else ($t.path | s) end) as $where
    | reduce range(0; $nodes | length) as $i (.; $nodes[$i] as $n | ($n.author.login? // null) as $login
        | if $login != null and any($mine[]; . == ($login | lc)) then . else
            send("t:\($n.id | s)"; "thread"; "\(if $i == 0 then "new thread" else "thread reply" end) from \($login | s) on \($where): \($n.body | snippet) \($n.url | s)") end))
# Gating bots on the current head: a review of the head commit, its own checks finished,
# or a summary comment that names the head.
| reduce $gating[] as $bot (.;
    [$checks[] | select((.name | botname) == $bot)] as $own
    | ([$rs[] | select((.user.login? | lc | contains($bot)) and .commit_id == $head)] | length > 0) as $onHead
    | ([$cs[] | select((.user.login? | lc | contains($bot)) and (.body | s | contains($short)))] | length > 0) as $summary
    | (if ($own | length) > 0 then ([$own[] | select(.bucket == "pending")] | length) == 0 else ($onHead or $summary) end) as $done
    | if $done then .reviewed += [$bot] | send("bot:\($bot):\($head)"; "bot"; "\($bot) finished on \($short)") else . end)
# Base branch and merge state.
| if $compared then
    [$baseFiles[0] | expand("") | select(type == "object") | .filename | s] as $mineFiles
    | (reduce ($compare[0].files? // [])[] as $f ({}; .[$f.filename | lc] = true)) as $moved
    | ([$mineFiles[] | select($moved[lc])] | sort_by(ascii_downcase)) as $touched
    | if ($touched | length) > 0 then
        send("base:\($baseOid)"; "base-moved"; "\($base) moved to \($baseOid[0:7]) and touches files in this PR: \($touched[0:5] | join(", "))\(if ($touched | length) > 5 then " and \(($touched | length) - 5) more" else "" end)")
      else . end
  else . end
| if $baseOid != "" then .baseOid = $baseOid else . end
| if ($ms == "BEHIND" or $ms == "DIRTY") and .mergeState != $ms then
    send("merge:\($ms):\($head):\($baseOid)"; "merge-state"; (if $ms == "DIRTY" then $dirty else $behind end))
  else . end
| if $ms != "" and $ms != "UNKNOWN" then .mergeState = $ms else . end
# Summary for the checks line and the final lines.
| ([[$byName[] | .bucket] | group_by(.)[] | "\(length) \(.[0])"] | join(", ")) as $counts
| ([$counts]
   + (if $req.state == "known" then ["required \([$gate[] | select(.bucket == "pass" or .bucket == "skipping")] | length)/\($gate | length) green"] else [] end)
   + (if ($gating | length) > 0 then ["bots reviewed: \(if (.reviewed | length) > 0 then .reviewed | join(", ") else "none yet" end)"] else [] end)
   + ["\($unresolved | length) unresolved threads", "merge state \($ms)"]
   | map(select(. != "")) | join("; ")) as $summary
| if $until != "any-change" then
    (if $ms == "DIRTY" then finish(1; "final:dirty:\($head)"; "blocked"; $dirty) else . end)
    | (if ($fails | length) > 0 then finish(1; "final:failed:\($head)"; "failed"; "\($fails[-1].text)\($note)") else . end)
    | (if $green and $until == "green" then
         remember("checks:\($head)") | finish(0; "final:green:\($head)"; "green"; "green on \($short): \($summary)\($note)")
       else . end)
    | (if $green and $until == "ready" and (.reviewed | length) == ($gating | length) then
         (if ($unresolved | length) > 0 then
            finish(1; "final:threads:\($head)"; "blocked"; "blocked by \($unresolved | length) unresolved threads on \($short): \($unresolved | join(" "))")
          else . end)
         | (if $ms == "BEHIND" then finish(1; "final:behind:\($head)"; "blocked"; $behind) else . end)
         | remember("checks:\($head)") | finish(0; "final:ready:\($head)"; "ready"; "ready on \($short): \($summary)\($note)")
       else . end)
  else . end
| if $allDone and ($stable or $baseline) then send("checks:\($head)"; "checks-finished"; "checks finished on \($short): \($summary)") else . end
| if $until == "any-change" and .events > 0 then finish(0; ""; ""; "") else . end
| {lines, texts, final, fingerprint: $fingerprint, pending: "still pending on \($short): \($summary)\($note)",
   state: {reported: (.reported | keys_unsorted), baseOid, mergeState}}
'

PREV=null
VIEWER=''

# One poll. Returns 1 when gh failed (GH_* say why); exits when the watch ends.
poll() {
    snapshot || return 1
    [ "$SNAP" = merged ] && complete 0 final:merged merged "merged: $PR_URL"
    [ "$SNAP" = closed ] && complete 1 final:closed closed "closed without merging: $PR_URL"
    if [ -z "$VIEWER" ]; then
        gh_call "$T/user.json" api user || return 1
        VIEWER=$(jq -r '.login // ""' "$T/user.json") || bad_reply user || return 1
    fi
    _compared=false
    _old=$(jq -r '.baseOid // ""' "$T/state.json")
    if [ -n "$BASE_OID" ] && [ -n "$_old" ] && [ "$BASE_OID" != "$_old" ] && [ "$BASELINE" = false ]; then
        if gh_call "$T/base-files.json" api --paginate --slurp "repos/$REPO/pulls/$NUMBER/files?per_page=100" &&
            gh_call "$T/compare.json" api "repos/$REPO/compare/$_old...$BASE_OID"; then
            _compared=true
        else
            log "could not compare base commits: $GH_MSG"
        fi
    fi
    [ "$_compared" = true ] || { echo null >"$T/base-files.json"; echo null >"$T/compare.json"; }
    jq -n \
        --slurpfile pr "$T/pr.json" --slurpfile runs "$T/runs.json" --slurpfile statuses "$T/statuses.json" \
        --slurpfile comments "$T/comments.json" --slurpfile reviews "$T/reviews.json" \
        --slurpfile threads "$T/threads.json" --slurpfile required "$T/required.json" \
        --slurpfile state "$T/state.json" --slurpfile baseFiles "$T/base-files.json" \
        --slurpfile compare "$T/compare.json" --rawfile printed "$T/printed" \
        --arg viewer "$VIEWER" --arg baseOid "$BASE_OID" --arg until "$UNTIL" \
        --argjson prev "$PREV" --argjson gating "$GATING" --argjson number "$NUMBER" \
        --argjson baseline "$BASELINE" --argjson once "$ONCE" --argjson json "$JSON" \
        --argjson compared "$_compared" \
        "$POLL_JQ" >"$T/result.json" || bad_reply 'a poll' || return 1
    jq -r '.lines[]' "$T/result.json"
    jq -r '.texts[]' "$T/result.json" >>"$T/printed"
    jq -c '.state' "$T/result.json" >"$T/state.json"
    PREV=$(jq -c '.fingerprint' "$T/result.json")
    _final=$(jq -r '.final // ""' "$T/result.json")
    [ -n "$_final" ] && complete "$_final" '' '' ''
    PENDING=$(jq -r '.pending' "$T/result.json")
    return 0
}

# ---------------------------------------------------------------- loop

FAILURES=0
FIRST_POLL=true
while :; do
    PENDING='still pending'
    if poll; then
        FAILURES=0
        save_state
        [ "$BASELINE" = true ] && log "baseline recorded for $REPO#$NUMBER; reporting only new events"
        BASELINE=false
    else
        if [ "$FIRST_POLL" = true ] && [ "$GH_NOTFOUND" = 1 ]; then stop_early "cannot read $REPO#$NUMBER: $GH_MSG"; fi
        [ "$GH_TRANSIENT" = 1 ] || complete 1 final:error error "pr-wait stopped: $GH_MSG" failed
        FAILURES=$((FAILURES + 1))
        log "poll failed ($FAILURES/$MAX_FAILED_POLLS): $GH_MSG"
        [ "$FAILURES" -lt "$MAX_FAILED_POLLS" ] ||
            complete 1 final:unreachable error "pr-wait stopped: GitHub unreachable for $FAILURES polls: $GH_MSG" failed
    fi
    FIRST_POLL=false
    _elapsed=$(($(date +%s) - START))
    if [ "$ONCE" = true ] || { [ "$MAX_WAIT" -gt 0 ] && [ $((_elapsed + INTERVAL)) -gt "$MAX_WAIT" ]; }; then
        complete 3 final:pending pending "$PENDING after ${_elapsed}s; run pr-wait again" "$( [ "$BASELINE" = true ] && echo failed )"
    fi
    sleep "$INTERVAL"
done
