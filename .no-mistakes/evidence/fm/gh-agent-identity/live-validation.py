import os, json, pathlib, subprocess, threading, http.server, urllib.parse, datetime, time, shutil, traceback
ROOT=pathlib.Path.cwd(); LAB=ROOT/'.validation-live'/'product'; E=pathlib.Path('~/.no-mistakes/evidence/01M76SRAYFNN4HYKJKEQJVSMDM')
LAB.mkdir(parents=True,exist_ok=True)
requests=[]; nodes={}; routes={}; notifications=[]; fail_notifications=False; delay=0; mints=0
class Server(http.server.BaseHTTPRequestHandler):
 def log_message(self,*args): pass
 def do_GET(self): self.answer()
 def do_POST(self): self.answer()
 def answer(self):
  global mints
  u=urllib.parse.urlsplit(self.path); p=urllib.parse.unquote(u.path); q=urllib.parse.parse_qs(u.query)
  body=json.loads(self.rfile.read(int(self.headers.get('Content-Length','0'))) or b'{}')
  auth=self.headers.get('Authorization',''); requests.append({'method':self.command,'path':self.path,'credential':('app-jwt' if auth.count('.')==2 else auth),'body':body})
  code=200
  if p=='/user': data={'login':'machine-bot','id':5150}
  elif p=='/app': data={'id':4242,'slug':'lab-app'}
  elif p=='~[bot]': data={'id':99001,'login':'lab-app[bot]'}
  elif p=='/repos/acme/widget': data={'permissions':{'push':True}}
  elif p=='/repos/acme/readonly': data={'permissions':{'push':False}}
  elif p=='/repos/acme/widget/installation': data={'id':777,'permissions':{'contents':'write'}}
  elif p=='/app/installations/777/access_tokens':
   mints+=1; code=201; data={'token':'ghs_SyntheticApp'+str(mints),'expires_at':'2099-01-01T00:00:00Z'}
  elif p=='/notifications':
   if delay: time.sleep(delay)
   code=503 if fail_notifications else 200; data={} if fail_notifications else (notifications if q.get('page',['1'])[0]=='1' else [])
  elif p=='/graphql': data={'data':{'nodes':[nodes.get(i) for i in body['variables']['ids']]}}
  elif p.endswith('/reactions'): data={} if self.command=='POST' else []; code=201 if self.command=='POST' else 200
  elif p in routes: data=routes[p]
  else: code=404; data={'message':'unknown emulator route'}
  raw=json.dumps(data).encode(); self.send_response(code); self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(raw))); self.end_headers()
  try:self.wfile.write(raw)
  except (BrokenPipeError,ConnectionResetError):pass
srv=http.server.ThreadingHTTPServer(('127.0.0.1',0),Server); srv.daemon_threads=True
thread=threading.Thread(target=srv.serve_forever); thread.start(); API='http://127.0.0.1:'+str(srv.server_port)
base=os.environ.copy()
for k in list(base):
 if k.startswith(('FM_','GIT_CONFIG_')) or k in ['GH_TOKEN','GITHUB_TOKEN','GH_ENTERPRISE_TOKEN','GITHUB_ENTERPRISE_TOKEN','GH_HOST','TASKS_AXI_FILE','TASKS_AXI_BACKEND']:base.pop(k,None)
base.update(HOME=str(LAB/'user'),FM_HOME=str(LAB/'home'),TMPDIR=str(LAB/'tmp'),FM_GH_API_URL=API,GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_GLOBAL=str(LAB/'gitconfig'),GIT_TERMINAL_PROMPT='0')
for d in ['user','tmp','home/config','home/state','home/data']: (LAB/d).mkdir(parents=True,exist_ok=True)
log=[]; results=[]
def run(args,env=None,inp=None,code=0):
 e=base.copy(); e.update(env or {})
 r=subprocess.run([str(a) for a in args],input=inp,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,env=e,cwd=ROOT,timeout=45)
 log.append('$ '+ ' '.join(str(a) for a in args)+'\n'+r.stdout+'[exit '+str(r.returncode)+']\n')
 assert r.returncode==code,(args,r.returncode,r.stdout)
 return r.stdout
ID=ROOT/'bin/fm-gh-identity.sh'; BOT=ROOT/'bin/fm-gh-bot-check.sh'; INBOX=ROOT/'bin/fm-inbox.sh'; HOME=LAB/'home'; cfg=HOME/'config'; worker=HOME/'state/worker'; envfile=LAB/'worker-env.sh'; repo=LAB/'repo'
def private(p,s): p.write_text(s);p.chmod(0o600)
def scenario(name,fn):
 try:fn();results.append({'name':name,'result':'pass','live':True});print('PASS '+name,flush=True)
 except Exception as e:results.append({'name':name,'result':'fail','live':True,'reason':str(e)});traceback.print_exc()
