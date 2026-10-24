"""Disposable live CLI validation; uses real product commands, no tool shims."""
import hashlib, json, os, pathlib, shutil, subprocess, tempfile, time
root = pathlib.Path.cwd()
evidence = pathlib.Path('/home/rgm/.no-mistakes/evidence/01M5PAAQRNW77M8AQJJP4MDZYA')
lab = pathlib.Path(tempfile.mkdtemp(prefix='attention-live-', dir=root / '.validation-tmp'))
log = []
env = os.environ.copy()
for key in list(env):
    if key.startswith(('FM_', 'TASKS_AXI_', 'BD_', 'BEADS_')) or key in ('TMUX', 'NO_MISTAKES_GATE'):
        env.pop(key)
env['TMPDIR'] = str(root / '.validation-tmp')
def home(name, ledger=True):
    p = lab / name
    for d in ('data','state','config','projects'): (p/d).mkdir(parents=True, exist_ok=True)
    (p/'.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/archive.md"\ndone_keep = 10\n')
    (p/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
    if ledger: (p/'config/fleet-ledger').touch()
    return p

def run(p, script, *args, ok=True):
    e = env | {'FM_HOME':str(p)}
    proc = subprocess.run(['bash', str(root/'bin'/script), *args], env=e, text=True, capture_output=True, timeout=90)
    log.append({'home':p.name,'command':[script,*args],'exit':proc.returncode,'stdout':proc.stdout,'stderr':proc.stderr})
    if ok and proc.returncode: raise RuntimeError(log[-1])
    return proc

def attention(p, label):
    out = json.loads(run(p, 'fm-attention.sh','--json').stdout)
    (evidence/(label+'.json')).write_text(json.dumps(out, indent=2)+'\n')
    assert out['schema']=='fm-attention.v1'
    assert set(out)=={'schema','generated','open_decisions'}
    return out['open_decisions']

def hold(p, task, reason, *args):
    run(p,'fm-captain-hold.sh','hold',task,'--title',task,'--reason',reason,'--repo','sample',*args)

def inventory(p):
    return {str(f.relative_to(p)):('dir' if f.is_dir() else hashlib.sha256(f.read_bytes()).hexdigest()) for f in p.rglob('*')}
try:
    p=home('lifecycle')
    hold(p,'a','choose A'); time.sleep(1.1)
    hold(p,'b','choose B'); time.sleep(1.1)
    rows=attention(p,'01-held-a-b')
    assert [r['task'] for r in rows]==['b','a']
    ledger=(p/'state/fleet-ledger.jsonl').read_bytes()
    hold(p,'a','choose A')
    assert (p/'state/fleet-ledger.jsonl').read_bytes()==ledger
    assert attention(p,'02-unchanged-retry')==rows
    time.sleep(1.1)
    hold(p,'a','choose revised A','--until','2027-01-01')
    revised=attention(p,'03-changed-deferral')
    assert [r['task'] for r in revised]==['a','b']
    assert revised[0]['bucket']=='dated' and revised[0]['opened_at']==rows[1]['opened_at']
    (p/'answer.txt').write_text('Use option B.\n')
    run(p,'fm-captain-hold.sh','answer','b','--decision-file',str(p/'answer.txt'))
    assert [r['task'] for r in attention(p,'04-answer-removes-call')]==['a']
    run(p,'fm-captain-hold.sh','answer','a','--decision-file',str(p/'answer.txt'),'--release')
    assert attention(p,'05-release-clears-feed')==[]
    shutil.copyfile(p/'state/fleet-ledger.jsonl', evidence/'captain-events.jsonl')
    for flag in (False,True):
        q=home('legacy-'+str(flag),flag)
        (q/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n- [ ] legacy - legacy (repo: sample) (kind: captain) (hold: choose legacy) (hold-kind: captain) (since 2026-01-01)\n- [ ] day - day (repo: sample) (kind: captain) (hold: choose day) (hold-kind: captain) (since 2026-01-02)\n  Captain hold set: 2026-07-03\n\n## Done\n')
        before=attention(q,'06-legacy-before-'+str(flag))
        assert [r['task'] for r in before]==['day','legacy']
        assert before[0]['opened_at']=='2026-07-03T00:00:00Z' and before[0]['opened_precision']=='day'
        hold(q,'legacy','choose legacy')
        assert attention(q,'07-legacy-retry-'+str(flag))==before
        assert not (q/'state/fleet-ledger.jsonl').exists()
    q=home('status-feed')
    (q/'data/secondmates.md').write_text('- remote - Remote mate (host: invalid.example; root: /remote/root; home: /remote/home; scope: fixture; projects: sample; added 2026-09-01)\n')
    (q/'state/remote.meta').write_text('kind=secondmate\nmode=secondmate\nharness=codex\nremote_host=invalid.example\nremote_root=/remote/root\nhome=/remote/home\n')
    status=q/'state/remote.status'
    status.write_text('needs-decision [key=pending-reply-old] [at=1783072800]: pending-reply-missed: choose old\nneeds-decision [key=new] [at=1783076400]: choose new\nblocked [key=pending-reply-old] [at=1783080000]: unrelated rejected note\nblocked [key=pending-reply-old]: unrelated unstamped rejected note\nneeds-decision [at=1783069200]: default decision\n needs-decision\n needs-decision [at=12:30]\nneeds-decision [key=undated]: no timestamp\n')
    with status.open('a') as f:
        for i in range(100): f.write('check: '+('x'*1990)+'\n')
    run(q,'fm-fleet-ledger.sh','capture')
    assert (q/'state/fleet-ledger.jsonl').stat().st_size>131072
    with (q/'state/fleet-ledger.jsonl').open('a') as f: f.write('not JSON\n{"ts":"bad"}\n')
    before=inventory(q)
    rows=attention(q,'08-large-delayed-ledger')
    assert inventory(q)==before, 'read changed persisted files or directories'
    assert [r['key'] for r in rows]==['new','pending-reply-old','default','undated']
    assert [r['opened_at'] for r in rows]==['2026-07-03T11:00:00Z','2026-07-03T10:00:00Z','2026-07-03T09:00:00Z',None]
    assert all(r['opened_at']==r['last_touched_at'] for r in rows)
    assert attention(q,'09-repeat-read')==rows and inventory(q)==before
    after_read=inventory(q)
    with status.open('a') as f: f.write('resolved [key=new]: answered\n')
    assert [r['key'] for r in attention(q,'10-resolved-key')]==['pending-reply-old','default','undated']
    (evidence/'read-only-inventory.json').write_text(json.dumps({'unchanged':True,'before':before,'after':after_read},indent=2)+'\n')
    assert run(q,'fm-attention.sh',ok=False).returncode==2
    assert run(q,'fm-attention.sh','--json','extra',ok=False).returncode==2
    run(q,'fm-attention.sh','--help')
    print('Live CLI scenarios passed: lifecycle, re-hold ordering, changed deferral, legacy ordering, keyed folding, large delayed/torn ledger, read-only registered secondmate, argument guards.')
finally:
    (evidence/'live-cli-transcript.json').write_text(json.dumps(log,indent=2)+'\n')
    shutil.rmtree(lab)
