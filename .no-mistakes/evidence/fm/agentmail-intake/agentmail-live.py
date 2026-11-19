import os, sys, json, tempfile, shutil, subprocess, threading, time, socket, datetime
from pathlib import Path
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs, unquote
ROOT=Path.cwd(); E=Path(__file__).parent
scratch=Path(tempfile.mkdtemp(prefix='.agentmail-live-',dir=ROOT)); home=scratch/'home'
(home/'config').mkdir(parents=True); (home/'state').mkdir()
(home/'config/agentmail').write_text('inbox=agent@example.test\nowner=personal@example.test\nowner=work@example.test\nroute=ryannmicua:personal@example.test\nroute=adventistasia:work@example.test\n')
key=home/'config/agentmail.key'; key.write_text('am_DisposableLiveValidationOnly\n'); key.chmod(0o600)
messages=[]; calls=[]; mode='ok'; page_size=2; patch_fail=False; results=[]; children=[]
class API(BaseHTTPRequestHandler):
 def log_message(self,*args): pass
 def answer(self,status,data):
  body=json.dumps(data).encode(); self.send_response(status); self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
 def do_GET(self):
  p=urlparse(self.path); q=parse_qs(p.query); path=unquote(p.path); calls.append({'method':'GET','path':path,'query':q})
  if path.endswith('/messages'):
   items=list(messages)
   # Enforce discovery filters; a sending-time cursor would lose delayed mail.
   for lab in ['unauthenticated','spam','blocked']:
    if q.get('include_'+lab)!=['true']: items=[m for m in items if lab not in m['labels']]
   if 'after' in q: items=[m for m in items if m['timestamp']>q['after'][0]]
   n=int(q.get('page_token',['0'])[0]); data={'messages':items[n:n+page_size]}
   if n+page_size<len(items):data['next_page_token']=str(n+page_size)
   self.answer(200,data)
  else:
   mid=path.rsplit('/',1)[-1]; self.answer(200,next(m for m in messages if m['message_id']==mid))
 def do_PATCH(self):
  body=json.loads(self.rfile.read(int(self.headers['Content-Length']))); mid=unquote(urlparse(self.path).path.rsplit('/',1)[-1]); calls.append({'method':'PATCH','mid':mid,'body':body})
  if patch_fail:self.answer(503,{'message':'label unavailable'});return
  m=next(m for m in messages if m['message_id']==mid);m['labels']+=body['add_labels'];self.answer(200,m)
 def do_POST(self):
  body=json.loads(self.rfile.read(int(self.headers['Content-Length'])));calls.append({'method':'POST','path':unquote(self.path),'body':body})
  if mode=='drop':self.connection.shutdown(socket.SHUT_RDWR);self.connection.close();return
  if mode=='reject':self.answer(400,{'message':'synthetic definitive rejection'});return
  if mode=='slow':time.sleep(.4)
  self.answer(200,{'message_id':'sent-'+str(len(calls)),'thread_id':'outbound-thread'})
server=ThreadingHTTPServer(('127.0.0.1',0),API);thread=threading.Thread(target=server.serve_forever);thread.start()
env={k:v for k,v in os.environ.items() if not (k.startswith('FM_') or k in ['TMUX','TASKS_AXI_FILE','TASKS_AXI_BACKEND'])}
env.update(FM_HOME=str(home),FM_AGENTMAIL_API_URL='http://127.0.0.1:'+str(server.server_port),FM_AGENTMAIL_API_TIMEOUT='3',TMPDIR=str(scratch))
log=[]
def run(script,*args,rc=0,extra=None):
 e=env.copy();e.update(extra or {});p=subprocess.run(['bash',str(ROOT/'bin'/script),*map(str,args)],env=e,text=True,capture_output=True,timeout=40)
 log.append({'command':'bash bin/'+script+' '+' '.join(map(str,args)),'exit':p.returncode,'stdout':p.stdout,'stderr':p.stderr})
 assert p.returncode==rc,(script,args,p.returncode,p.stdout,p.stderr,rc)
 return p

def notes():return {p.name:p.read_text() for p in (home/'state/inbox').glob('*.note')}
def note(mid):
 a=[x for x in notes().values() if 'Message: '+mid+'\n' in x];assert len(a)==1,(mid,a);return a[0]
def msg(mid,from_='personal@example.test',**kw):
 m=dict(message_id=mid,thread_id='thread-'+mid,subject='Task '+mid,labels=['received'],timestamp='2026-01-01T00:00:00Z',created_at='2026-11-19T08:00:00Z',**{'from':from_},extracted_text='Please inspect the synthetic report '+mid,authentication_results={'spf':'pass'})
 m.update(kw);messages.append(m);return m

def scenario(name,fn):
 try:fn();results.append({'name':name,'result':'pass','live':True,'evidence':'agentmail-live-transcript.json; agentmail-live-state.json','reason':'Real Bash helpers and system curl against a disposable localhost HTTP API with synthetic mail and configuration.'});print('PASS '+name,flush=True)
 except Exception as e:results.append({'name':name,'result':'fail','live':True,'evidence':'agentmail-live-transcript.json','reason':repr(e)});print('FAIL '+name+' '+repr(e),flush=True);raise