def cred(extra=''):
 return run(['bash','-c','. "$1"; printf "protocol=https\\nhost=github.com\\npath=acme/widget.git\\n\\n" | git '+extra+' credential fill','_',envfile])
def machine():
 (cfg/'github-identity').write_text('kind=token\n');private(cfg/'github-identity.token','ghp_SyntheticBot1\n')
 (LAB/'gitconfig').write_text('[credential]\n helper = "!f() { echo username=owner; echo password=synthetic-owner; }; f"\n[credential "https://github.com"]\n username = owner\n[user]\n name = Owner\n email = owner@example.test\n')
 before=(LAB/'gitconfig').read_bytes()
 run([ID,'status','acme/widget']);run([ID,'prepare-worker',worker,'acme/widget']);run([ID,'env-file',worker,envfile])
 assert 'password=ghp_SyntheticBot1' in cred()
 run(['git','init','-q',repo]);run(['bash','-c','. "$1"; git -C "$2" commit -q --allow-empty -m "Local identity proof"; git -C "$2" log -1 --format="%an <%ae>|%cn <%ce>"','_',envfile,repo])
 identity=run(['git','-C',repo,'log','-1','--format=%an <%ae>|%cn <%ce>'])
 assert identity.strip()=='machine-bot <5150+machine-bot@users.noreply.github.com>|machine-bot <5150+machine-bot@users.noreply.github.com>'
 private(cfg/'github-identity.token','ghp_SyntheticBot2\n');assert 'password=ghp_SyntheticBot2' in cred()
 outside=run(['git','credential','fill'],inp='protocol=https\nhost=github.com\npath=acme/widget.git\n\n');assert 'password=synthetic-owner' in outside
 assert before==(LAB/'gitconfig').read_bytes()
 # Full URL keeps real gh on localhost; generated wrapper supplies GH_TOKEN.
 out=run(['bash','-c','. "$1"; gh api "$2/user"','_',envfile,API]);assert json.loads(out)['login']=='machine-bot'
def app():
 global mints
 private(cfg/'github-identity','kind=app\napp_id=4242\n')
 run(['openssl','genrsa','-out',cfg/'github-identity.pem','2048']);(cfg/'github-identity.pem').chmod(0o600)
 run([ID,'status','acme/widget']);run([ID,'prepare-worker',worker,'acme/widget']);run([ID,'env-file',worker,envfile]);assert 'password=ghs_SyntheticApp1' in cred();assert 'password=ghs_SyntheticApp1' in cred();assert mints==1
 cache=HOME/'state/gh-identity/tokens/4242-acme__widget';private(cache,'expires=1\ntoken=ghs_Expired\n');assert 'password=ghs_SyntheticApp2' in cred();assert mints==2
 mint=[r for r in requests if r['path']=='/app/installations/777/access_tokens'];assert all(r['body']=={'repositories':['widget']} for r in mint)
def guards():
 private(cfg/'github-identity','kind=token\n');run([ID,'status','acme/readonly'],code=3)
 (cfg/'github-identity.token').chmod(0o644);out=run([ID,'status','acme/widget'],code=1);assert 'chmod 600' in out;(cfg/'github-identity.token').chmod(0o600)
 run(['git','-C',repo,'remote','add','origin','https://owner:synthetic-password@github.com/acme/widget.git'])
 out=run([ID,'check-remotes',repo],code=1);assert 'remove embedded credentials' in out and 'synthetic-password' not in out
 run(['git','-C',repo,'remote','set-url','origin','https://github.com/acme/widget.git']);run([ID,'check-remotes',repo])
 private(LAB/'user/.netrc','machine github.com login owner password SyntheticNetrc\n');out=run([ID,'env-file',worker,envfile],code=1);assert 'netrc' in out and 'SyntheticNetrc' not in out;(LAB/'user/.netrc').unlink()
def item(n,author,text,editor=None,edited=False,rest=None):
 p=f'/repos/acme/widget/issues/comments/{n}'; node='IC_'+str(n)
 obj={'id':n,'node_id':node,'user':{'login':author},'body':rest or text,'html_url':f'https://github.com/acme/widget/issues/5#issuecomment-{n}','url':API+p}
 nodes[node]={'id':node,'body':text,'author':{'login':author},'lastEditedAt':'2026-11-01T00:00:00Z' if edited else None,'editor':{'login':editor} if editor else None};return obj
