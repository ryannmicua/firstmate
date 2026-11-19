#!/usr/bin/env bash
# Behavior tests for bin/fm-agentmail-check.sh (inbound mail to inbox notes) and
# bin/fm-agentmail-send.sh (allowlisted outbound mail).
#
# Every AgentMail call is answered by the fake curl from tests/fixtures.sh and
# the key is an invented string, so no case touches a real account.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

CHECK="$ROOT/bin/fm-agentmail-check.sh"
SEND="$ROOT/bin/fm-agentmail-send.sh"
TMP_ROOT=$(fm_test_tmproot fm-agentmail)
FAKE_KEY=am_FakeKeyForTests0001
API=https://api.test.invalid
INBOX_PATH='/v0/inboxes/agent%40example.test'

command -v jq >/dev/null 2>&1 || { echo "skip: jq not installed"; exit 0; }

enc_id() {  # <message-id>: its URL-encoded path form
  jq -rn --arg s "$1" '$s | @uri'
}

# msg <name> <message-id> <from> <extra-json>: write one message body and its
# list entry (the same object), received now, labelled received.
msg() {
  local name=$1 id=$2 from=$3 extra=${4:-{\}}
  jq -n --arg id "$id" --arg from "$from" --argjson extra "$extra" --arg inbox agent@example.test '
    {inbox_id: $inbox, thread_id: ("thr-" + $id), message_id: $id, from: $from, to: [$inbox],
     subject: ("Subject " + $id), labels: ["received", "unread"], timestamp: (now - 3600 | floor | todateiso8601),
     extracted_text: ("text of " + $id), authentication_results: {spf: "pass", spf_domain: "example.test"}}
    + $extra' > "$BODIES/$name"
  route GET "$INBOX_PATH/messages/$(enc_id "$id")" 200 "$name"
  route PATCH "$INBOX_PATH/messages/$(enc_id "$id")" 200 empty
}

route() {  # <method> <glob> <status> <body-name>
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$BODIES/$4" >> "$ROUTES"
}

# list_of <name>...: the list response holding those messages, oldest first.
list_of() {
  local n args=()
  for n in "$@"; do args+=("$BODIES/$n"); done
  jq -s '{count: length, messages: (sort_by(.timestamp))}' "${args[@]}" > "$BODIES/list"
}

# make_world <name>: a home whose inbox holds owner mail with authentication
# passing, the same owner address without a pass, an Armor-flagged owner mail,
# a stranger's mail, and a sent message that must be ignored.
make_world() {
  local name=$1 owner='Owner Person <Owner@Example.test>'
  HOME_DIR="$TMP_ROOT/$name/home"
  FAKEBIN=$(fm_fakebin "$TMP_ROOT/$name")
  LOG="$TMP_ROOT/$name/log"
  ROUTES="$TMP_ROOT/$name/routes"
  BODIES="$TMP_ROOT/$name/bodies"
  mkdir -p "$HOME_DIR/config" "$HOME_DIR/state" "$BODIES"
  printf '%s\n' 'inbox=agent@example.test' 'owner=owner@example.test' 'owner=Second@Example.test' \
    'route=Personal-Org:owner@example.test' 'route=work-org:second@example.test' > "$HOME_DIR/config/agentmail"
  (umask 077 && printf '%s\n' "$FAKE_KEY" > "$HOME_DIR/config/agentmail.key")
  printf '{}' > "$BODIES/empty"
  : > "$ROUTES"
  msg owner-pass '<m1@mail.test>' "$owner" '{"attachments":[{"attachment_id":"att1","filename":"report.pdf","size":2048}]}'
  msg owner-nopass '<m2@mail.test>' "$owner" '{"authentication_results":{}}'
  msg owner-armor '<m3@mail.test>' "$owner" '{"agent_armor":{"status":"complete","verdict":"review","reason":"r"}}'
  msg stranger '<m4@mail.test>' 'Stranger <stranger@elsewhere.test>' '{}'
  msg owner-dkim '<m5@mail.test>' "$owner" '{"authentication_results":{"dkim":"pass","dkim_domain":"example.test"}}'
  msg owner-dkim-other '<m6@mail.test>' "$owner" '{"authentication_results":{"dkim":"pass","dkim_domain":"attacker.test"}}'
  msg sent-copy '<m7@mail.test>' 'agent@example.test' '{"labels":["sent"]}'
  msg owner-clear '<m8@mail.test>' "$owner" '{"agent_armor":{"status":"complete","verdict":"clear","reason":"ok"}}'
  list_of owner-pass owner-nopass owner-armor stranger owner-dkim owner-dkim-other sent-copy owner-clear
  route GET "$INBOX_PATH/messages?limit=50&*" 200 list
  fm_test_fake_github_api "$FAKEBIN" "$LOG" "$ROUTES"
}

