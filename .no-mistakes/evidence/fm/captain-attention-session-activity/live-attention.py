import os, json, pathlib, subprocess, tempfile, shutil, hashlib, time
root=pathlib.Path.cwd()
evidence=pathlib.Path('/home/rgm/.no-mistakes/evidence/01M5R04SW67KGV782XE3EA2SSE')
home=pathlib.Path(tempfile.mkdtemp(prefix='attention-live-',dir=root/'.test-tmp'))
env={k:v for k,v in os.environ.items() if not k.startswith(('FM_','TASKS_AXI_')) and k not in ('TMUX','REX_SESSION','REX_BLOCK')}
env.update(FM_HOME=str(home),TMPDIR=str(root/'.test-tmp'))
transcript=[]
def cmd(script,*args):
    p=subprocess.run(['bash',str(root/'bin'/script),*args],env=env,text=True,capture_output=True,timeout=60)
    transcript.append({'command':['bash','bin/'+script,*args], 'returncode':p.returncode,'stdout':p.stdout,'stderr':p.stderr})
    assert p.returncode==0,transcript[-1]
    return p.stdout

def read(name):
    data=cmd('fm-attention.sh','--json')
    (evidence/(name+'.json')).write_text(data)
    return json.loads(data)

def write_records(records,mode='a'):
    with (home/'state/fleet-ledger.jsonl').open(mode) as f:
        for r in records:f.write(json.dumps(r)+'\n')

def stamp(file,t):
    p=home/'state'/file
    p.write_text('disposable session boundary\n')
    os.utime(p,(t,t))
