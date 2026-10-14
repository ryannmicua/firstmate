import os,json,subprocess,urllib.request,base64,time
from pathlib import Path
R=Path.cwd(); D=R/'.test-phase'; E=Path('/home/rgm/.no-mistakes/evidence/01M4WGXDNGGQ4VYQ87MTYR9JHP'); log=[]
env={k:v for k,v in os.environ.items() if not (k.startswith('FM_') or k.startswith('GIT_') or k in ('NO_MISTAKES_GATE','TMUX','TMUX_PANE'))}
env.update(PATH=str(D)+':'+env['PATH'],HOME=str(D/'forgejo-home'),XDG_CONFIG_HOME=str(D/'tea-config'),TMPDIR=str(D/'tmp'),GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1')
def api(path,data=None,method=None):
    req=urllib.request.Request('http://localhost:39871/api/v1'+path,data=json.dumps(data).encode() if data is not None else None,method=method,headers={'Content-Type':'application/json','Authorization':'Basic '+base64.b64encode(b'fixture:DisposableOnly123').decode()})
    with urllib.request.urlopen(req,timeout=15) as f: return json.load(f)
def run(args,expect=0,cwd=R):
    p=subprocess.run(list(map(str,args)),env=env,cwd=cwd,text=True,capture_output=True,timeout=45)
    log.append('$ '+' '.join(map(str,args))+'\n'+p.stdout+p.stderr+f'\nexit={p.returncode}\n'); (E/'forgejo-live.log').write_text('\n'.join(log)); assert p.returncode==expect,log[-1]; return p.stdout
repo=api('/user/repos',{'name':'fixture-repo','auto_init':True,'default_branch':'main'})
work=D/'forge-repo'; run(['git','clone','-q','http://fixture:DisposableOnly123@localhost:39871/fixture/fixture-repo',work])
run(['git','checkout','-qb','change'],cwd=work); (work/'feature.txt').write_text('A real feature\n'); run(['git','add','feature.txt'],cwd=work)
run(['git','-c','user.name=Fixture','-c','user.email=fixture@example.invalid','-c','commit.gpgsign=false','commit','-qm','feature'],cwd=work); run(['git','push','-q','origin','change'],cwd=work)
pr=api('/repos/fixture/fixture-repo/pulls',{'head':'change','base':'main','title':'Disposable feature'})
head=pr['head']['sha']; url='https://localhost/fixture/fixture-repo/pulls/'+str(pr['number'])
h=D/'forge-home'; run(['bin/fm-lab-home.sh','create',h]); env['FM_HOME']=str(h)
(h/'state/feature.meta').write_text(f'kind=ship\nmode=direct-PR\nyolo=off\nproject={work}\nworktree={work}\nbranch=change\nspawn_gen=forge-live\n')
api('/repos/fixture/fixture-repo/statuses/'+head,{'state':'failure','context':'validation','description':'Adversarial failing status'})
time.sleep(2)
run(['bin/fm-pr-merge.sh','feature',url],1)
assert not api('/repos/fixture/fixture-repo/pulls/'+str(pr['number']))['merged']
api('/repos/fixture/fixture-repo/statuses/'+head,{'state':'success','context':'validation','description':'Green exact head'})
run(['bin/fm-pr-merge.sh','feature',url])
record=api('/repos/fixture/fixture-repo/pulls/'+str(pr['number'])); assert record['merged']
assert run(['bin/fm-pr-poll.sh','--validated','forgejo',url,'localhost','fixture/fixture-repo',pr['number']]).strip()=='merged'
assert run(['bin/fm-pr-poll.sh','--validated','forgejo',url.replace('/pulls/','/pulls/999'), 'localhost','fixture/fixture-repo','999'+str(pr['number'])]).strip()==''
(E/'forgejo-merged-record.json').write_text(json.dumps({k:record[k] for k in ['number','state','merged','merge_commit_sha','head','base']},indent=2))
# Redact disposable clone credentials even though this account dies with the fixture.
(E/'forgejo-live.log').write_text('\n'.join(log).replace('fixture:DisposableOnly123@','fixture:<disposable-password>@'))
print('Forgejo rejects red status, merges green exact head and emits merged poll.')