run_check() {  # <action>: check also waits for the poll job it started
  local i=0 pid rc=0
  env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE FM_HOME="$HOME_DIR" \
    FM_AGENTMAIL_API_URL="$API" FM_GH_API_URL="$API" PATH="$FAKEBIN:$PATH" "$CHECK" "$1" 2>&1 || rc=$?
  [ "$1" = check ] || return "$rc"
  while pid=$(readlink "$HOME_DIR/state/.agentmail-poll.lock" 2>/dev/null) && kill -0 "$pid" 2>/dev/null; do
    [ "$i" -lt 1200 ] || fail "background poll job did not finish"
    sleep 0.05
    i=$((i + 1))
  done
}

run_send() {
  env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE FM_HOME="$HOME_DIR" \
    FM_AGENTMAIL_API_URL="$API" FM_GH_API_URL="$API" PATH="$FAKEBIN:$PATH" "$SEND" "$@" 2>&1
}

run_daily() {
  env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE FM_HOME="$HOME_DIR" \
    FM_AGENTMAIL_API_URL="$API" FM_GH_API_URL="$API" PATH="$FAKEBIN:$PATH" \
    FM_AGENTMAIL_DAILY_DATE="$DAILY_DAY" "$ROOT/bin/fm-agentmail-daily.sh" "$@" 2>&1
}

note_files() {
  find "$HOME_DIR/state/inbox" -maxdepth 1 -name '*.note' 2>/dev/null | sort
}

note_with() {  # <fixed text>: the one note containing it
  local f
  for f in $(note_files); do
    if grep -qF -- "$1" "$f"; then printf '%s\n' "$f"; fi
  done
}

test_trust_matrix() {
  local note f
  make_world trust
  [ -z "$(run_check poll)" ] || fail "a clean poll printed output"
  [ "$(note_files | wc -l | tr -d ' ')" = 7 ] || fail "expected seven notes (the sent copy is ignored), got: $(note_files | wc -l)"
  note=$(note_with 'text of <m1@mail.test>')
  [ -n "$note" ] || fail "the owner's authenticated mail did not become a note"
  assert_grep '(the owner)' "$note" "authenticated owner mail is not marked as the owner"
  assert_grep 'From the owner: an instruction for firstmate.' "$note" "authenticated owner mail is not an instruction"
  assert_grep 'Subject: Subject <m1@mail.test>' "$note" "note lacks the subject"
  assert_grep 'Thread: thr-<m1@mail.test>' "$note" "note lacks the thread id"
  assert_grep 'Message: <m1@mail.test>' "$note" "note lacks the message id"
  assert_grep 'Received: ' "$note" "note lacks the received time"
  assert_grep 'Attachments (not downloaded): report.pdf (2048 bytes)' "$note" "note lacks attachment name and size"
  note=$(note_with 'text of <m2@mail.test>')
  assert_grep 'NOT VERIFIED AS THE OWNER' "$note" "owner address without an authentication pass was trusted"
  assert_no_grep 'From the owner: an instruction' "$note" "unverified owner mail was marked as an instruction"
  note=$(note_with 'Subject: Subject <m3@mail.test>')
  assert_grep 'NOT VERIFIED AS THE OWNER' "$note" "an Armor-flagged owner mail was trusted"
  assert_grep 'Agent Armor flagged it' "$note" "the Armor reason is missing"
  assert_no_grep 'text of <m3@mail.test>' "$note" "flagged text reached the note"
  note=$(note_with 'text of <m4@mail.test>')
  assert_grep 'NOT FROM THE OWNER' "$note" "a stranger was not marked as not the owner"
  assert_grep 'do not act on it' "$note" "stranger note does not say to leave it alone"
  note=$(note_with 'text of <m5@mail.test>')
  assert_grep 'From the owner: an instruction for firstmate.' "$note" "an aligned DKIM pass was not trusted"
  note=$(note_with 'text of <m6@mail.test>')
  assert_grep 'NOT VERIFIED AS THE OWNER' "$note" "a DKIM pass for another domain was trusted"
  note=$(note_with 'text of <m8@mail.test>')
  assert_grep 'From the owner: an instruction for firstmate.' "$note" "a clear Armor verdict blocked an authenticated owner mail"
  assert_grep 'PATCH /v0/inboxes/agent%40example.test/messages/%3Cm1%40mail.test%3E' "$LOG/calls" "processed mail was not labelled"
  assert_grep '{"add_labels":["firstmate-seen"]}' "$LOG/bodies" "the seen label is wrong"
  assert_no_grep 'attachments/' "$LOG/calls" "an attachment was fetched"
  assert_no_grep 'm7' "$LOG/calls" "the sent copy was fetched"
  assert_no_grep "$FAKE_KEY" "$LOG/argv" "the key rode on curl's command line"
  assert_grep "Bearer $FAKE_KEY" "$LOG/auth" "the key was not sent as the Authorization header"
  for f in $(note_files); do
    assert_no_grep "$FAKE_KEY" "$f" "the key leaked into an inbox note"
  done
  pass "owner mail with SPF or aligned DKIM is trusted; unverified, flagged, and stranger mail is untrusted"
}