def record(t,event,task='login',**kw):return dict(v=1,ts=t,event=event,task=task,**kw)
def inventory():return sorted((str(p.relative_to(home)),hashlib.sha256(p.read_bytes()).hexdigest(),p.stat().st_mtime_ns) for p in home.rglob('*') if p.is_file())
try:
    for d in ['data','state','config','projects']:(home/d).mkdir()
    (home/'.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n')
    (home/'data/backlog.md').write_text('## In flight\n\n- [ ] login - Repair login redirects (repo: webapp) (kind: ship) (since 2026-07-01)\n- [ ] export - Export monthly report (repo: reports) (kind: scout) (since 2026-07-01)\n\n## Queued\n\n## Done\n\n- [x] old - Previous release (repo: webapp) (kind: ship) (since 2026-06-01)\n')
    (home/'config/fleet-ledger').touch()
    stamp('.lock',1782897600)
    stamp('.lock-session',1782897600)
    stamp('.session-start-complete',1782901000)
    records=[record(1782897599,'task.dispatched','old'),record(1782897600,'task.dispatched'),record(1782897700,'task.status',state='working',text='routine noise'),record(1782897800,'task.pr_ready',pr='https://example.test/webapp/pull/7'),record(1782897900,'task.merged','old',via='local'),record(1782897950,'task.cleaned_up','retired')]
    write_records(records,'w')
    cmd('fm-fleet-ledger.sh','dispatched','export','scout','reports','codex','default')
    out=read('01-session-activity')
    assert out['session']==dict(started_at='2026-07-01T09:20:00Z',source='session_identity')
    assert [r['line'] for r in out['session_activity']]==['Started: Export monthly report','Cleaned up: retired','Landed locally: Previous release','PR ready: Repair login redirects','Started: Repair login redirects']
    assert [r['task'] for r in out['in_flight']]==['login','export']
    stamp('.lock',1782900900)
    reanchor=read('02-same-session-reanchor')
    for k in ['session','session_activity','session_activity_total','session_activity_truncated']:assert reanchor[k]==out[k]
    stamp('.lock-session',1782897850)
    changed=read('03-new-session')
    assert all(r['at']>='2026-07-01T09:24:10Z' for r in changed['session_activity'])
    assert not any(r['task']=='login' for r in changed['session_activity'])
    (home/'state/.lock-session').unlink()
    stamp('.lock',1782897600)
    lock=read('04-lock-only-startup')
    assert lock['session']['source']=='session_lock'
    assert any(r['event']=='task.dispatched' and r['task']=='login' for r in lock['session_activity'])
    # Feed the documented ledger protocol adversarial statuses, duplicate records and tied decisions.
    extra=[record(1782898000+i,'task.status',state=s,text=s+' details') for i,s in enumerate(['failed','blocked','resolved','done','paused'])]
    extra += [record(1782898100,'task.status',state='needs-decision',key=k,text='Choose option') for k in ['first','second','second']]
    extra += [record(1782898200,'captain.answered',mode=m) for m in ['done','release','reconciled']]
    write_records(extra)
    with (home/'state/fleet-ledger.jsonl').open('a') as f:f.write('broken json\n{"ts":"foreign"}\n{"ts":1782898300,"event":"future.event","task":"login"}\n')
    distinct=read('05-decisions-and-noise')
    statuses=[r['state'] for r in distinct['session_activity'] if r['event']=='task.status']
    assert set(statuses)=={'failed','blocked','resolved','done','needs-decision'}
    assert [r['key'] for r in distinct['session_activity'] if r['state']=='needs-decision']==['second','first']
    assert [r['mode'] for r in distinct['session_activity'] if r['event']=='captain.answered']==['reconciled','release','done']
    # Real captain hold writes a decision through tasks-axi and the real ledger producer.
    cmd('fm-captain-hold.sh','hold','approval','--title','Approve report format','--reason','Choose CSV or PDF','--repo','reports')
    held=read('06-open-decision-and-in-flight')
    assert any(r['task']=='approval' and r['reason']=='Choose CSV or PDF' for r in held['open_decisions'])
    assert any(r['task']=='approval' and r['line']=='Waiting on you: Approve report format' for r in held['session_activity'])
    # Current metadata has no endpoint: no worker or shared session is contacted.
    (home/'state/login.meta').write_text('kind=ship\nharness=codex\npr=https://example.test/webapp/pull/8\n')
    (home/'state/login.status').write_text('working [at=1782899100]: tracing redirect\n')
    (home/'config/fleet-ledger').unlink()
    current=read('07-current-pr-recording-disabled')
    assert all(r['pr']=='https://example.test/webapp/pull/8' for r in current['session_activity'] if r['task']=='login')
    running=next(r for r in current['in_flight'] if r['task']=='login')
    assert running['pr']=='https://example.test/webapp/pull/8' and running['last_event']=='working [at=1782899100]: tracing redirect' and isinstance(running['worker'],str)
    before=inventory()
    read('08-read-only')
    assert inventory()==before
    write_records([record(1782899000+i,'task.dispatched') for i in range(105)])
    capped=read('09-disclosed-cap')
    assert capped['session_activity_truncated'] is True and len(capped['session_activity'])==100
    assert capped['session_activity_total']==len(current['session_activity'])+105
    assert [r['at'] for r in capped['session_activity']]==sorted([r['at'] for r in capped['session_activity']],reverse=True)
    (home/'state/.lock').unlink()
    fallback=read('10-honest-fallback')
    assert fallback['session']['source']=='fallback_24h'
    assert abs((time.time()-86400)-__import__('datetime').datetime.fromisoformat(fallback['session']['started_at'].replace('Z','+00:00')).timestamp())<60
    assert all(r['task'] in ['export','approval'] for r in fallback['session_activity'])
    (home/'state/fleet-ledger.jsonl').unlink()
    empty=read('11-no-ledger')
    assert empty['session_activity']==[] and empty['session_activity_total']==0 and not empty['session_activity_truncated']
    assert empty['in_flight'] and empty['open_decisions']
    print('Live CLI scenarios passed: session ordering; re-anchor and new identity; startup and fallback; distinct decisions and noise; real held decision; current PR and worker detail; read-only; disclosed cap; missing ledger.')
finally:
    (evidence/'live-cli-transcript.json').write_text(json.dumps(transcript,indent=2)+'\n')
    shutil.rmtree(home)
