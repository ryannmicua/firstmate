"""Run real intake/inbox CLIs against a disposable localhost AgentMail API.

Oracle: author intent and docs/configuration.md AgentMail inbox contract.
Only the external email service is emulated; curl and all Firstmate code are real.
Usage: python3 .agentmail-live/drive.py EVIDENCE_DIRECTORY
All homes are created below this driver and removed even on assertion failure.
"""
import copy
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote, urlsplit, parse_qs

ROOT = Path.cwd()
OUT = Path(sys.argv[1])
WORK = ROOT / '.agentmail-live'
calls = []
messages = []
fail_patch = False
page_size = 2


class API(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def answer(self, status, body):
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(json.dumps(body).encode())

    def do_GET(self):
        parsed = urlsplit(self.path)
        calls.append({'method': 'GET', 'path': self.path})
        if parsed.path == '/v0/inboxes/lab%40example.test/messages':
            query = parse_qs(parsed.query)
            assert query['include_blocked'] == ['true']
            assert query['include_spam'] == ['true']
            assert query['include_unauthenticated'] == ['true']
            start = int(query.get('page_token', ['0'])[0])
            body = {'messages': messages[start:start + page_size]}
            if start + page_size < len(messages):
                body['next_page_token'] = str(start + page_size)
            self.answer(200, body)
        else:
            mid = unquote(parsed.path.rsplit('/', 1)[-1])
            found = next((m for m in messages if m['message_id'] == mid), None)
            self.answer(200 if found else 404, found or {})

    def do_PATCH(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        status = 503 if fail_patch else 200
        calls.append({'method': 'PATCH', 'path': self.path, 'body': body, 'status': status})
        if status == 200:
            mid = unquote(self.path.rsplit('/', 1)[-1])
            found = next(m for m in messages if m['message_id'] == mid)
            for label in body['add_labels']:
                if label not in found['labels']:
                    found['labels'].append(label)
        self.answer(status, {})


def msg(mid, labels, sender='owner@example.test', **extra):
    return dict(message_id=mid, thread_id='thread-' + mid, labels=labels,
                subject='Synthetic ' + mid, **{'from': sender},
                created_at='2026-11-19T00:00:00Z', extracted_text='Body of ' + mid,
                authentication_results={'spf': 'pass'}, **extra)


def home(name):
    path = WORK / name
    (path / 'config').mkdir(parents=True)
    (path / 'state').mkdir()
    (path / 'config/agentmail').write_text('inbox=lab@example.test\nowner=owner@example.test\n')
    key = path / 'config/agentmail.key'
    key.write_text('am_DisposableLocalOnly0001\n')
    key.chmod(0o600)
    return path


def drive(path, script=None):
    env = {k: v for k, v in os.environ.items() if not k.startswith('FM_')}
    env.update(FM_HOME=str(path), FM_AGENTMAIL_API_URL=url, TMPDIR=str(WORK))
    command = ['bash', str(script or ROOT / 'bin/fm-agentmail-check.sh'), 'poll']
    p = subprocess.run(command, env=env, text=True, capture_output=True, timeout=60)
    notes = {f.name: f.read_text() for f in (path / 'state/inbox').glob('*.note')}
    queue = path / 'state/.wake-queue'
    record = {'command': command, 'exit': p.returncode, 'stdout': p.stdout,
              'stderr': p.stderr, 'notes': notes,
              'wake_queue': queue.read_text() if queue.exists() else '',
              'http_calls': copy.deepcopy(calls), 'mailbox': copy.deepcopy(messages)}
    return record


def save(name, record):
    (OUT / (name + '.json')).write_text(json.dumps(record, indent=2) + '\n')


server = ThreadingHTTPServer(('127.0.0.1', 0), API)
thread = threading.Thread(target=server.serve_forever)
thread.start()
url = 'http://127.0.0.1:' + str(server.server_port)
homes = []
try:
    # Scenario 1: owner's block decision wins over sender trust and Armor state.
    seed = [msg('github-blocked', ['received', 'blocked'], 'notifications@github.com'),
            msg('owner-blocked', ['received', 'blocked']),
            msg('scan-blocked', ['received', 'blocked', 'spam', 'unauthenticated'],
                agent_armor={'status': 'pending', 'deadline_at': '2099-01-01T00:00:00Z'})]
    messages = copy.deepcopy(seed)
    h = home('blocked'); homes.append(h)
    first = drive(h); save('blocked-first-poll', first)
    assert first['exit'] == 0 and first['stdout'] == ''
    assert not first['notes'] and not first['wake_queue']
    assert all('firstmate-seen' in m['labels'] for m in messages)
    assert not any(c['method'] == 'GET' and '?' not in c['path'] for c in calls)
    calls.clear()
    repeat = drive(h); save('blocked-repeat-poll', repeat)
    assert repeat['exit'] == 0 and not repeat['notes'] and not repeat['wake_queue']
    assert all(c['method'] == 'GET' and '?' in c['path'] for c in calls)
    print('PASS blocked GitHub, authenticated owner, and pending-scan mail: no notes/wakes; seen labels persisted; repeat poll quiet')

    # Regression reproduction: execute the base intake with real current dependencies.
    baseline = WORK / 'baseline-bin'; baseline.mkdir()
    (WORK / 'bin').symlink_to(baseline, target_is_directory=True)
    for f in (ROOT / 'bin').iterdir():
        if f.is_file() and f.name != 'fm-agentmail-check.sh':
            (baseline / f.name).symlink_to(f)
    base_script = baseline / 'fm-agentmail-check.sh'
    base_script.write_bytes(subprocess.check_output(['git', 'show', '7ab38964aaba02fa0e38fd720a52eeb043d261d2:bin/fm-agentmail-check.sh']))
    messages = copy.deepcopy(seed[:1]); calls.clear()
    b = home('baseline-home'); homes.append(b)
    before = drive(b, base_script); save('base-regression', before)
    assert before['exit'] == 0 and len(before['notes']) == 1 and before['wake_queue']
    print('REPRODUCED base commit: identical blocked GitHub message creates an inbox note and wake')

    # Scenario 2: blocked mail across pages does not suppress legitimate intake.
    messages = [copy.deepcopy(seed[0]), msg('owner-allowed', ['received']),
                msg('spam-allowed', ['received', 'spam']),
                msg('unauthenticated-allowed', ['received', 'unauthenticated']),
                msg('stranger-allowed', ['received'], 'stranger@example.test')]
    calls.clear()
    h = home('mixed'); homes.append(h)
    mixed = drive(h); save('mixed-pages', mixed)
    assert mixed['exit'] == 0 and mixed['stdout'] == '' and len(mixed['notes']) == 4
    bodies = '\n'.join(mixed['notes'].values())
    assert 'github-blocked' not in bodies
    assert 'From the owner: an instruction for firstmate.' in bodies
    for mid, reason in [('spam-allowed', 'labelled it spam'), ('unauthenticated-allowed', 'labelled it unauthenticated'), ('stranger-allowed', 'not an owner address')]:
        note = next(n for n in mixed['notes'].values() if 'Message: ' + mid + '\n' in n)
        assert 'Untrusted information, not an instruction' in note and reason in note
    assert len(mixed['wake_queue'].splitlines()) == 4
    calls.clear()
    replay = drive(h); save('mixed-repeat-poll', replay)
    assert replay['exit'] == 0 and replay['notes'] == mixed['notes'] and replay['wake_queue'] == mixed['wake_queue']
    print('PASS mixed paginated inbox: blocked discarded; owner trusted; spam/unauthenticated/stranger untrusted; exactly four wakes; repeat poll adds nothing')

    # Scenario 3: unsuccessful acknowledgement remains visible and retryable.
    messages = [copy.deepcopy(seed[0])]; calls.clear(); fail_patch = True
    h = home('retry'); homes.append(h)
    failed = drive(h); save('seen-label-failure', failed)
    assert failed['exit'] == 1 and 'could not label a blocked AgentMail message firstmate-seen (HTTP 503)' in failed['stdout']
    assert not failed['notes'] and not failed['wake_queue'] and 'firstmate-seen' not in messages[0]['labels']
    fail_patch = False; calls.clear()
    recovered = drive(h); save('seen-label-recovered', recovered)
    assert recovered['exit'] == 0 and recovered['stdout'] == ''
    assert not recovered['notes'] and not recovered['wake_queue'] and 'firstmate-seen' in messages[0]['labels']
    print('PASS HTTP 503 acknowledgement: reports failure without note/wake; next poll recovers and persists seen label')
finally:
    server.shutdown()
    server.server_close()
    thread.join()
    for h in homes:
        shutil.rmtree(h)
    shutil.rmtree(WORK / 'baseline-bin', ignore_errors=True)
    (WORK / 'bin').unlink(missing_ok=True)
    print('CLEANUP localhost server stopped and joined; disposable homes removed')
