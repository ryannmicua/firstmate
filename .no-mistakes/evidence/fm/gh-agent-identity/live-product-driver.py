"""Disposable product driver: real CLI clients against a localhost GitHub/Git emulator.
Only synthetic credentials and data are used; all owned children are awaited.
"""
import base64, datetime, hashlib, http.server, json, os, pathlib, shutil, signal, socket, ssl, subprocess, threading, time, urllib.parse
ROOT=pathlib.Path.cwd(); LAB=ROOT/'.local-validation'; EVID=pathlib.Path('~/.no-mistakes/evidence/01M76SRAYFNN4HYKJKEQJVSMDM')
LOG=[]; RESULTS=[]; REQUESTS=[]; nodes={}; threads=[]; subjects={}; lists={}; reactions=set(); minted=0; delay=0; fail_page=False
TOKEN='ghp_DisposableBot0001'; APP_TOKEN='ghs_DisposableApp0001'; OWNER='ghp_DisposableOwner0001'
def record(s):
    LOG.append(s); print(s,flush=True)
def run(args,env=None,input=None,ok=0,cwd=ROOT):
    p=subprocess.run([str(x) for x in args],env=env,cwd=cwd,input=input,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=90)
    record('$ '+' '.join(str(x) for x in args)+'\n'+p.stdout.rstrip()+f'\n[exit {p.returncode}]')
    assert p.returncode==ok,(args,p.returncode,p.stdout)
    return p.stdout
base=os.environ.copy()
for key in list(base):
    if key.startswith(('FM_', 'GIT_', 'GH_', 'GITHUB_', 'TASKS_AXI_')) or key in ('NETRC','TMUX','REX_SESSION','REX_BLOCK'):
        base.pop(key,None)
