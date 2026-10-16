#!/usr/bin/env bash
# Behavior tests for bin/fm-prose-lint.sh, the advisory prose lint the
# output-conventions skill names. Every case runs the script through its
# command line: it must warn and never block, skip Vale cleanly when it is
# absent, and relabel Vale findings onto the caller's input names.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LINT="$ROOT/bin/fm-prose-lint.sh"
TMP_ROOT=$(fm_test_tmproot fm-prose-lint)
NO_VALE_PATH=$(fm_test_base_path_sans "$PATH" vale)
CACHE="$TMP_ROOT/empty-cache"

# The invented status message from the research behind the profile: one
# 85-word sentence, then its plain rewrite.
BEFORE="$TMP_ROOT/before.md"
AFTER="$TMP_ROOT/after.md"
cat > "$BEFORE" <<'EOF'
Quick update on the portal-auth lane: I went ahead and kicked off the validation pipeline after rebasing onto main (there were two conflicts in the session middleware, both small, which were resolved), and it's currently chugging through the integration suite; assuming nothing blows up it should wrap up in roughly 20 minutes, at which point I'll circle back with the PR link, though it's worth flagging that the token-expiry change touches tenant isolation, so it'll need sign-off from a designated human before anyone merges it.
EOF
cat > "$AFTER" <<'EOF'
Portal-auth lane: validation is running. Merge needs one human approval.

I rebased the branch onto main. I fixed two small conflicts in the session middleware. The integration tests are running now. They should finish in about 20 minutes. Then I will send the PR link.
EOF

run_lint() {  # <path-value> <args...>; sets OUT, ERR, RC
  local path_value=$1
  shift
  OUT=$(PATH="$path_value" FM_PROSE_LINT_CACHE="$CACHE" "$LINT" "$@" 2>"$TMP_ROOT/stderr")
  RC=$?
  ERR=$(cat "$TMP_ROOT/stderr")
}

test_without_vale_skips_cleanly_and_still_checks_the_lead() {
  run_lint "$NO_VALE_PATH" "$BEFORE" "$AFTER"
  expect_code 0 "$RC" "the lint must exit 0 without vale"
  assert_contains "$ERR" "vale is not installed, so the Vale style checks were skipped" \
    "the lint did not say it skipped Vale"
  assert_contains "$OUT" "$BEFORE:1:1:Status.LeadSentence:Lead sentence has 85 words, more than 25." \
    "the lint did not flag the 85-word lead sentence"
  assert_not_contains "$OUT" "$AFTER:" "the lint flagged the plain rewrite"
  run_lint "$NO_VALE_PATH" --sync
  expect_code 0 "$RC" "--sync must exit 0 without vale"
  assert_contains "$ERR" "vale is not installed, so there is nothing to sync" \
    "--sync did not explain the missing vale"
  pass "fm-prose-lint: without vale it warns, skips the style checks, and exits 0"
}

test_lead_sentence_reading_rules() {
  local status heading code later
  status="$TMP_ROOT/status.txt"
  printf '%s\n' 'done [at=1792118584]: I merged the fix, rebased the branch onto main, reran the suite, and pushed the result to the remote today after checking every reported failure again.' > "$status"
  run_lint "$NO_VALE_PATH" "$status"
  assert_contains "$OUT" "$status:1:23:Status.LeadSentence:Lead sentence has 26 words" \
    "the status prefix was counted or mislocated"

  heading="$TMP_ROOT/heading.md"
  printf '%s\n' '# A very long report title that would exceed the sentence word limit if anyone counted all of these words in the heading as ordinary prose instead of a title' '' '---' '' 'The fix is ready for review.' > "$heading"
  run_lint "$NO_VALE_PATH" "$heading"
  assert_not_contains "$OUT" "Status.LeadSentence" "a heading or rule was read as the lead sentence"

  code="$TMP_ROOT/code.md"
  # shellcheck disable=SC2016 # The backticks are literal Markdown, not a substitution.
  printf '%s\n' 'Run `git log --oneline --decorate --graph --all --since one week ago --author someone --grep fix --no-merges --reverse --stat --name-only --date short --format full --color always --max-count 10` first.' > "$code"
  run_lint "$NO_VALE_PATH" "$code"
  assert_not_contains "$OUT" "Status.LeadSentence" "an inline code span counted as more than one word"

  later="$TMP_ROOT/later.md"
  printf '%s\n' 'CI is green.' 'The rest of this paragraph runs on and on with many more words than the lead sentence limit allows here because it describes every remaining task in detail.' > "$later"
  run_lint "$NO_VALE_PATH" "$later"
  assert_not_contains "$OUT" "Status.LeadSentence" "a long second sentence was read as the lead"

  OUT=$(printf '%s\n' 'CI passed every required check for the release after I fixed the reported failure and successfully reran the affected tests on the final branch this morning.' \
    | PATH="$NO_VALE_PATH" FM_PROSE_LINT_CACHE="$CACHE" "$LINT" - 2>/dev/null)
  assert_contains "$OUT" "stdin:1:1:Status.LeadSentence:Lead sentence has 26 words" \
    "standard input was not checked under the stdin label"
  pass "fm-prose-lint: the lead sentence skips headings and prefixes and counts code as one word"
}

