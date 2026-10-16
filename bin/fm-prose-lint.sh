#!/usr/bin/env bash
# fm-prose-lint.sh - advisory, warn-only prose lint for worker status lines and
# report summaries. It enforces the cheap, countable part of the writing profile
# owned by .agents/skills/output-conventions/SKILL.md.
#
# Usage:
#   fm-prose-lint.sh [--] <file|->...
#   fm-prose-lint.sh --sync
#   fm-prose-lint.sh --help
#
# Each input is one message: a status line, a report summary, or a Markdown
# file. "-" reads standard input. Two checks run on every input:
#   Status.LeadSentence  the lead sentence has at most 25 words. Whether it
#                        gives the answer first needs review. Leading blank lines, Markdown
#                        heading lines, and horizontal rules are skipped; a
#                        leading status prefix such as "done [at=<epoch>]: " and
#                        a list or quote marker are not counted; an inline code
#                        span counts as one word. The sentence ends at the first
#                        ".", "!" or "?" followed by a space or line end, or at
#                        the end of its paragraph.
#   Vale                 the config in
#                        .agents/skills/output-conventions/assets/vale/:
#                        Status.SentenceLength (25 words), Status.Idioms, and
#                        the named package rules Google.Passive,
#                        Microsoft.Adverbs and Microsoft.Wordiness. Every input
#                        is linted as Markdown whatever its file name.
# Findings print one per line as <path>:<line>:<column>:<rule>:<message>, the
# same shape as `vale --output=line`; standard input is labelled "stdin".
#
# The lint never blocks: it exits 0 whatever it finds. When `vale` is not on
# PATH it prints a skip note on stderr and still runs the lead-sentence check;
# when vale itself fails it reports that on stderr and still exits 0. Only a
# usage error, such as an unknown option, no input, or a missing file, exits 2.
#
# Vale is optional, never a hard dependency. The named package rules need the
# Google and Microsoft Vale packages: --sync downloads them once with
# `vale sync` (network) into the cache directory
#   ${FM_PROSE_LINT_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/firstmate/vale}
# and until then Vale runs the two Status rules alone, with a note on stderr.
# Every lint run copies the tracked config and the cached packages into a
# private temporary directory, so it never writes into the firstmate checkout.
set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
VALE_ASSETS="$SCRIPT_DIR/../.agents/skills/output-conventions/assets/vale"
CACHE_DIR=${FM_PROSE_LINT_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/firstmate/vale}

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

note() {
  printf 'fm-prose-lint: %s\n' "$*" >&2
}

die_usage() {
  note "$*"
  note "run with --help for usage"
  exit 2
}

have_vale() {
  command -v vale >/dev/null 2>&1
}

