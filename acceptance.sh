#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
INVOCATION_DIRECTORY="$PWD"

if (( $# > 1 )); then
    print -u2 "Usage: $0 [evidence-directory]"
    exit 64
fi

if (( $# == 1 )); then
    if [[ "$1" == /* ]]; then
        EVIDENCE_DIRECTORY="$1"
    else
        EVIDENCE_DIRECTORY="$INVOCATION_DIRECTORY/$1"
    fi
else
    RUN_ID="$(date -u '+%Y%m%dT%H%M%SZ')-$$"
    EVIDENCE_DIRECTORY="$ROOT/.scratch/acceptance/$RUN_ID"
fi

if [[ -e "$EVIDENCE_DIRECTORY" ]]; then
    print -u2 "Evidence directory already exists: $EVIDENCE_DIRECTORY"
    exit 73
fi

mkdir -p "$EVIDENCE_DIRECTORY"
OUTCOME="FAIL"

finish() {
    local exit_code=$?
    if [[ "$OUTCOME" != "PASS" || $exit_code -ne 0 ]]; then
        OUTCOME="FAIL"
    fi
    {
        print "outcome=$OUTCOME"
        print "exit_code=$exit_code"
    } > "$EVIDENCE_DIRECTORY/result.txt"
    print
    print "Acceptance outcome: $OUTCOME"
    print "Evidence: $EVIDENCE_DIRECTORY"
}
trap finish EXIT

exec > >(tee "$EVIDENCE_DIRECTORY/workflow.log") 2>&1
cd "$ROOT"

print "Vibestick initial-milestone acceptance"
print "Started: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
print "Source: $ROOT"
print "Evidence: $EVIDENCE_DIRECTORY"

if ! SOURCE_COMMIT="$(git rev-parse HEAD 2>/dev/null)"; then
    print -u2 "Source is not a Git worktree with an identifiable commit"
    exit 65
fi
if ! SOURCE_STATUS="$(git status --short 2>/dev/null)"; then
    print -u2 "Could not inspect the source worktree"
    exit 65
fi

{
    print "timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    print "source=$ROOT"
    print "git_commit=$SOURCE_COMMIT"
    print "git_status_begin"
    print -r -- "$SOURCE_STATUS"
    print "git_status_end"
    print "macos=$(sw_vers -productVersion 2>/dev/null || print unavailable)"
    print "architecture=$(uname -m)"
    print "swift_begin"
    swift --version
    print "swift_end"
} > "$EVIDENCE_DIRECTORY/environment.txt"

cp \
    "$ROOT/docs/initial-milestone-acceptance-checklist.md" \
    "$EVIDENCE_DIRECTORY/manual-checklist.md"

if [[ -n "$SOURCE_STATUS" ]]; then
    print -u2 "Source tree is not clean; commit or remove all changes before acceptance"
    print -r -- "$SOURCE_STATUS"
    exit 65
fi

print
print "== Clean source tree =="
swift package clean

print
print "== Automated tests =="
swift test

print
print "== Source-built application =="
"$ROOT/build.sh"
if [[ ! -x "$ROOT/Vibestick.app/Contents/MacOS/Vibestick" ]]; then
    print -u2 "Source build did not produce an executable Vibestick.app"
    exit 1
fi

OUTCOME="PASS"
