#!/bin/sh
# Install the third-party skills listed in apm/apm.yml for every harness, through APM
# (Linux and macOS).
#
#   sh <repository>/scripts/sync-apm.sh
#
# Same behaviour as sync-apm.ps1, without PowerShell. apm/apm.yml in this repository is
# the one list of third-party skills; apm/apm.lock.yaml pins their exact commits. APM
# keeps its user-scope manifest, lock and working state in its home ($APM_HOME, default
# ~/.apm), which is per machine. This script:
#
#   1. copies apm/apm.yml, and apm/apm.lock.yaml when it exists, into the APM home
#   2. runs `apm install -g`, which deploys the skills to ~/.claude/skills (Claude Code)
#      and ~/.agents/skills (Codex, Cursor)
#   3. copies the lock APM wrote back to apm/apm.lock.yaml, to commit
#
# Use it on a new machine to restore the same versions, and after editing apm/apm.yml.
# Never run `apm install -g <package>` directly: that changes the copy in the APM home,
# and the next sync overwrites it.
#
# When apm is missing, it shows the install command and, from a terminal, asks
# "Install it now? [Y/n]" (Enter means yes) and runs exactly that command. Without a
# terminal it only shows the command.
#
# Exit code: APM's own; 2 when apm is not installed (or the install was declined).

set -u
here=$(cd "$(dirname "$0")" && pwd -P)
source_dir="$here/../apm"
manifest="$source_dir/apm.yml"
lock="$source_dir/apm.lock.yaml"
apm_home=${APM_HOME:-"$HOME/.apm"}

if ! command -v apm >/dev/null 2>&1; then
    # The installer for Linux and macOS. SYNC_APM_INSTALL_COMMAND replaces it (used by the tests).
    install=${SYNC_APM_INSTALL_COMMAND:-"curl -sSL https://aka.ms/apm-unix | sh"}
    echo "apm is not installed. It installs with:"
    echo "  $install"
    # Ask only someone at a terminal (SYNC_APM_PROMPT=1 forces the question, for the tests).
    if [ "${SYNC_APM_PROMPT:-}" != 1 ] && [ ! -t 0 ]; then
        echo "Run that, then run this script again."
        exit 2
    fi
    printf 'Install it now? [Y/n] '
    answer=
    read -r answer || true
    case $(printf '%s' "$answer" | tr -d '\r' | tr '[:upper:]' '[:lower:]') in
        '' | y | yes) ;;
        *) echo "Not installed. Run the command above yourself, then run this script again."; exit 2 ;;
    esac

    sh -c "$install"   # exactly the command shown above

    # A fresh install is not on this shell's PATH yet: look where the installer puts it.
    if [ -x "$HOME/.local/bin/apm" ]; then PATH="$HOME/.local/bin:$PATH"; export PATH; fi
    if ! command -v apm >/dev/null 2>&1; then
        echo "apm is still not found after the install. Open a new terminal and run this script again."
        exit 2
    fi
fi
if [ ! -f "$manifest" ]; then
    echo "No manifest at $manifest."
    exit 2
fi

mkdir -p "$apm_home" || exit 1
cp "$manifest" "$apm_home/apm.yml" || exit 1
if [ -f "$lock" ]; then cp "$lock" "$apm_home/apm.lock.yaml" || exit 1; fi

APM_HOME=$apm_home apm install -g
code=$?
if [ "$code" -ne 0 ]; then
    echo "apm install -g failed (exit $code); apm/apm.lock.yaml left as it was."
    exit "$code"
fi

written="$apm_home/apm.lock.yaml"
if [ -f "$written" ]; then
    if [ -f "$lock" ] && cmp -s "$written" "$lock"; then
        echo "apm/apm.lock.yaml unchanged."
    else
        cp "$written" "$lock" || exit 1
        echo "apm/apm.lock.yaml updated; commit it."
    fi
fi
exit 0