base.update(HOME=str(LAB/'user'),TMPDIR=str(LAB/'tmp'),GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_GLOBAL=str(LAB/'owner.gitconfig'),GH_CONFIG_DIR=str(LAB/'owner-gh'),GIT_TERMINAL_PROMPT='0',NO_PROXY='',no_proxy='')
for d in ('user','tmp','owner-gh','remotes'): (LAB/d).mkdir(exist_ok=True)
(LAB/'owner.gitconfig').write_text('[user]\n name = Local Owner\n email = owner@example.invalid\n[credential "https://github.com"]\n username = owner\n[credential]\n helper = "!f() { echo username=owner; echo password='+OWNER+'; }; f"\n')
original_config=(LAB/'owner.gitconfig').read_bytes()
run(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-keyout',LAB/'tls.key','-out',LAB/'tls.crt','-days','1','-subj','/CN=github.com','-addext','subjectAltName=DNS:github.com,DNS:api.github.com'],env=base)
run(['git','init','--bare','-q',LAB/'remotes/widget.git'],env=base)
run(['git','--git-dir',LAB/'remotes/widget.git','config','http.receivepack','true'],env=base)
ctx=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain(LAB/'tls.crt',LAB/'tls.key')
class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version='HTTP/1.1'
    def log_message(self,*a): pass
    def do_CONNECT(self):
        assert self.path in ('github.com:443','api.github.com:443'),self.path
        self.send_response(200); self.end_headers()
        self.connection=ctx.wrap_socket(self.connection,server_side=True)
        self.rfile=self.connection.makefile('rb',buffering=0); self.wfile=self.connection.makefile('wb',buffering=0)
        self.close_connection=False
    def do_GET(self): self.route()
    def do_POST(self): self.route()
    def answer(self,status,body,headers=None):
        raw=json.dumps(body).encode() if not isinstance(body,bytes) else body
        self.send_response(status)
        for k,v in (headers or {}).items(): self.send_header(k,v)
        self.send_header('Content-Length',str(len(raw))); self.end_headers()
        try: self.wfile.write(raw)
        except (BrokenPipeError,ssl.SSLEOFError): pass
    def route(self):
        global minted
        parsed=urllib.parse.urlparse(self.path); path=parsed.path; q=urllib.parse.parse_qs(parsed.query)
        raw=self.rfile.read(int(self.headers.get('Content-Length',0))); data=json.loads(raw) if raw and 'json' in self.headers.get('Content-Type','') else None
        auth=self.headers.get('Authorization',''); actor='anonymous'
        if auth.split(' ')[-1]==TOKEN: actor='bot'
        elif auth.split(' ')[-1]==APP_TOKEN: actor='app-bot'
        elif auth.split(' ')[-1]==OWNER: actor='owner'
        elif auth.startswith('Bearer ey'): actor='app-jwt'
        elif auth.startswith('Basic '):
            user,pw=base64.b64decode(auth[6:]).decode().split(':',1)
            actor={TOKEN:'bot',APP_TOKEN:'app-bot',OWNER:'owner'}.get(pw,'unknown')
        REQUESTS.append(dict(method=self.command,path=self.path,actor=actor,body=data))
        if path.startswith('/acme/widget.git/'):
            if actor not in ('bot','app-bot'):
                return self.answer(401,b'',{'WWW-Authenticate':'Basic realm="local git"'})
            ge=base.copy(); ge.update(GIT_PROJECT_ROOT=str(LAB/'remotes'),GIT_HTTP_EXPORT_ALL='1',PATH_INFO=path[len('/acme'):],REQUEST_METHOD=self.command,QUERY_STRING=parsed.query,CONTENT_TYPE=self.headers.get('Content-Type',''),CONTENT_LENGTH=str(len(raw)),REMOTE_USER=actor,SERVER_PROTOCOL='HTTP/1.1')
            p=subprocess.run(['git','http-backend'],env=ge,input=raw,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=20)
            assert p.returncode==0,p.stderr
            head,body=p.stdout.split(b'\r\n\r\n',1); headers={}; status=200
            for line in head.decode().split('\r\n'):
                k,v=line.split(':',1)
                if k=='Status': status=int(v.split()[0])
                else: headers[k]=v.strip()
            return self.answer(status,body,headers)
        if path=='/user': return self.answer(200,{'login':{'owner':'local-owner','app-bot':'local-app[bot]'}.get(actor,'local-bot'),'id':9001})
        if path=='/app':
            jwt=auth.split(' ')[-1]; h,p,s=jwt.split('.')
            payload=json.loads(base64.urlsafe_b64decode(p+'='*(-len(p)%4))); assert payload['iss']=='42'
            sig=base64.urlsafe_b64decode(s+'='*(-len(s)%4)); (LAB/'jwt.sig').write_bytes(sig)
            v=subprocess.run(['openssl','dgst','-sha256','-verify',str(LAB/'app.pub'),'-signature',str(LAB/'jwt.sig')],input=(h+'.'+p).encode(),stdout=subprocess.PIPE)
            assert v.returncode==0
            return self.answer(200,{'slug':'local-app','id':42})
        if path=='~': return self.answer(200,{'id':9002,'login':'local-app[bot]'})
        if path.endswith('/installation'):
            return self.answer(200 if '/widget/' in path else 404,{'id':77,'permissions':{'contents':'write'}})
        if path=='/app/installations/77/access_tokens':
            assert actor=='app-jwt' and data=={'repositories':['widget']}; minted+=1
            return self.answer(201,{'token':APP_TOKEN,'expires_at':'2099-01-01T00:00:00Z'})
        if path=='/repos/acme/widget': return self.answer(200,{'permissions':{'push':True}})
        if path=='/repos/acme/denied': return self.answer(404,{'message':'Not Found'})
        if path=='/notifications':
            if delay: time.sleep(delay)
            if fail_page and q.get('page')==['2']: return self.answer(503,{'message':'temporary local failure'})
            page=int(q.get('page',['1'])[0]); size=int(q['per_page'][0]); return self.answer(200,threads[(page-1)*size:page*size])
        if path=='/graphql': return self.answer(200,{'data':{'nodes':[nodes.get(i) for i in data['variables']['ids']]}})
        if path.endswith('/reactions'):
            if self.command=='POST': reactions.add(path); return self.answer(201,{'content':'eyes'})
            return self.answer(200,[{'content':'eyes','user':{'login':'local-bot'}}] if path in reactions else [])
        if path in subjects: return self.answer(200,subjects[path])
        if path in lists: return self.answer(200,lists[path])
        return self.answer(404,{'message':'local emulator has no such resource'})
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler); server.daemon_threads=True
server_thread=threading.Thread(target=server.serve_forever); server_thread.start(); api=f'http://127.0.0.1:{server.server_port}'
base.update(FM_GH_API_URL=api,HTTPS_PROXY=api,https_proxy=api,HTTP_PROXY='',http_proxy='',SSL_CERT_FILE=str(LAB/'tls.crt'),GIT_SSL_CAINFO=str(LAB/'tls.crt'))
# localhost must bypass proxies for ordinary curl API calls.
base.update(NO_PROXY='127.0.0.1,localhost',no_proxy='127.0.0.1,localhost')
ID=ROOT/'bin/fm-gh-identity.sh'; BOT=ROOT/'bin/fm-gh-bot-check.sh'
def home(name):
    p=LAB/name; run([ROOT/'bin/fm-lab-home.sh','create',p],env=base); return p
