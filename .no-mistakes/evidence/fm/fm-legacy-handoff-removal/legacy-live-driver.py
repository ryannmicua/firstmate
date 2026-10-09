import os, pathlib, subprocess, hashlib, shutil, json, time
root=pathlib.Path.cwd(); lab=root/'.l'; evidence=pathlib.Path('/home/rgm/.no-mistakes/evidence/01M4HGNAD303NZ473VHVBMGE8S')
assert not lab.exists()
log=[]; results=[]
env=os.environ.copy()
for k in list(env):
    if (k.startswith('FM_') and k.endswith('_OVERRIDE')) or k in ['FM_GATE_REFUSE_BYPASS','HERDR_ENV','HERDR_PANE_ID','HERDR_SESSION','HERDR_SOCKET_PATH','HERDR_TAB_ID','HERDR_WORKSPACE_ID','TMUX','FM_TASK_ID','TASKS_AXI_FILE','TASKS_AXI_BACKEND']:
        env.pop(k,None)
env.update(FM_HOME=str(lab),TMUX_TMPDIR=str(lab/'tmux'),TMPDIR=str(lab/'tmp'))
def run(args, expected=None, extra=None):
    e=env.copy(); e.update(extra or {})
    p=subprocess.run(args,env=e,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=60)
    log.append('$ '+' '.join(map(str,args))+'\n'+p.stdout+'exit='+str(p.returncode)+'\n')
    if expected is not None: assert p.returncode==expected, log[-1]
    return p.stdout

def digest():
    return {str(p.relative_to(lab)):hashlib.sha256(p.read_bytes()).hexdigest() for parent in ['state','data','copy'] for p in (lab/parent).rglob('*') if p.is_file() and '.git' not in p.parts and (parent != 'state' or p.suffix == '.meta')}
def inventory(): return run(['tmux','-L','fm-lab','list-windows','-a','-F','#{session_name}:#{window_name}:#{pane_current_command}'],0)
def check(name, fn):
    log.append('\nSCENARIO: '+name+'\n')
    try: fn(); results.append({'name':name,'result':'pass','live':True})
    except Exception as e:
        log.append('ASSERTION FAILED: '+str(e)+'\n'); results.append({'name':name,'result':'fail','live':True}); raise
try:
    run(['bin/fm-lab-home.sh','create',str(lab)],0)
    for x in ['tmux','tmp','copy','data/paseo-backend-adapter']: (lab/x).mkdir(parents=True,exist_ok=True)
    run(['git','init','-q',str(lab/'copy')],0)
    (lab/'copy/task.txt').write_text('unfinished task work, preserve me\n')
    run(['git','-C',str(lab/'copy'),'-c','user.name=Lab','-c','user.email=lab@example.invalid','commit','--allow-empty','-qm','lab'],0)
    meta=lab/'state/paseo-backend-adapter.meta'
    meta.write_text(f'window=firstmate:fm-paseo-backend-adapter\nendpoint_task_id=paseo-backend-adapter\nworktree={lab}/copy\nproject={lab}/copy\nharness=codex\nkind=ship\nmode=no-mistakes\nyolo=off\nmodel=default\neffort=default\n')
    (lab/'data/paseo-backend-adapter/brief.md').write_text('# Task\nPreserve unfinished task work.\n')
    run(['tmux','-L','fm-lab','new-session','-d','-s','firstmate','-n','sentinel','-x','120','-y','35','-c',str(lab/'copy'),'bash --noprofile --norc'],0)
    socket=run(['tmux','-L','fm-lab','display-message','-p','-t','firstmate:sentinel','#{socket_path},#{pid},0'],0).strip(); env['TMUX']=socket
    def rejected_handoff():
        before=digest(); inv=inventory()
        out=run(['bin/fm-control.sh','paseo-backend-adapter','handoff','--expect-endpoint','firstmate:fm-paseo-backend-adapter','--expect-worktree',str(lab/'copy'),'--expect-head',subprocess.check_output(['git','-C',str(lab/'copy'),'rev-parse','HEAD'],text=True).strip(),'--note','legacy retry'],2)
        assert "'handoff' is not a control verb" in out
        assert before==digest() and inv==inventory()
        log.append('Task records, brief, unfinished work, and real tmux inventory unchanged.\n')
    check('Legacy task handoff is rejected without altering work or creating an endpoint',rejected_handoff)
    def rejected_flags():
        before=digest(); inv=inventory()
        for flag in ['--expect-endpoint','--expect-worktree','--expect-head']:
            out=run(['bin/fm-control.sh','paseo-backend-adapter','relaunch',flag,'legacy','--note','legacy retry'],1)
            assert 'unknown option' in out or 'unknown argument' in out or 'unexpected argument' in out, out
        assert before==digest() and inv==inventory()
        log.append('Removed handoff flags cannot enter an ordinary relaunch.\n')
    check('Old attestation flags cannot enable handoff through relaunch',rejected_flags)
    def missing_refusals():
        before=digest(); inv=inventory()
        for args in [['bin/fm-control.sh','paseo-backend-adapter','exit'],['bin/fm-control.sh','paseo-backend-adapter','relaunch','--note','do not duplicate'],['bin/fm-spawn.sh','paseo-backend-adapter','--relaunch','--harness','codex']]:
            out=run(args,1); assert 'missing' in out or 'absence' in out or 'cannot prove' in out, out
        assert before==digest() and inv==inventory()
        log.append('Both control verbs and direct spawn preserve task state and refuse the absent window.\n')
    check('Missing historical tmux endpoint refuses exit and replacement without changing work',missing_refusals)
    def forged_transaction():
        before=digest(); inv=inventory()
        for value in ['forged-legacy-transaction','']:
            out=run(['bin/fm-spawn.sh','paseo-backend-adapter','--relaunch','--harness','codex'],1,{'FM_CONTROL_HANDOFF_TX':value})
            assert 'missing' in out or 'absence' in out or 'cannot prove' in out, out
        assert before==digest() and inv==inventory()
        log.append('Nonempty and empty legacy transaction variables cannot bypass normal absence proof.\n')
    check('Legacy transaction environment cannot bypass direct-spawn safety',forged_transaction)
    def ordinary_exit():
        meta.write_text(meta.read_text().replace('firstmate:fm-paseo-backend-adapter','firstmate:sentinel'))
        # Use a separate task whose endpoint label belongs to it, as required by public identity validation.
        text=meta.read_text().replace('paseo-backend-adapter','sentinel').replace('firstmate:sentinel','firstmate:fm-sentinel')
        (lab/'state/sentinel.meta').write_text(text)
        run(['tmux','-L','fm-lab','rename-window','-t','firstmate:sentinel','fm-sentinel'],0)
        before=digest(); inv=inventory()
        out=run(['bin/fm-control.sh','sentinel','exit'],0); assert 'already-stopped' in out
        assert before==digest() and inv==inventory()
        log.append('Ordinary exit recognizes a real stopped shell and preserves its endpoint and unfinished work.\n')
    check('Ordinary exit still recognizes an already-stopped agent and preserves its endpoint',ordinary_exit)
finally:
    subprocess.run(['tmux','-L','fm-lab','kill-server'],env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
    if lab.exists(): shutil.rmtree(lab)
    log.append('Teardown: private fm-lab tmux server stopped; disposable lab home removed.\n')
    (evidence/'legacy-control-live.log').write_text(''.join(log))
    (evidence/'legacy-control-results.json').write_text(json.dumps(results,indent=2)+'\n')
print(json.dumps(results,indent=2))