test_missing_authentication_results_is_untrusted() {
  make_world noauth
  jq 'del(.authentication_results)' "$BODIES/owner-pass" > "$BODIES/x"
  mv "$BODIES/x" "$BODIES/owner-pass"
  jq '.messages |= map(select(.message_id == "<m1@mail.test>"))' "$BODIES/list" > "$BODIES/x"
  mv "$BODIES/x" "$BODIES/list"
  run_check poll >/dev/null || fail "poll failed"
  assert_grep 'NOT VERIFIED AS THE OWNER' "$(note_with 'text of <m1@mail.test>')" "mail without authentication results was trusted"
  pass "a message with no authentication results is never trusted"
}

test_replay_and_dedup() {
  local count
  make_world replay
  run_check poll >/dev/null || fail "first poll failed"
  count=$(note_files | wc -l | tr -d ' ')
  # The fake never records the seen label, so the same list replays; request
  # ids must keep it from creating a second note per message.
  run_check poll >/dev/null || fail "replayed poll failed"
  [ "$(note_files | wc -l | tr -d ' ')" = "$count" ] || fail "a replayed poll created duplicate notes"
  # A message already labelled firstmate-seen is skipped without being fetched.
  jq '.labels += ["firstmate-seen"]' "$BODIES/owner-pass" > "$BODIES/x"
  jq -s '{count: length, messages: .}' "$BODIES/x" > "$BODIES/list"
  : > "$LOG/calls"
  run_check poll >/dev/null || fail "seen-label poll failed"
  assert_no_grep 'm1%40mail.test' "$LOG/calls" "a seen message was fetched again"
  pass "replays and seen-labelled messages never produce a second note"
}

test_pending_armor_defers_and_retries() {
  make_world pending
  jq '.agent_armor = {status: "pending", started_at: "2026-01-01T00:00:00Z", deadline_at: (now + 600 | floor | todateiso8601)}' "$BODIES/owner-pass" > "$BODIES/x"
  mv "$BODIES/x" "$BODIES/owner-pass"
  jq '.timestamp = (now - 1800 | floor | todateiso8601)' "$BODIES/owner-pass" > "$BODIES/x"
  mv "$BODIES/x" "$BODIES/owner-pass"
  jq '.timestamp = (now - 600 | floor | todateiso8601)' "$BODIES/stranger" > "$BODIES/x"
  mv "$BODIES/x" "$BODIES/stranger"
  list_of owner-pass stranger
  run_check poll >/dev/null || fail "deferring poll failed"
  [ -z "$(note_files)" ] || fail "a message still being scanned was noted, or a later one jumped it"
  jq '.agent_armor = {status: "complete", verdict: "clear", reason: "ok"}' "$BODIES/owner-pass" > "$BODIES/x"
  mv "$BODIES/x" "$BODIES/owner-pass"
  run_check poll >/dev/null || fail "retry poll failed"
  assert_grep 'From the owner: an instruction' "$(note_with 'text of <m1@mail.test>')" "the cleared message was not trusted on retry"
  [ -n "$(note_with 'text of <m4@mail.test>')" ] || fail "the later message was lost"
  pass "a message whose Armor scan is pending is deferred and noted once cleared"
}