h=home('home'); env=base.copy(); env['FM_HOME']=str(h)
(h/'config/github-identity').write_text('kind=token\n'); (h/'config/github-identity.token').write_text(TOKEN); (h/'config/github-identity.token').chmod(0o600)
def worker_shell(profile,command):
    envfile=profile/'worker.env'; run([ID,'env-file',profile,envfile],env=env)
    return run(['bash','-c','. "$1"; '+command,'_',envfile],env=env,cwd=LAB/'work')
def scenario(name,fn):
    record('\nSCENARIO: '+name)
    try:
        fn(); RESULTS.append({'name':name,'result':'pass','live':True}); record('RESULT: pass')
    except Exception as e:
        RESULTS.append({'name':name,'result':'fail','live':True,'reason':repr(e)}); record('RESULT: fail '+repr(e))
def identity_token():
    run([ID,'status','acme/widget'],env=env)
    profile=h/'state/token-worker'; run([ID,'prepare-worker',profile,'acme/widget'],env=env)
    run(['git','init','-q',LAB/'work'],env=env); run(['git','remote','add','origin','https://github.com/acme/widget.git'],env=env,cwd=LAB/'work')
    run([ID,'check-remotes',LAB/'work'],env=env)
    worker_shell(profile,'git commit -q --allow-empty -m "Local bot identity probe" && git push origin HEAD:refs/heads/token-probe && git fetch origin && git log -1 --format="%an <%ae>|%cn <%ce>" && gh api user --jq .login')
    gitcalls=[r for r in REQUESTS if '/git-receive-pack' in r['path']]
    assert gitcalls and all(r['actor']=='bot' for r in gitcalls if r['actor']!='anonymous')
    author=run(['git','--git-dir',LAB/'remotes/widget.git','log','refs/heads/token-probe','-1','--format=%an <%ae>|%cn <%ce>'],env=env)
    assert author.strip()=='local-bot <9001+local-bot@users.noreply.github.com>|local-bot <9001+local-bot@users.noreply.github.com>'
    ownerenv=base.copy(); ownerenv['GH_TOKEN']=OWNER
    assert run(['gh','api','user','--jq','.login'],env=ownerenv).strip()=='local-owner'
    assert (LAB/'owner.gitconfig').read_bytes()==original_config
    record('Real Git pushed and fetched as bot; real gh used bot inside the worker and owner outside. Owner git config byte-identical.')
def identity_app():
    run(['openssl','genrsa','-out',h/'config/github-identity.pem','2048'],env=env); (h/'config/github-identity.pem').chmod(0o600)
    run(['openssl','rsa','-in',h/'config/github-identity.pem','-pubout','-out',LAB/'app.pub'],env=env)
    (h/'config/github-identity').write_text('kind=app\napp_id=42\n')
    profile=h/'state/app-worker'; run([ID,'prepare-worker',profile,'acme/widget'],env=env)
    worker_shell(profile,'git commit -q --allow-empty -m "Local App identity probe" && git push origin HEAD:refs/heads/app-probe && gh api user --jq .login')
    assert minted==1,minted
    cache=h/'state/gh-identity/tokens/42-acme__widget'; cache.write_text(f'expires={int(time.time())+30}\ntoken=ghs_ExpiredSynthetic\n'); cache.chmod(0o600)
    out=worker_shell(profile,'gh api user --jq .login'); assert 'local-app[bot]' in out and minted==2
    run([ID,'prepare-worker',h/'state/denied-worker','acme/denied'],env=env,ok=3); assert not (h/'state/denied-worker').exists()
    record('App JWT verified with OpenSSL; repository-scoped token cached, then refreshed; denied installation produced no worker.')
def guards():
    (h/'config/github-identity').write_text('kind=token\n'); p=h/'config/github-identity.token'; p.chmod(0o644)
    n=len(REQUESTS); out=run([ID,'status','acme/widget'],env=env,ok=1); assert 'chmod 600' in out and len(REQUESTS)==n; p.chmod(0o600)
    run([ID,'prepare-worker',h/'state/no-access','acme/denied'],env=env,ok=3)
    run(['git','remote','set-url','origin','https://owner:synthetic@github.com/acme/widget.git'],env=env,cwd=LAB/'work')
    assert 'embedded credentials' in run([ID,'check-remotes',LAB/'work'],env=env,ok=1)
    run(['git','remote','set-url','origin','https://github.com/acme/widget.git'],env=env,cwd=LAB/'work')
    (LAB/'user/.netrc').write_text('machine github.com login owner password SyntheticOnly\n')
    assert 'netrc entry' in run([ID,'env-file',h/'state/token-worker',LAB/'refused.env'],env=env,ok=1); (LAB/'user/.netrc').unlink()
    record('Insecure token, missing access, embedded remote credentials and owner netrc all refused without owner fallback.')