stamp=(datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(minutes=5)).strftime('%Y-%m-%dT%H:%M:%SZ')
def thread_item(n,typ,p):return {'id':str(n),'reason':'mention','updated_at':stamp,'repository':{'full_name':'acme/widget'},'subject':{'title':'Synthetic intake','type':typ,'url':API+p,'latest_comment_url':API+'/deleted-latest-comment'}}
def inbox():
 (cfg/'github-bot').write_text('login=machine-bot\nowner=Owner\n');private(cfg/'github-bot.token','ghp_SyntheticInbox\n')
 comments=[item(1,'Owner','@machine-bot perform owner task',rest='@machine-bot stale REST text'),item(2,'stranger','@machine-bot stranger request'),item(3,'Owner','@machine-bot collaborator-edited text','stranger',True),item(4,'Owner','@machine-bot owner-edited request','Owner',True),item(5,'Owner','@machine-bot-suffix must not count')]
 routes['/repos/acme/widget/issues/5']={'html_url':'https://github.com/acme/widget/issues/5','title':'Synthetic intake'}
 routes['/repos/acme/widget/issues/5/comments']=comments
 routes['/repos/acme/widget/issues/5/events']=[{'id':9001,'event':'assigned','actor':{'login':'Owner'},'assignee':{'login':'machine-bot'}},{'id':9002,'event':'review_requested','actor':{'login':'stranger'},'requested_reviewer':{'login':'machine-bot'}}]
 notifications.append(thread_item(1,'Issue','/repos/acme/widget/issues/5'))
 run([BOT,'poll']); text=run([INBOX,'list']); (E/'inbox-output.txt').write_text(text)
 notes=[p.read_text() for p in (HOME/'state/inbox').glob('*.note')];assert len(notes)==6,len(notes)
 for phrase,trusted in [('perform owner task',True),('stranger request',False),('collaborator-edited text',False),('owner-edited request',True)]:
  note=next(n for n in notes if phrase in n);assert ('From the owner: an instruction' in note)==trusted;assert trusted or 'do not act' in note
 assert not any('stale REST text' in n or 'must not count' in n for n in notes)
 assert any('assignment' in n and 'From the owner: an instruction' in n for n in notes)
 assert any('review request' in n and 'do not act' in n for n in notes)
def recovery():
 global fail_notifications,delay
 initial=len(list((HOME/'state/inbox').glob('*.note')));reactions=len([r for r in requests if r['method']=='POST' and r['path'].endswith('/reactions')])
 run([BOT,'poll']);assert len(list((HOME/'state/inbox').glob('*.note')))==initial;assert reactions==len([r for r in requests if r['method']=='POST' and r['path'].endswith('/reactions')])
 record=HOME/'state/.github-bot-check';before=record.read_text();fail_notifications=True;run([BOT,'poll'],code=1);assert before==record.read_text();fail_notifications=False
 # Commit and PR notifications exercise separate collection paths and no deleted latest fetch.
 c=item(11,'Owner','@machine-bot commit task');c['url']=API+'/repos/acme/widget/comments/11';routes['/repos/acme/widget/commits/abc']={'html_url':'https://github.com/acme/widget/commit/abc'};routes['/repos/acme/widget/commits/abc/comments']=[c]
 routes['/repos/acme/widget/pulls/7']={'html_url':'https://github.com/acme/widget/pull/7'}
 routes['/repos/acme/widget/issues/7/comments']=[];routes['/repos/acme/widget/issues/7/events']=[];routes['/repos/acme/widget/pulls/7/comments']=[]
 review=item(12,'Owner','@machine-bot review task');review['submitted_at']='2026-11-01T00:00:00Z';routes['/repos/acme/widget/pulls/7/reviews']=[review]
 notifications.extend([thread_item(2,'Commit','/repos/acme/widget/commits/abc'),thread_item(3,'PullRequest','/repos/acme/widget/pulls/7')]);run([BOT,'poll']);assert len(list((HOME/'state/inbox').glob('*.note')))==initial+2
 assert not any('/commits/abc/events' in r['path'] or '/deleted-latest-comment' in r['path'] for r in requests)
 run([BOT,'arm']);delay=4;run([BOT,'check']);lock=HOME/'state/.github-bot-poll.lock';assert lock.is_symlink();run([BOT,'disarm']);time.sleep(5);assert not lock.exists() and not record.exists();delay=0
try:
 scenario('Machine-user worker uses synthetic bot credentials and commit identity while isolated owner credentials remain usable',machine)
 scenario('GitHub App worker mints repository-scoped tokens, reuses cache, and refreshes expired tokens through localhost API',app)
 scenario('Authentication guards reject read-only access, public token files, embedded remote credentials, and owner netrc',guards)
 scenario('Local notification poll saves owner mentions and assignments as instructions and marks stranger or collaborator-edited text do-not-act',inbox)
 scenario('Local polling deduplicates replay, preserves cursor after HTTP failure, handles commits/reviews/deleted latest URLs, and disarms a running poll',recovery)
finally:
 srv.shutdown();srv.server_close();thread.join()
 (E/'live-transcript.log').write_text('\n'.join(log));(E/'local-api-requests.json').write_text(json.dumps(requests,indent=2));(E/'live-results.json').write_text(json.dumps(results,indent=2))
 shutil.rmtree(LAB)
if any(r['result']=='fail' for r in results):raise SystemExit(1)