test_delivery_ignores_sending_time() {
  local labels
  for labels in '["received"]' '["sent"]' '["draft"]' '["received","firstmate-seen"]'; do
    make_world "future-$RANDOM"
    msg future '<future@mail.test>' owner@example.test "$(jq -nc --argjson labels "$labels" '{labels: $labels, timestamp: (now + 3600 | floor | todateiso8601)}')"
    list_of future
    run_check poll >/dev/null || fail "future timestamp poll failed"
    msg delayed '<delayed@mail.test>' owner@example.test '{"timestamp":"2000-01-01T11:45:00Z"}'
    list_of delayed
    run_check poll >/dev/null || fail "delayed delivery poll failed"
    [ -n "$(note_with 'text of <delayed@mail.test>')" ] || fail "delayed mail was lost after future timestamp"
  done
  make_world delayed-pages
  printf 'fm-agentmail-check-v1\npolled_at=2099-01-01T12:00:00Z\n' > "$HOME_DIR/state/.agentmail-check"
  msg delayed '<delayed@mail.test>' owner@example.test '{"timestamp":"2000-01-01T11:45:00Z","created_at":"2000-01-02T08:30:00Z"}'
  list_of delayed
  cp "$BODIES/list" "$BODIES/last-page"
  printf '{"messages":[],"next_page_token":"page2"}' > "$BODIES/first-page"
  : > "$ROUTES"
  route GET "$INBOX_PATH/messages?*page_token=page2" 200 last-page
  route GET "$INBOX_PATH/messages?limit=50&*" 200 first-page
  route GET "$INBOX_PATH/messages/$(enc_id '<delayed@mail.test>')" 200 delayed
  route PATCH "$INBOX_PATH/messages/$(enc_id '<delayed@mail.test>')" 200 empty
  run_check poll >/dev/null || fail "poll with an old saved cursor failed"
  [ -n "$(note_with 'text of <delayed@mail.test>')" ] || fail "delayed mail on a later page was lost"
  assert_grep 'Received: 2000-01-02T08:30:00Z' "$(note_with 'text of <delayed@mail.test>')" "note showed the sending time as the receipt time"
  python3 - "$LOG/calls" <<'PYQUERY' || fail "discovery violated the AgentMail timestamp and pagination contract"
import pathlib, sys, urllib.parse
queries = []
for line in pathlib.Path(sys.argv[1]).read_text().splitlines():
    url = urllib.parse.urlparse(line.split()[1])
    if url.path.endswith('/messages'):
        query = urllib.parse.parse_qs(url.query)
        assert 'after' not in query and 'before' not in query, 'sending-time filter can exclude delayed delivery'
        queries.append(query)
assert len(queries) == 2, 'poll did not consume both pages'
assert queries[1]['page_token'] == ['page2'], 'poll lost the pagination token'
PYQUERY
  run_check poll >/dev/null || fail "delayed mail replay failed"
  [ "$(note_files | wc -l | tr -d ' ')" = 1 ] || fail "delayed mail replay created duplicate notes"
  make_world delayed-initial
  msg delayed '<initial@mail.test>' owner@example.test '{"timestamp":"2000-01-01T11:45:00Z"}'
  list_of delayed
  run_check poll >/dev/null || fail "initial delayed delivery poll failed"
  [ -n "$(note_with 'text of <initial@mail.test>')" ] || fail "first poll lost old-sent newly delivered mail"
  pass "delayed delivery survives future messages, legacy cursors, pagination, initial polls, and replays"
}

test_armor_withholding_ignores_sender_classification() {
  local sender labels armor note n=0
  make_world armor-matrix
  for sender in owner@example.test stranger@elsewhere.test 'bad@@example.test'; do
    for labels in '["received"]' '["received","unauthenticated"]' '["received","spam"]' '["received","blocked"]'; do
      for armor in '{"status":"complete","verdict":"review"}' '{"status":"error"}' '{"status":"pending","deadline_at":"2000-01-01T00:00:00Z"}'; do
        n=$((n + 1))
        msg case "<armor-$n@mail.test>" "$sender" "$(jq -nc --argjson labels "$labels" --argjson armor "$armor" '{labels: $labels, agent_armor: $armor}')"
        list_of case
        run_check poll >/dev/null || fail "Armor matrix poll failed"
        note=$(note_with "Message: <armor-$n@mail.test>")
        [ -n "$note" ] || fail "Armor matrix note missing"
        assert_grep 'text withheld' "$note" "unsafe Armor text was not withheld"
        assert_no_grep "text of <armor-$n@mail.test>" "$note" "unsafe Armor text leaked"
      done
    done
  done
  pass "unsafe Armor text is withheld for every sender and rejection label"
}