# Print a Status.LeadSentence finding for one input when its lead sentence is
# longer than 25 words. $1 is the readable file, $2 the label to print.
lead_sentence_check() {
  awk -v label="$2" -v max=25 '
    function count_words(text,    parts, n, i, words) {
      n = split(text, parts, /[^[:alnum:]_\047\/-]+/)
      words = 0
      for (i = 1; i <= n; i++) if (parts[i] ~ /[[:alnum:]]/) words++
      return words
    }
    function finish() {
      if (started && count_words(sentence) > max) {
        printf "%s:%d:%d:Status.LeadSentence:Lead sentence has %d words, more than %d. Put the answer first.\n", label, line_no, column, count_words(sentence), max
      }
      done = 1
    }
    done { next }
    {
      text = $0
      sub(/\r$/, "", text)
    }
    !started {
      if (text ~ /^[[:space:]]*$/ || text ~ /^[[:space:]]*#/ || text ~ /^[[:space:]]*([-*_=][[:space:]]*)+$/) next
      original = text
      sub(/^[[:space:]]*(>[[:space:]]*)*/, "", text)
      sub(/^([-*+]|[0-9]+[.)])[[:space:]]+/, "", text)
      sub(/^[[:alpha:]][[:alnum:]-]*( \[[^]]*\])*:[[:space:]]+/, "", text)
      started = 1
      line_no = NR
      column = length(original) - length(text) + 1
      sentence = ""
    }
    started {
      if (NR > line_no && text ~ /^[[:space:]]*$/) { finish(); next }
      gsub(/`[^`]*`/, "CODE", text)
      if (match(text, /[.!?]([[:space:]]|$)/)) {
        sentence = sentence " " substr(text, 1, RSTART)
        finish()
        next
      }
      sentence = sentence " " text
    }
    END { if (!done) finish() }
  ' "$1"
}

# Build a private Vale config directory from the tracked assets plus any
# cached packages, and print its path. Notes about missing packages go to
# stderr once per run.
prepare_vale_dir() {
  local dir pkg missing=
  dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-prose-lint.XXXXXX") || return 1
  cp "$VALE_ASSETS/.vale.ini" "$dir/.vale.ini" || return 1
  mkdir -p "$dir/styles" || return 1
  cp -R "$VALE_ASSETS/styles/Status" "$dir/styles/Status" || return 1
  for pkg in Google Microsoft; do
    if [ -d "$CACHE_DIR/styles/$pkg" ]; then
      cp -R "$CACHE_DIR/styles/$pkg" "$dir/styles/$pkg" || return 1
    else
      missing="$missing $pkg"
    fi
  done
  if [ -n "$missing" ]; then
    note "Vale package(s)${missing} not synced, so only the Status rules ran; run '$0 --sync' once to enable Google.Passive, Microsoft.Adverbs and Microsoft.Wordiness"
  fi
  printf '%s\n' "$dir"
}

# Run Vale on one input read from stdin and relabel its findings.
# $1 is the Vale config directory, $2 the readable file, $3 the label.
vale_check() {
  local out rc
  out=$(vale --no-global --no-exit --no-wrap --output=line --config "$1/.vale.ini" --ext=.md < "$2" 2>&1)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    note "vale failed on $3 (exit $rc); its style findings are missing:"
    printf '%s\n' "$out" >&2
    return 0
  fi
  [ -n "$out" ] || return 0
  printf '%s\n' "$out" | awk -v label="$3" '
    index($0, "stdin.md:") == 1 { print label substr($0, 9); next }
    { print }
  '
}

sync_packages() {
  if ! have_vale; then
    note "vale is not installed, so there is nothing to sync; install vale (https://vale.sh) to enable the style checks"
    exit 0
  fi
  mkdir -p "$CACHE_DIR" || { note "cannot create $CACHE_DIR"; exit 0; }
  cp "$VALE_ASSETS/.vale.ini" "$CACHE_DIR/.vale.ini" || { note "cannot write $CACHE_DIR/.vale.ini"; exit 0; }
  if (cd "$CACHE_DIR" && vale --no-global --config "$CACHE_DIR/.vale.ini" sync); then
    note "synced the Google and Microsoft Vale packages into $CACHE_DIR/styles"
  else
    note "vale sync failed; the lint still runs the Status rules without the named package rules"
  fi
  exit 0
}

INPUTS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --sync)
      [ "$#" -eq 1 ] && [ "${#INPUTS[@]}" -eq 0 ] || die_usage "--sync takes no other arguments"
      sync_packages
      ;;
    --) shift; while [ "$#" -gt 0 ]; do INPUTS+=("$1"); shift; done; break ;;
    -) INPUTS+=("-") ;;
    -*) die_usage "unknown option: $1" ;;
    *) INPUTS+=("$1") ;;
  esac
  shift
done

[ "${#INPUTS[@]}" -gt 0 ] || die_usage "no input given"
for input in "${INPUTS[@]}"; do
  [ "$input" = - ] || [ -r "$input" ] || die_usage "cannot read $input"
done

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-prose-lint-input.XXXXXX") || { note "cannot create a temporary directory"; exit 0; }
VALE_DIR=
# shellcheck disable=SC2329 # Invoked by the EXIT trap below.
cleanup() {
  rm -rf "$WORK"
  [ -z "$VALE_DIR" ] || rm -rf "$VALE_DIR"
}
trap cleanup EXIT

if have_vale; then
  VALE_DIR=$(prepare_vale_dir) || { note "cannot prepare the Vale config; running the lead-sentence check alone"; VALE_DIR=; }
else
  note "vale is not installed, so the Vale style checks were skipped; the lead-sentence check still ran (install vale from https://vale.sh to enable them)"
fi

n=0
for input in "${INPUTS[@]}"; do
  n=$((n + 1))
  if [ "$input" = - ]; then
    file="$WORK/stdin.$n"
    cat > "$file"
    label=stdin
  else
    file=$input
    label=$input
  fi
  lead_sentence_check "$file" "$label"
  [ -z "$VALE_DIR" ] || vale_check "$VALE_DIR" "$file" "$label"
done
exit 0