def item(i,author,text,kind='issues',edited=None,snapshot=None):
    rest={'id':i,'node_id':f'N{i}','user':{'login':author},'body':text,'html_url':f'https://github.com/acme/widget/{kind}/1#item-{i}','url':f'{api}/repos/acme/widget/{kind}/comments/{i}'}
    if author.lower()=='owner-one': nodes[f'N{i}']={'id':f'N{i}','author':{'login':author},'body':snapshot or text,'lastEditedAt':'2026-11-12T00:00:00Z' if edited else None,'editor':{'login':edited} if edited else None}
    return rest
bh=home('bot-home'); benv=base.copy(); benv['FM_HOME']=str(bh)
(bh/'config/github-bot').write_text('login=local-bot\nowner=Owner-One\n'); (bh/'config/github-bot.token').write_text(TOKEN); (bh/'config/github-bot.token').chmod(0o600)
def seed():
    global threads
    now=datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(hours=1)
    stamp=now.strftime('%Y-%m-%dT%H:%M:%SZ')
    def thread(i,typ,path,reason): return {'id':str(i),'reason':reason,'updated_at':stamp,'last_read_at':stamp,'repository':{'full_name':'acme/widget'},'subject':{'title':'Synthetic '+typ,'type':typ,'url':api+path,'latest_comment_url':api+'/deleted/comment'}}
    issue='/repos/acme/widget/issues/1'; pr='/repos/acme/widget/pulls/2'; commit='/repos/acme/widget/commits/abc123'
    subjects[issue]=item(100,'Owner-One','@local-bot owner issue body'); subjects[issue]['html_url']='https://github.com/acme/widget/issues/1'
    subjects[pr]=item(200,'stranger','@local-bot stranger PR body','pull'); subjects[pr]['html_url']='https://github.com/acme/widget/pull/2'
    subjects[commit]={'html_url':'https://github.com/acme/widget/commit/abc123'}
    lists[issue+'/comments']=[item(101,'Owner-One','@local-bot owner comment'),item(102,'stranger','@local-bot outsider comment'),item(103,'Owner-One','@local-bot collaborator edited','issues',edited='stranger'),item(104,'Owner-One','@local-bot stale REST text','issues',snapshot='@local-bot verified snapshot text'),item(105,'Owner-One','@local-bot owner self-edit','issues',edited='Owner-One'),item(106,'Owner-One','@local-bot unknown provenance')]
    nodes.pop('N106')
    lists['/repos/acme/widget/issues/2/comments']=[]
    lists[pr+'/comments']=[item(201,'Owner-One','@local-bot review comment','pull')]
    review=item(202,'Owner-One','@local-bot submitted review','pull'); review['submitted_at']=stamp
    pending=item(203,'Owner-One','@local-bot pending review','pull'); pending['submitted_at']=None
    lists[pr+'/reviews']=[review,pending]
    lists[commit+'/comments']=[item(301,'Owner-One','@local-bot commit comment','commit')]
    lists[issue+'/events']=[{'id':500,'event':'assigned','actor':{'login':'Owner-One'},'assignee':{'login':'local-bot'}},{'id':501,'event':'assigned','actor':{'login':'stranger'},'assignee':{'login':'local-bot'}}]
    lists['/repos/acme/widget/issues/2/events']=[{'id':502,'event':'review_requested','actor':{'login':'Owner-One'},'requested_reviewer':{'login':'local-bot'}}]
    threads=[thread(1,'Commit',commit,'mention'),thread(2,'Issue',issue,'assign'),thread(3,'PullRequest',pr,'review_requested')]
    threads += [thread(i,'Discussion',f'/ignored/{i}','mention') for i in range(4,55)]