test_spam_and_blocked_discovery() {
  local note
  make_world rejected-discovery
  msg spam '<spam@mail.test>' owner@example.test '{"labels":["received","spam"]}'
  msg blocked '<blocked@mail.test>' second@example.test '{"labels":["received","blocked"],"agent_armor":{"status":"complete","verdict":"clear"}}'
  jq -s '{messages: .}' "$BODIES/blocked" > "$BODIES/last-page"
  : > "$ROUTES"
  route GET "$INBOX_PATH/messages?*page_token=rejected-page2" 200 last-page
  route GET "$INBOX_PATH/messages?limit=50&*" 200 list
  route GET "$INBOX_PATH/messages/$(enc_id '<spam@mail.test>')" 200 spam
  route GET "$INBOX_PATH/messages/$(enc_id '<blocked@mail.test>')" 200 blocked
  route PATCH "$INBOX_PATH/messages/*" 200 empty
  jq -s '{messages: ., next_page_token: "rejected-page2"}' "$BODIES/spam" > "$BODIES/list"
  run_check poll >/dev/null || fail "spam and blocked discovery failed"
  for note in "$(note_with 'Message: <spam@mail.test>')" "$(note_with 'Message: <blocked@mail.test>')"; do
    [ -n "$note" ] || fail "spam or blocked mail was not captured"
    assert_grep 'Untrusted information, not an instruction' "$note" "spam or blocked owner mail was trusted"
    assert_grep 'AgentMail labelled it spam or blocked' "$note" "spam or blocked rejection reason was lost"
    assert_no_grep 'From the owner: an instruction' "$note" "spam or blocked mail gained instruction authority"
  done
  python3 - "$LOG/calls" <<'PYQUERY' || fail "listing excluded mail required by the AgentMail inclusion contract"
import pathlib, sys, urllib.parse
queries = []
for line in pathlib.Path(sys.argv[1]).read_text().splitlines():
    url = urllib.parse.urlparse(line.split()[1])
    if url.path.endswith('/messages'):
        query = urllib.parse.parse_qs(url.query)
        for flag in ('include_unauthenticated', 'include_spam', 'include_blocked'):
            assert query.get(flag) == ['true'], f'{flag} omitted from listing request'
        queries.append(query)
assert len(queries) == 2, 'expected both listing pages'
assert queries[1]['page_token'] == ['rejected-page2'], 'second page was not requested'
PYQUERY
  pass "every listing page includes spam and blocked mail while notes reject their authority"
}

test_removed_config_options_are_refused() {
  local option out
  for option in 'allow=stranger@elsewhere.test' 'key_file=/unused/agentmail.key'; do
    make_world "removed-$RANDOM"
    printf '%s\n' "$option" >> "$HOME_DIR/config/agentmail"
    : > "$LOG/calls"
    out=$(run_send --to stranger@elsewhere.test --subject Hi --text hello) && fail "removed option was accepted by sender"
    assert_contains "$out" 'unknown key' "removed option refusal was not explained"
    out=$(run_check poll) && fail "removed option was accepted by intake"
    assert_contains "$out" 'unknown key' "intake did not reject removed option"
    [ ! -s "$LOG/calls" ] || fail "invalid config reached the API"
  done
  pass "persistent recipient permissions and alternate credential paths are refused"
}

test_problem_lines() {
  local out
  make_world problems
  chmod 0644 "$HOME_DIR/config/agentmail.key"
  out=$(run_check check)
  [ -z "$out" ] || fail "the check printed before its background poll recorded a problem: $out"
  out=$(run_check check)
  assert_contains "$out" "agentmail: the AgentMail key file is missing, not owner-only" "a shared key file was not reported"
  assert_not_contains "$out" "$FAKE_KEY" "the problem line leaked the key"
  out=$(run_check check)
  [ -z "$out" ] || fail "an unchanged problem was reported twice: $out"
  chmod 0600 "$HOME_DIR/config/agentmail.key"
  : > "$ROUTES"
  route GET "$INBOX_PATH/messages?limit=50&*" 401 empty
  run_check check >/dev/null
  out=$(run_check check)
  assert_contains "$out" "AgentMail refused the key (HTTP 401)" "a refused key was not reported"
  pass "problems are reported once and never include the key"
}

