"""Try the real configured Beads adapter in a disposable local database."""
import json, os, pathlib, shutil, subprocess, tempfile, hashlib
root=pathlib.Path.cwd(); ev=pathlib.Path('/home/rgm/.no-mistakes/evidence/01M5PAAQRNW77M8AQJJP4MDZYA')
lab=pathlib.Path(tempfile.mkdtemp(prefix='attention-beads-',dir=root/'.validation-tmp'))
e=os.environ.copy()
for k in list(e):
    if k.startswith(('FM_','BEADS_','BD_','TASKS_AXI_')): e.pop(k)
e.update({'HOME':str(lab/'user'),'XDG_CONFIG_HOME':str(lab/'user/config'),'XDG_CACHE_HOME':str(lab/'user/cache'),'PATH':str(root/'.validation-tmp/beads-bin')+':'+e['PATH'],'TMPDIR':str(root/'.validation-tmp'),'BD_NON_INTERACTIVE':'1','GIT_CONFIG_GLOBAL':'/dev/null','GIT_CONFIG_SYSTEM':'/dev/null'})
log=[]
def run(args,ok=True):
    p=subprocess.run(args,cwd=lab,env=e,capture_output=True,text=True,timeout=90)
    log.append({'command':args,'exit':p.returncode,'stdout':p.stdout,'stderr':p.stderr})
    if ok and p.returncode: raise RuntimeError(log[-1])
    return p
try:
    for d in ('data','state','config','projects','user'): (lab/d).mkdir()
    run(['git','init','-q'])
    run(['bd','init','--prefix','att','--skip-agents','--skip-hooks','--non-interactive'])
    (lab/'.tasks.toml').write_text('backend = "beads"\n[beads]\npath = '+json.dumps(str(lab/'.beads'))+'\nbinary = "bd"\nprefix = "att"\n')
    (lab/'config/fleet-ledger').touch(); e['FM_HOME']=str(lab)
    def product(script,*args): return run(['bash',str(root/'bin'/script),*args])
    product('fm-attention.sh','--json')
    product('fm-captain-hold.sh','hold','att-call','--title','Beads call','--reason','choose (first), option','--repo','sample')
    product('fm-captain-hold.sh','hold','att-dated','--title','Dated call','--reason','defer option','--repo','sample','--until','2027-01-01')
    product('fm-tasks-axi.sh','add','att-blocker','Blocking task','--repo','sample')
    product('fm-tasks-axi.sh','block','att-call','--by','att-blocker')
    out=json.loads(product('fm-attention.sh','--json').stdout)
    (ev/'beads-attention.json').write_text(json.dumps(out,indent=2)+'\n')
    rows=out['open_decisions']
    assert len(rows)==2
    assert any(r['task']=='att-call' and r['bucket']=='blocked' and r['reason']=='choose (first), option' for r in rows)
    assert any(r['task']=='att-dated' and r['bucket']=='dated' for r in rows)
    assert not (lab/'data/backlog.md').exists()
    print('Real Beads-backed attention holds and blocker classification passed.')
finally:
    (ev/'beads-cli-transcript.json').write_text(json.dumps(log,indent=2)+'\n')
    shutil.rmtree(lab)
