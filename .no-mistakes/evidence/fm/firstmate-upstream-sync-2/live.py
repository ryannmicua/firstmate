import os, subprocess, json
from pathlib import Path
R=Path.cwd(); D=R/'.test-phase'; E=Path('/home/rgm/.no-mistakes/evidence/01M4WGXDNGGQ4VYQ87MTYR9JHP')
env={k:v for k,v in os.environ.items() if not (k.startswith('FM_') or k in ('NO_MISTAKES_GATE','TMUX','TMUX_PANE','TASKS_AXI_FILE','TASKS_AXI_BACKEND','GIT_DIR','GIT_WORK_TREE','GIT_COMMON_DIR','GIT_INDEX_FILE'))}
env.update(TMPDIR=str(D/'tmp'),GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1',TREEHOUSE_ROOT=str(D/'treehouse-project/.test-phase/pool'))
log=[]
def run(args,expect=0,cwd=R,extra=None):
    p=subprocess.run(list(map(str,args)),cwd=cwd,env=env| (extra or {}),text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=60)
    log.append('$ '+' '.join(map(str,args))+'\n'+p.stdout+f'\nexit={p.returncode}\n')
    (E/'live-cli.log').write_text('\n'.join(log))
    assert p.returncode==expect,log[-1]
    return p.stdout
h=D/'live-home'; run(['bin/fm-lab-home.sh','create',h]); env['FM_HOME']=str(h); (h/'config/backlog-backend').write_text('manual\n')
run(['bin/fm-role.sh','report']); run(['bin/fm-role.sh','check',R],1)
# Explicit invalid scope must not grant authority.
(h/'config/firstmate-role').write_text('maintainer github.com/unrelated/repository\n')
run(['bin/fm-role.sh','check',R],1)
(h/'config/firstmate-role').unlink()
# A backlog larger than MAX_ARG_STRLEN is transported intact by the real producer.
(h/'data/backlog.md').write_text('## In flight\n'+''.join(f'- [ ] orphan-{i}-'+('i'*110)+' - Missing metadata (repo: firstmate) (kind: ship)\n' for i in range(1200))+'\n## Queued\n\n## Done\n')
p=subprocess.run(['bin/fm-fleet-snapshot.sh','--contribution-input'],env=env,cwd=R,text=True,capture_output=True,timeout=60)
assert p.returncode==0,p.stderr
obj=json.loads(p.stdout); assert len(obj['backlog']['records'])==1200
(E/'large-contribution-input.json').write_text(p.stdout)
log.append(f'large contribution input: backlog bytes={(h/"data/backlog.md").stat().st_size}; emitted {len(obj["backlog"]["records"])} records intact\n')
# Existing announced recovery must survive another foreground checkpoint.
(h/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
(h/'state/.watcher-down').write_text('pending:downtime:live-scenario\n')
run(['bin/fm-watch-checkpoint.sh','--seconds','3'],extra={'FM_POLL':'1','FM_CHECK_INTERVAL':'999999'})
mark=(h/'state/.watcher-down').read_text(); assert mark=='announced:downtime:live-scenario\n',mark
out=run(['bin/fm-watch-checkpoint.sh','--seconds','1'],124,extra={'FM_POLL':'1','FM_CHECK_INTERVAL':'999999'})
assert 'rearm-resurface' not in out and (h/'state/.watcher-down').read_text()==mark
assert not (h/'state/.watch.lock/pid').exists()
# Real Treehouse slot: refuse a ship's nested repository, then clean scout scratch.
proj=D/'treehouse-project'; run(['treehouse','get','--lease','--no-fetch','--json'],cwd=proj); wt=next(proj.glob('.test-phase/pool/.treehouse/*/1/treehouse-project'))
run(['git','init','-q',wt/'nested']); (wt/'nested/payload').write_text('preserve ship bytes\n'); (wt/'scratch').write_text('scratch\n')
run(['tmux','-L','fm-lab-sync','new-session','-d','-s','lab','-x','120','-y','40','sleep 300'])
try:
    socket=run(['tmux','-L','fm-lab-sync','display-message','-p','-t','lab','#{socket_path}']).strip()
    env['TMUX']=socket+',0,0'; env['FM_BACKEND']='tmux'
    meta=h/'state/slot.meta'
    def write(kind):
        meta.write_text(f'window=lab:fm-slot\nendpoint_task_id=slot\nworktree={wt}\nproject={proj}\nkind={kind}\nmode=local-only\nbackend=tmux\nharness=claude\nspawn_gen=live-slot\ndecisions_reviewed=1\n')
    write('ship')
    run(['bin/fm-teardown.sh','slot'],1)
    assert (wt/'nested/payload').read_text()=='preserve ship bytes\n' and (wt/'scratch').exists() and meta.exists()
    write('scout'); (h/'data/slot').mkdir(); (h/'data/slot/report.md').write_text('Disposable scout report.\n')
    run(['bin/fm-teardown.sh','slot'])
    assert not (wt/'nested').exists() and not (wt/'scratch').exists() and not meta.exists()
    assert not run(['git','-C',wt,'status','--porcelain','--untracked-files=all']).strip()
    run(['treehouse','status'],cwd=proj)
finally:
    run(['tmux','-L','fm-lab-sync','kill-server'])
(E/'live-cli.log').write_text('\n'.join(log))
print('Direct role, large backlog, recovery checkpoint and real Treehouse scenarios passed.')