test_send_allowlist() {
  local out rc=0
  make_world send
  : > "$LOG/calls"
  out=$(run_send --to stranger@elsewhere.test --subject Hi --text hello) || rc=$?
  [ "$rc" -ne 0 ] || fail "a recipient outside the allowlist was not refused"
  assert_contains "$out" "not on the allowlist" "the refusal does not say why"
  assert_no_grep 'POST' "$LOG/calls" "a refused send still called AgentMail"
  out=$(run_send --to owner@example.test,stranger@elsewhere.test --subject Hi --text hello) && fail "a comma list was not refused"
  out=$(run_send --to stranger@elsewhere.test --allow-recipient other@elsewhere.test --subject Hi --text hello) && fail "--allow-recipient for another address allowed the send"
  printf '{"message_id":"<sent1@mail.test>","thread_id":"thr-sent1"}' > "$BODIES/sent"
  route POST "$INBOX_PATH/messages/send" 200 sent
  out=$(run_send --to Owner@Example.test --subject 'Daily' --text 'body' --html-file <(printf '<p>body</p>')) || fail "the owner's address was refused: $out"
  assert_contains "$out" 'message_id=<sent1@mail.test>' "the send did not print the message id"
  assert_contains "$out" 'thread_id=thr-sent1' "the send did not print the thread id"
  assert_grep '"to":["owner@example.test"]' "$LOG/bodies" "the owner was not the recipient"
  assert_grep '"html":"<p>body</p>"' "$LOG/bodies" "the html body was dropped"
  out=$(run_send --to stranger@elsewhere.test --allow-recipient stranger@elsewhere.test --subject 'Asked' --text 'b') || fail "an explicitly allowed recipient was refused: $out"
  assert_grep '"to":["stranger@elsewhere.test"]' "$LOG/bodies" "the one-off recipient was not used"
  out=$(run_send --to stranger@elsewhere.test --subject 'Again' --text 'b') && fail "--allow-recipient was remembered for a later send"
  assert_no_grep "$FAKE_KEY" "$LOG/argv" "the key rode on curl's command line"
  assert_not_contains "$out" "$FAKE_KEY" "send output leaked the key"
  pass "sending is limited to the allowlist, one-off exceptions are per send, and the key never appears"
}

test_send_reply() {
  local out
  make_world reply
  printf '{"message_id":"<r1@mail.test>","thread_id":"thr-r1"}' > "$BODIES/reply"
  route POST "$INBOX_PATH/messages/$(enc_id '<m1@mail.test>')/reply" 200 reply
  : > "$LOG/calls"
  out=$(run_send --reply-to-message '<m1@mail.test>' --to owner@example.test --text-file - <<<'reply text') || fail "reply failed: $out"
  assert_contains "$out" 'thread_id=thr-r1' "the reply did not print its thread id"
  assert_grep 'POST /v0/inboxes/agent%40example.test/messages/%3Cm1%40mail.test%3E/reply' "$LOG/calls" "the reply did not use the reply endpoint"
  assert_no_grep 'reply_all' "$LOG/bodies" "a reply asked for reply-all"
  out=$(run_send --reply-to-message '<m1@mail.test>' --to stranger@elsewhere.test --text x) && fail "a reply to a stranger was allowed"
  out=$(run_send --reply-to-message '<m1@mail.test>' --to owner@example.test --subject s --text x) && fail "a reply accepted a subject"
  pass "a reply names its recipients, never replies to all, and obeys the allowlist"
}

test_send_routes_by_repository() {
  local out
  make_world route
  printf '{"message_id":"<s2@mail.test>","thread_id":"thr-s2"}' > "$BODIES/sent"
  route POST "$INBOX_PATH/messages/send" 200 sent
  out=$(run_send --repo personal-org/widget --subject Daily --text b) || fail "personal repository route failed: $out"
  assert_grep '"to":["owner@example.test"]' "$LOG/bodies" "a personal-org repository did not go to its address"
  : > "$LOG/bodies"
  out=$(run_send --repo Work-Org/api --subject Daily --text b) || fail "work repository route failed: $out"
  assert_grep '"to":["second@example.test"]' "$LOG/bodies" "a work-org repository did not go to its address"
  : > "$LOG/calls"
  out=$(run_send --repo other-org/x --subject Daily --text b) && fail "a repository with no route was sent"
  assert_contains "$out" "no recipient route" "the missing route is not explained"
  out=$(run_send --repo not-a-slug --subject Daily --text b) && fail "an invalid repository was accepted"
  assert_no_grep 'POST' "$LOG/calls" "a refused repository still sent"
  # A routed address outside the allowlist is still refused.
  printf '%s\n' 'inbox=agent@example.test' 'owner=owner@example.test' 'route=work-org:stranger@elsewhere.test' > "$HOME_DIR/config/agentmail"
  out=$(run_send --repo work-org/api --subject Daily --text b) && fail "a routed address off the allowlist was sent"
  assert_contains "$out" "not on the allowlist" "the allowlist did not cover a routed address"
  pass "--repo picks the recipient by repository owner from local config and still obeys the allowlist"
}