test_lead_accepts_the_adopted_word_ceiling() {
  local text
  for text in \
    'CI passed every required check after I fixed the failure and reran the affected tests today.' \
    'CI passed every required check for the release after I fixed the reported failure and reran the affected tests on the final branch this morning.'; do
    OUT=$(printf '%s\n' "$text" | PATH="$NO_VALE_PATH" FM_PROSE_LINT_CACHE="$CACHE" "$LINT" - 2>/dev/null)
    assert_not_contains "$OUT" "Status.LeadSentence" "the lint flagged a lead within the adopted ceiling"
  done
  pass "fm-prose-lint: leads between 16 and 25 words meet the adopted ceiling"
}

test_usage_errors_are_the_only_nonzero_exit() {
  run_lint "$NO_VALE_PATH"
  expect_code 2 "$RC" "no input must be a usage error"
  run_lint "$NO_VALE_PATH" --bogus "$BEFORE"
  expect_code 2 "$RC" "an unknown option must be a usage error"
  run_lint "$NO_VALE_PATH" "$TMP_ROOT/missing.md"
  expect_code 2 "$RC" "a missing file must be a usage error"
  run_lint "$NO_VALE_PATH" --help
  expect_code 0 "$RC" "--help must exit 0"
  assert_contains "$OUT" "The lint never blocks" "--help did not print the header contract"
  pass "fm-prose-lint: only usage errors exit nonzero"
}

# A stand-in vale proves the plumbing: the private config carries the tracked
# Status rules, findings are relabelled onto the input, missing packages are
# named, and a vale failure still exits 0.
test_vale_plumbing_with_a_stand_in() {
  local fakebin
  fakebin=$(fm_fakebin "$TMP_ROOT/stand-in")
  cat > "$fakebin/vale" <<'SH'
#!/usr/bin/env bash
config=
for arg in "$@"; do
  case "$arg" in --config=*) config=${arg#--config=} ;; esac
done
prev=
for arg in "$@"; do
  [ "$prev" = --config ] && config=$arg
  prev=$arg
done
[ -f "$(dirname "$config")/styles/Status/Idioms.yml" ] || { echo "no Status style beside $config" >&2; exit 9; }
cat > /dev/null
[ -z "${STAND_IN_FAIL:-}" ] || { echo "stand-in failure" >&2; exit 3; }
echo "stdin.md:1:5:Status.Idioms:Replace the idiom or filler 'quick update' with the plain fact."
SH
  chmod +x "$fakebin/vale"
  run_lint "$fakebin:$PATH" "$AFTER"
  expect_code 0 "$RC" "the lint must exit 0 with findings"
  assert_contains "$OUT" "$AFTER:1:5:Status.Idioms:" "a Vale finding was not relabelled onto the input"
  assert_contains "$ERR" "Vale package(s) Google Microsoft not synced" \
    "the lint did not say the named package rules were absent"
  OUT=$(STAND_IN_FAIL=1 PATH="$fakebin:$PATH" FM_PROSE_LINT_CACHE="$CACHE" "$LINT" "$AFTER" 2>"$TMP_ROOT/stderr"); RC=$?
  ERR=$(cat "$TMP_ROOT/stderr")
  expect_code 0 "$RC" "a vale failure must not block"
  assert_contains "$ERR" "vale failed on $AFTER (exit 3)" "a vale failure was not reported"
  pass "fm-prose-lint: Vale runs on a private copy of the config, relabels findings, and never blocks"
}

# The real Vale, when this host has it, runs the tracked Status rules without
# any package sync or network.
test_real_vale_status_rules() {
  if ! command -v vale >/dev/null 2>&1; then
    printf '# vale is not installed; the real-Vale case did not run\n'
    return 0
  fi
  run_lint "$PATH" "$BEFORE" "$AFTER"
  expect_code 0 "$RC" "the lint must exit 0 with real Vale findings"
  assert_contains "$OUT" "$BEFORE:1:1:Status.SentenceLength:Sentence has more than 25 words. Split it." \
    "real Vale did not apply the 25-word ceiling"
  assert_contains "$OUT" "$BEFORE:1:1:Status.Idioms:Replace the idiom or filler 'Quick update' with the plain fact." \
    "real Vale did not apply the idiom list"
  assert_not_contains "$OUT" "$AFTER:" "real Vale flagged the plain rewrite"
  pass "fm-prose-lint: real Vale applies the tracked Status rules"
}

test_without_vale_skips_cleanly_and_still_checks_the_lead
test_lead_sentence_reading_rules
test_lead_accepts_the_adopted_word_ceiling
test_usage_errors_are_the_only_nonzero_exit
test_vale_plumbing_with_a_stand_in
test_real_vale_status_rules