def notes(): return [p.read_text() for p in (bh/'state/inbox').glob('*.note')]
def intake():
    seed(); run([BOT,'poll'],env=benv)
    ns=notes(); record('Persisted inbox notes:\n'+'\n---\n'.join(ns)); assert len(ns)==14,len(ns)
    for text in ['owner issue body','owner comment','verified snapshot text','owner self-edit','review comment','submitted review','commit comment']:
        matches=[n for n in ns if text in n]; assert len(matches)==1 and 'From the owner: an instruction' in matches[0],text
    for text in ['stranger PR body','outsider comment','collaborator edited','unknown provenance']:
        matches=[n for n in ns if text in n]; assert len(matches)==1 and 'NOT FROM THE OWNER' in matches[0] and 'do not act' in matches[0],text
    assert not any('stale REST text' in n or 'pending review' in n for n in ns)
    assert any('assignment' in n and 'by Owner-One (the owner)' in n for n in ns)
    assert any('assignment' in n and 'by stranger (NOT FROM THE OWNER)' in n for n in ns)
    assert any('review request' in n and 'by Owner-One (the owner)' in n for n in ns)
    assert not any('/commits/abc123/events' in r['path'] or '/deleted/comment' in r['path'] for r in REQUESTS)
    assert any('/notifications?' in r['path'] and 'page=2' in r['path'] for r in REQUESTS)
    EVID.joinpath('persisted-inbox-notes.txt').write_text('\n---\n'.join(ns))
def replay_retry():
    global fail_page
    before=len(notes()); before_react=sum(r['method']=='POST' and '/reactions' in r['path'] for r in REQUESTS)
    recordfile=bh/'state/.github-bot-check'; saved=recordfile.read_text(); recordfile.unlink()
    run([BOT,'poll'],env=benv); assert len(notes())==before
    assert sum(r['method']=='POST' and '/reactions' in r['path'] for r in REQUESTS)==before_react
    recordfile.write_text(saved); fail_page=True
    out=run([BOT,'poll'],env=benv,ok=1); assert 'could not retrieve' in out and recordfile.read_text()==saved
    fail_page=False; run([BOT,'poll'],env=benv); assert len(notes())==before
    record('Repeat poll created no duplicate notes/reactions; page-two HTTP 503 preserved cursor; recovery completed.')
def lifecycle():
    global delay
    run([BOT,'arm'],env=benv); assert (bh/'state/github-bot.check-trust').exists()
    unrelated=subprocess.Popen(['sleep','30'],start_new_session=True)
    try:
        lock=bh/'state/.github-bot-poll.lock'; lock.symlink_to(str(unrelated.pid)); delay=4
        start=time.monotonic(); run([BOT,'check'],env=benv); assert time.monotonic()-start<3
        deadline=time.monotonic()+3
        while lock.is_symlink() and os.readlink(lock)==str(unrelated.pid) and time.monotonic()<deadline: time.sleep(0.02)
        pid=int(os.readlink(lock)); assert pid!=unrelated.pid
        assert os.getpgid(pid)==pid
        record(f'Unrelated PID {unrelated.pid} replaced by owned poll PID {pid}; check returned while API request delayed.')
        run([BOT,'disarm'],env=benv); assert unrelated.poll() is None
        delay=0; time.sleep(5)
        assert not lock.exists() and not (bh/'state/.github-bot-check').exists() and not (bh/'state/.github-bot-poll.out').exists()
        assert not (bh/'state/github-bot.check.sh').exists()
        try: os.killpg(pid,0)
        except ProcessLookupError: pass
        else: raise AssertionError('owned process group remains')
        record('Disarm stopped poll group; no state recreated after delayed response; unrelated process survived.')
    finally:
        unrelated.terminate(); unrelated.wait()
        lock=bh/'state/.github-bot-poll.lock'
        if lock.is_symlink():
            try: os.killpg(int(os.readlink(lock)),signal.SIGKILL)
            except ProcessLookupError: pass
        delay=0
try:
    scenario('Machine-user identity: real Git push/fetch and gh API use synthetic bot while owner remains usable',identity_token)
    scenario('GitHub App identity: signed JWT, repository-scoped cache refresh and denied-installation refusal on localhost',identity_app)
    scenario('Identity guards reject insecure secrets, denied access, embedded remote credentials and owner netrc',guards)
    scenario('Local notification API produces owner instructions and non-actionable outsider/edited notes across issue, PR and commit sources',intake)
    scenario('Paged discovery retries HTTP failure without cursor loss; repeated notifications do not duplicate notes or reactions',replay_retry)
    scenario('Arm/check/disarm replaces unrelated stale PID and stops delayed owned poll without touching unrelated process',lifecycle)
finally:
    server.shutdown(); server.server_close(); server_thread.join()
    EVID.joinpath('live-product-transcript.txt').write_text('\n'.join(LOG)+'\n')
    EVID.joinpath('local-api-requests.json').write_text(json.dumps(REQUESTS,indent=2)+'\n')
    EVID.joinpath('live-scenarios.json').write_text(json.dumps(RESULTS,indent=2)+'\n')
    record('Local emulator stopped and awaited.')
if any(s['result']=='fail' for s in RESULTS): raise SystemExit(1)