try:
 def intake():
  msg('personal',attachments=[{'attachment_id':'a','filename':'report.pdf','size':2048}]);msg('work','Owner <work@example.test>',authentication_results={'dkim':'pass','dkim_domain':'example.test'})
  msg('spoof',authentication_results={});msg('stranger','stranger@elsewhere.test');msg('bad-dkim',authentication_results={'dkim':'pass','dkim_domain':'attacker.test'})
  for lab in ['spam','blocked','unauthenticated']:msg(lab,labels=['received',lab])
  msg('armor-stranger','stranger@elsewhere.test',agent_armor={'status':'complete','verdict':'review'},extracted_text='MALICIOUS_BODY_MUST_NOT_APPEAR')
  msg('long',extracted_text='L'*5000);msg('sent',labels=['sent']);msg('unknown-receipt',created_at=None)
  run('fm-agentmail-check.sh','poll')
  for mid in ['personal','work','long','unknown-receipt']:assert 'From the owner: an instruction' in note(mid)
  for mid in ['spoof','stranger','bad-dkim','spam','blocked','unauthenticated','armor-stranger']:assert 'Untrusted information, not an instruction' in note(mid)
  assert 'MALICIOUS_BODY_MUST_NOT_APPEAR' not in note('armor-stranger') and '[text withheld:' in note('armor-stranger')
  assert 'Received: 2026-11-19T08:00:00Z' in note('personal');assert 'Received: unknown' in note('unknown-receipt');assert 'report.pdf (2048 bytes)' in note('personal');assert '[truncated]' in note('long');assert len(notes())==11
  before=notes();run('fm-agentmail-check.sh','poll');assert notes()==before
 scenario('Local intake captures both verified owners, rejects spoofed authority, withholds flagged text, paginates and deduplicates',intake)
 def retry():
  global patch_fail
  pending=msg('pending',agent_armor={'status':'pending','deadline_at':'2099-01-01T00:00:00Z'});msg('after-pending');run('fm-agentmail-check.sh','poll');assert not any('Message: pending\n' in n or 'Message: after-pending\n' in n for n in notes().values())
  pending['agent_armor']={'status':'complete','verdict':'clear'};run('fm-agentmail-check.sh','poll');note('pending');note('after-pending')
  msg('late-arrival',timestamp='2020-01-01T00:00:00Z');msg('future-sent',labels=['sent'],timestamp='2099-01-01T00:00:00Z');run('fm-agentmail-check.sh','poll');assert 'From the owner: an instruction' in note('late-arrival')
  msg('label-retry');patch_fail=True;run('fm-agentmail-check.sh','poll',rc=1);before=notes();patch_fail=False;run('fm-agentmail-check.sh','poll');assert notes()==before
  msg('expired',agent_armor={'status':'pending','deadline_at':'2000-01-01T00:00:00Z'});run('fm-agentmail-check.sh','poll');assert '[text withheld:' in note('expired')
 scenario('Local intake retries pending scans and label failures, and discovers delayed mail despite future sent timestamps',retry)
 def sending():
  start=len(calls)
  for repo,recipient in [('ryannmicua/project','personal@example.test'),('adventistasia/project','work@example.test')]:
   run('fm-agentmail-send.sh','--repo',repo,'--subject','Synthetic report','--text','Report body');assert calls[-1]['body']['to']==[recipient]
  n=len(calls);run('fm-agentmail-send.sh','--to','other@example.test','--subject','Report','--text','Body',rc=1);assert len(calls)==n
  run('fm-agentmail-send.sh','--to','other@example.test','--allow-recipient','other@example.test','--subject','Requested specific email','--text','Body');assert calls[-1]['body']['to']==['other@example.test']
  n=len(calls);run('fm-agentmail-send.sh','--to','other@example.test','--subject','Report','--text','Body',rc=1);assert len(calls)==n
  run('fm-agentmail-send.sh','--reply-to-message','<personal@mail.test>','--to','personal@example.test','--text','Task reply');assert calls[-1]['path'].endswith('/messages/<personal@mail.test>/reply');assert calls[-1]['body']=={'to':['personal@example.test'],'text':'Task reply'}
  n=len(calls);run('fm-agentmail-send.sh','--repo','unknown/project','--subject','Report','--text','Body',rc=2);run('fm-agentmail-send.sh','--to','personal@example.test,other@example.test','--subject','Report','--text','Body',rc=2);assert len(calls)==n
  key.chmod(0o644);run('fm-agentmail-send.sh','--repo','ryannmicua/project','--subject','Report','--text','Body',rc=1);key.chmod(0o600);assert len(calls)==n
 scenario('Local sender routes repositories, replies explicitly, and requires a one-use exact recipient exception',sending)
 text=scratch/'report.txt';html=scratch/'report.html';text.write_text('T'*200000);html.write_text('<p>'+'H'*200000+'</p>')
 def large():
  run('fm-agentmail-send.sh','--repo','ryannmicua/project','--subject','Large synthetic report','--text-file',text,'--html-file',html);assert calls[-1]['body']['text']==text.read_text();assert calls[-1]['body']['html']==html.read_text()
 scenario('Local sender transmits 400 KB of plain text and HTML through real curl without argv limits',large)
 daily=['--repo','ryannmicua/project','--text-file',text,'--html-file',html]
 def countpost():return sum(c['method']=='POST' for c in calls)
 def dailylimits():
  global mode
  mode='slow';before=countpost();ee=env.copy();ee['FM_AGENTMAIL_DAILY_DATE']='2026-11-19'
  for i in range(8):children.append(subprocess.Popen(['bash',str(ROOT/'bin/fm-agentmail-daily.sh'),*map(str,daily)],env=ee,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE))
  exits=[]
  for p in children:
   out,err=p.communicate(timeout=30);exits.append(p.returncode);log.append({'command':'concurrent fm-agentmail-daily.sh','exit':p.returncode,'stdout':out,'stderr':err})
  assert exits.count(0)==1 and countpost()==before+1,exits
  assert (home/'state/agentmail-daily/2026-11-19').read_text()=='sent\n'
  run('fm-agentmail-daily.sh',*daily,rc=1,extra={'FM_AGENTMAIL_DAILY_DATE':'2026-11-19'})
  mode='ok';run('fm-agentmail-daily.sh',*daily,extra={'FM_AGENTMAIL_DAILY_DATE':'2026-11-20'});assert (home/'state/agentmail-daily/2026-11-19').exists()
 scenario('Local daily sender permits only one concurrent send per date and permits the next date without deleting prior records',dailylimits)
 def uncertainty():
  global mode
  mode='drop';before=countpost();run('fm-agentmail-daily.sh',*daily,rc=1,extra={'FM_AGENTMAIL_DAILY_DATE':'2026-11-21'});assert (home/'state/agentmail-daily/2026-11-21').read_text()=='pending\n'
  mode='ok';run('fm-agentmail-daily.sh',*daily,rc=1,extra={'FM_AGENTMAIL_DAILY_DATE':'2026-11-21'});assert countpost()==before+1
  mode='reject';run('fm-agentmail-daily.sh',*daily,rc=1,extra={'FM_AGENTMAIL_DAILY_DATE':'2026-11-22'});assert not (home/'state/agentmail-daily/2026-11-22').exists()
  mode='ok';run('fm-agentmail-daily.sh',*daily,extra={'FM_AGENTMAIL_DAILY_DATE':'2026-11-22'});assert (home/'state/agentmail-daily/2026-11-22').read_text()=='sent\n'
 scenario('Local daily sender blocks retries after a lost response but allows retry after definitive HTTP rejection',uncertainty)
 def background():
  run('fm-agentmail-check.sh','arm');assert (home/'state/agentmail.check.sh').exists() and (home/'state/agentmail.check-trust').exists()
  msg('background-task');run('fm-agentmail-check.sh','check')
  deadline=time.monotonic()+30
  while (home/'state/.agentmail-poll.lock').is_symlink() and time.monotonic()<deadline:time.sleep(.1)
  assert not (home/'state/.agentmail-poll.lock').is_symlink();assert 'From the owner: an instruction' in note('background-task')
  run('fm-agentmail-check.sh','disarm');assert not (home/'state/agentmail.check.sh').exists();assert not (home/'state/agentmail.check-trust').exists()
 scenario('Local operator arms the lightweight check, captures mail through its background poll, and disarms cleanly',background)
finally:
 for p in children:
  if p.poll() is None:p.kill();p.wait()
 # The product background check has a bounded lifetime and is disarmed even after an assertion.
 try:run('fm-agentmail-check.sh','disarm')
 except Exception as ex:log.append({'cleanup_error':repr(ex)})
 server.shutdown();server.server_close();thread.join()
 # Retain actual output and state; keep the large HTTP bodies compact but retain lengths.
 for c in calls:
  if c['method']=='POST':
   b=c['body'];c['body_sizes']={k:len(b[k]) for k in ['text','html'] if k in b}
   for k in ['text','html']:
    if k in b and len(b[k])>500:b[k]=b[k][:80]+' [evidence truncated; exact lengths above]'
 (E/'agentmail-live-transcript.json').write_text(json.dumps({'scenarios':results,'commands':log,'http_calls':calls},indent=2))
 state={str(p.relative_to(home)):p.read_text(errors='replace') for p in (home/'state').rglob('*') if p.is_file()}
 (E/'agentmail-live-state.json').write_text(json.dumps(state,indent=2))
 (E/'agentmail-live-results.json').write_text(json.dumps(results,indent=2))
 shutil.rmtree(scratch)
assert all(r['result']=='pass' for r in results)