test_daily_product_email() {
  local out holder uncertain uncertain_status uncertain_body DAILY_DAY=2026-11-19
  make_world daily
  printf '<p>Daily report</p>\n' > "$HOME_DIR/report.html"
  printf 'Daily report\n' > "$HOME_DIR/report.txt"
  printf '{"message_id":"daily-1","thread_id":"daily-thread"}' > "$BODIES/sent"
  route POST "$INBOX_PATH/messages/send" 200 sent
  out=$(run_daily --repo personal-org/product --html-file "$HOME_DIR/report.html" --text-file "$HOME_DIR/report.txt") || fail "daily send failed: $out"
  assert_contains "$out" 'sent: 2026-11-19' "daily send did not report success"
  jq -e '.to == ["owner@example.test"] and .text == "Daily report" and .html == "<p>Daily report</p>" and .subject == "Quarterdeck daily product email"' "$LOG/bodies" >/dev/null || fail "daily payload lost its owner route or body alternative"
  [ "$(cat "$HOME_DIR/state/agentmail-daily/$DAILY_DAY")" = sent ] || fail "successful daily send did not record its date"
  : > "$LOG/calls"
  out=$(run_daily --repo work-org/product --html-file "$HOME_DIR/report.html" --text-file "$HOME_DIR/report.txt") && fail "second daily send was allowed across repositories"
  assert_contains "$out" 'already sent today' "daily refusal did not explain the limit"
  [ ! -s "$LOG/calls" ] || fail "same-day refusal still called the API"
  DAILY_DAY=2026-11-20
  : > "$LOG/bodies"
  out=$(run_daily --repo work-org/product --html-file "$HOME_DIR/report.html" --text-file "$HOME_DIR/report.txt" --subject 'Product update') || fail "next-day daily send failed: $out"
  jq -e '.to == ["second@example.test"] and .subject == "Product update"' "$LOG/bodies" >/dev/null || fail "next day lost routing or custom subject"
  DAILY_DAY=2026-11-21
  printf '{"name":"ValidationError","message":"invalid recipient"}' > "$BODIES/rejected"
  : > "$ROUTES"
  route POST "$INBOX_PATH/messages/send" 422 rejected
  out=$(run_daily --repo personal-org/product --html-file "$HOME_DIR/report.html" --text-file "$HOME_DIR/report.txt") && fail "rejected daily send reported success"
  [ ! -e "$HOME_DIR/state/agentmail-daily/$DAILY_DAY" ] || fail "a definitive API rejection kept the day reserved"
  : > "$ROUTES"
  route POST "$INBOX_PATH/messages/send" 200 sent
  out=$(run_daily --repo personal-org/product --html-file "$HOME_DIR/report.html" --text-file "$HOME_DIR/report.txt") || fail "retry after a definitive rejection was refused: $out"
  printf '{"thread_id":"t"}' > "$BODIES/no-id"
  for uncertain in '2026-11-22 500 empty' '2026-11-23 000 empty' '2026-11-24 200 no-id' '2026-11-25 404 empty'; do
    read -r DAILY_DAY uncertain_status uncertain_body <<< "$uncertain"
    : > "$ROUTES"
    route POST "$INBOX_PATH/messages/send" "$uncertain_status" "$uncertain_body"
    out=$(run_daily --repo personal-org/product --html-file "$HOME_DIR/report.html" --text-file "$HOME_DIR/report.txt") && fail "uncertain send (HTTP $uncertain_status) reported success"
    assert_contains "$out" 'outcome uncertain' "uncertain send (HTTP $uncertain_status) was not reported as uncertain"
    [ "$(cat "$HOME_DIR/state/agentmail-daily/$DAILY_DAY")" = pending ] || fail "uncertain send (HTTP $uncertain_status) released the day"
    : > "$ROUTES"
    route POST "$INBOX_PATH/messages/send" 200 sent
    : > "$LOG/calls"
    out=$(run_daily --repo personal-org/product --html-file "$HOME_DIR/report.html" --text-file "$HOME_DIR/report.txt") && fail "retry after an uncertain send (HTTP $uncertain_status) sent a second email"
    assert_contains "$out" 'already sent today' "retry after an uncertain send (HTTP $uncertain_status) did not explain the limit"
    [ ! -s "$LOG/calls" ] || fail "retry after an uncertain send (HTTP $uncertain_status) called the API"
  done
  DAILY_DAY=2026-11-26
  printf 'pending\n' > "$HOME_DIR/state/agentmail-daily/$DAILY_DAY"
  out=$(run_daily --repo personal-org/product --html-file "$HOME_DIR/report.html" --text-file "$HOME_DIR/report.txt") && fail "an interrupted send's reservation was ignored"
  assert_contains "$out" 'already sent today' "an interrupted send's reservation did not consume the day"
  DAILY_DAY=2026-11-27
  : > "$LOG/calls"
  out=$(run_daily --repo personal-org/product --to stranger@elsewhere.test --html-file "$HOME_DIR/report.html" --text-file "$HOME_DIR/report.txt") && fail "daily sender accepted an arbitrary recipient"
  out=$(run_daily --repo personal-org/product --allow-recipient stranger@elsewhere.test --html-file "$HOME_DIR/report.html" --text-file "$HOME_DIR/report.txt") && fail "daily sender accepted a recipient exception"
  printf 'route=outside:stranger@elsewhere.test\n' >> "$HOME_DIR/config/agentmail"
  out=$(run_daily --repo outside/product --html-file "$HOME_DIR/report.html" --text-file "$HOME_DIR/report.txt") && fail "daily sender bypassed the owner allowlist"
  [ ! -s "$LOG/calls" ] || fail "refused daily send reached the API"
  DAILY_DAY=2026-11-28
  for holder in 1 2 3 4 5 6; do
    run_daily --repo personal-org/product --html-file "$HOME_DIR/report.html" --text-file "$HOME_DIR/report.txt" > "$HOME_DIR/race-$holder.out" &
  done
  wait
  [ "$(grep -c '^POST ' "$LOG/calls")" = 1 ] || fail "concurrent daily sends sent more than one email: $(cat "$LOG/calls")"
  [ "$(cat "$HOME_DIR"/race-*.out | grep -c 'already sent today')" = 5 ] || fail "concurrent daily sends were not refused for the reserved day"
  assert_grep '2026-11-19 sent' "$HOME_DIR/state/agentmail-daily.log" "successful send was not logged"
  assert_grep '2026-11-19 refused already sent today' "$HOME_DIR/state/agentmail-daily.log" "same-day refusal was not logged"
  assert_grep '2026-11-21 refused send failed' "$HOME_DIR/state/agentmail-daily.log" "rejected send was not logged"
  assert_grep '2026-11-22 refused send outcome uncertain; day consumed' "$HOME_DIR/state/agentmail-daily.log" "uncertain send was not logged"
  assert_no_grep "$FAKE_KEY" "$HOME_DIR/state/agentmail-daily.log" "daily log leaked the key"
  assert_no_grep "$FAKE_KEY" "$LOG/argv" "daily send put the key in argv"
  assert_not_contains "$out" "$FAKE_KEY" "daily output leaked the key"
  pass "daily product email uses owner routes and both bodies, reserves each date before sending, frees it only after a definitive rejection, and lets one of several concurrent calls send"
}

test_arm_and_disarm() {
  local out
  make_world arm
  out=$(run_check arm)
  assert_contains "$out" "armed: state/agentmail.check.sh" "arm did not report"
  [ -x "$HOME_DIR/state/agentmail.check.sh" ] || fail "arm did not write the check shim"
  [ -f "$HOME_DIR/state/agentmail.check-trust" ] || fail "arm did not bind the check"
  out=$(run_check disarm)
  assert_contains "$out" "disarmed" "disarm did not report"
  assert_absent "$HOME_DIR/state/agentmail.check.sh" "disarm left the shim"
  rm -f "$HOME_DIR/config/agentmail"
  out=$(run_check arm)
  assert_contains "$out" "configure the inbox first" "arm without config was not refused"
  pass "arm registers the watcher check and disarm removes it"
}

test_check_runs_poll_in_background() {
  make_world background
  [ -z "$(run_check check)" ] || fail "a clean check printed output"
  [ -n "$(note_with 'text of <m1@mail.test>')" ] || fail "the background poll did not save the owner mail"
  pass "check starts one detached poll job that saves the notes"
}

test_trust_matrix
test_missing_authentication_results_is_untrusted
test_replay_and_dedup
test_pending_armor_defers_and_retries
test_delivery_ignores_sending_time
test_armor_withholding_ignores_sender_classification
test_spam_and_blocked_discovery
test_removed_config_options_are_refused
test_problem_lines
test_send_allowlist
test_send_reply
test_send_routes_by_repository
test_daily_product_email
test_arm_and_disarm
test_check_runs_poll_in_background
