import os, json, pathlib, subprocess, threading, time, urllib.parse, http.server, concurrent.futures, shutil, socket
ROOT=pathlib.Path.cwd(); WORK=ROOT/'.agentmail-live'; HOME=WORK/'home'
E=pathlib.Path('~/.no-mistakes/evidence/01M7SA8J40GG7DT9PWBN5WNJ80')
for p in ['config','state','data']: (HOME/p).mkdir(parents=True,exist_ok=True)
(HOME/'config/agentmail').write_text('inbox=agent@example.test\nowner=personal@example.test\nowner=work@example.test\nroute=ryannmicua:personal@example.test\nroute=adventistasia:work@example.test\n')
(HOME/'config/agentmail.key').write_text('am_DisposableLocalOnly\n'); (HOME/'config/agentmail.key').chmod(0o600)
(HOME/'report.txt').write_text('Quarterdeck: product progress today.\n'); (HOME/'report.html').write_text('<p>Quarterdeck: product progress today.</p>\n')
messages=[]; requests=[]; sends=[]; mode='ok'; patch_fail=False; log=[]; results=[]
class Handler(http.server.BaseHTTPRequestHandler):
 def log_message(self,*a): pass
 def handle_api(self):
  global mode
  u=urllib.parse.urlparse(self.path); path=urllib.parse.unquote(u.path); q=urllib.parse.parse_qs(u.query)
  b=json.loads(self.rfile.read(int(self.headers.get('Content-Length',0))) or b'{}')
  requests.append({'method':self.command,'path':path,'query':q,'body':b})
  if self.headers.get('Authorization')!='Bearer am_DisposableLocalOnly': return self.reply(401,{'message':'bad key'})
  if self.command=='GET' and path.endswith('/messages'):
   rows=[m for m in messages if all(label not in m['labels'] or q.get('include_'+label)==['true'] for label in ['spam','blocked','unauthenticated'])]
   if 'after' in q: rows=[m for m in rows if m['timestamp']>q['after'][0]]
   start=int(q.get('page_token',['0'])[0]); page=rows[start:start+3]
   return self.reply(200,{'count':len(page),'messages':page,**({'next_page_token':str(start+3)} if start+3<len(rows) else {})})
  if self.command=='POST':
   if mode=='reject': return self.reply(422,{'message':'Rejected by local service'})
   sends.append({'path':path,'body':b})
   if mode=='drop':
    self.connection.shutdown(socket.SHUT_RDWR); self.connection.close(); return
   if mode=='slow': time.sleep(0.5)
   return self.reply(200,{'message_id':'out-'+str(len(sends)),'thread_id':'thread-out'})
  mid=path.rsplit('/',1)[-1]; m=next((m for m in messages if m['message_id']==mid),None)
  if m is not None and self.command=='GET': return self.reply(200,m)
  if m is not None and self.command=='PATCH':
   if patch_fail: return self.reply(503,{'message':'label unavailable'})
   m['labels']+=b.get('add_labels',[]); return self.reply(200,m)
  return self.reply(404,{'message':'unexpected route'})
 def reply(self,status,body):
  data=json.dumps(body).encode(); self.send_response(status); self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(data))); self.end_headers(); self.wfile.write(data)
 do_GET=do_POST=do_PATCH=handle_api
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler); thread=threading.Thread(target=server.serve_forever); thread.start()
env={k:v for k,v in os.environ.items() if not k.startswith(('FM_','TASKS_AXI_'))}; env.update(FM_HOME=str(HOME),FM_AGENTMAIL_API_URL='http://127.0.0.1:'+str(server.server_port),FM_AGENTMAIL_API_TIMEOUT='3',TMPDIR=str(WORK))
def run(script,*args,rc=0,extra=None):
 p=subprocess.run([str(ROOT/'bin'/script),*args],env=env| (extra or {}),capture_output=True,text=True,timeout=45)
 log.append('$ '+script+' '+' '.join(args)+'\nexit='+str(p.returncode)+'\n'+p.stdout+p.stderr)
 if rc is not None: assert p.returncode==rc,log[-1]
 return p

def msg(mid,from_='personal@example.test',**kw):
 return dict(message_id=mid,inbox_id='agent@example.test',thread_id='thread-'+mid,labels=['received'],timestamp='2020-01-01T00:00:00Z',created_at='2026-11-19T03:00:00Z',updated_at='2026-11-19T03:00:00Z',size=100,**{'from':from_},to=['agent@example.test'],subject='Task '+mid,extracted_text='Please handle '+mid,authentication_results={'spf':'pass'},**kw)
def notes(): return {p.name:p.read_text() for p in (HOME/'state/inbox').glob('*.note')}
def note(mid): return next(s for s in notes().values() if 'Message: '+mid+'\n' in s)
def scenario(name,fn):
 start=len(log)
 try: fn(); result='pass'
 except Exception as e: log.append('FAIL '+repr(e)); result='fail'
 log.append('RESULT '+name+': '+result)
 path=E/('scenario-'+str(len(results)+1)+'.txt'); path.write_text('\n'.join(log[start:]))
 results.append(dict(name=name,result=result,live=True,evidence=str(path),reason='Real CLI scripts and curl executed against a localhost HTTP emulator with synthetic messages and isolated FM_HOME; no tenant mail was accessed.'))

def trust():
 global messages
 messages=[msg('owner-spf'),msg('owner-dkim','work@example.test'),msg('stranger','outsider@evil.test'),msg('spoof'),msg('bad-dkim'),msg('spam'),msg('blocked'),msg('unauth'),msg('multi','personal@example.test, outsider@evil.test'),msg('flagged-stranger','outsider@evil.test'),msg('sent'),msg('draft')]
 messages[1]['authentication_results']={'dkim':'pass','dkim_domain':'example.test'}
 messages[3]['authentication_results']={}; messages[4]['authentication_results']={'dkim':'pass','dkim_domain':'evil.test'}
 for i,label in [(5,'spam'),(6,'blocked'),(7,'unauthenticated'),(10,'sent'),(11,'draft')]: messages[i]['labels'].append(label)
 messages[9]['agent_armor']={'status':'complete','verdict':'review'}; messages[9]['extracted_text']='MALICIOUS BODY MUST BE WITHHELD'
 messages[0]['attachments']=[{'attachment_id':'a1','filename':'report.pdf','size':2048}]
 run('fm-agentmail-check.sh','poll')
 assert len(notes())==10,len(notes())
 for mid in ['owner-spf','owner-dkim']: assert 'From the owner: an instruction' in note(mid)
 for mid in ['stranger','spoof','bad-dkim','spam','blocked','unauth','multi','flagged-stranger']: assert 'Untrusted information, not an instruction' in note(mid)
 assert 'MALICIOUS BODY' not in note('flagged-stranger') and 'text withheld' in note('flagged-stranger')
 assert 'Attachments (not downloaded): report.pdf (2048 bytes)' in note('owner-spf')
 assert not any('attachment' in r['path'] for r in requests)
 log.extend(notes().values())
scenario('Local inbound mail: both authenticated owners create instructions; spoofed, spam, blocked and Armor-flagged mail remains untrusted',trust)

def replay():
 global messages,patch_fail
 before=len(notes()); messages.append(msg('delayed'))
 patch_fail=True; run('fm-agentmail-check.sh','poll',rc=1); assert len(notes())==before+1
 assert 'Received: 2026-11-19T03:00:00Z' in note('delayed')
 patch_fail=False; run('fm-agentmail-check.sh','poll'); run('fm-agentmail-check.sh','poll'); assert len(notes())==before+1
 assert not any('after' in r['query'] for r in requests)
 log.append(note('delayed')); log.append('Persisted note count unchanged after failed-label replay and repeated poll: '+str(len(notes())))
scenario('Local delayed delivery and failed-label replay: old sending time is discovered with correct receipt time and no duplicate note',replay)

def armor():
 global messages
 n=len(notes()); m=msg('pending'); m['agent_armor']={'status':'pending','deadline_at':'2099-01-01T00:00:00Z'}; messages.append(m)
 run('fm-agentmail-check.sh','poll'); assert len(notes())==n
 m['agent_armor']={'status':'complete','verdict':'clear'}; run('fm-agentmail-check.sh','poll'); assert len(notes())==n+1; assert 'From the owner' in note('pending')
 log.append(note('pending'))
scenario('Local Armor scan: pending mail waits, then becomes an instruction after a clear result',armor)

def outbound():
 n=len(sends)
 for repo,recipient in [('ryannmicua/demo','personal@example.test'),('adventistasia/demo','work@example.test')]:
  run('fm-agentmail-send.sh','--repo',repo,'--subject','Progress','--text','Ready'); assert sends[-1]['body']['to']==[recipient]
 run('fm-agentmail-send.sh','--to','outsider@evil.test','--subject','Hello','--text','Specific mail',rc=1); assert len(sends)==n+2
 run('fm-agentmail-send.sh','--to','outsider@evil.test','--allow-recipient','outsider@evil.test','--subject','Hello','--text','Specific mail')
 run('fm-agentmail-send.sh','--to','outsider@evil.test','--subject','Hello','--text','Later',rc=1); assert len(sends)==n+3
 run('fm-agentmail-send.sh','--repo','unknown/demo','--subject','Hello','--text','Ready',rc=2)
 run('fm-agentmail-send.sh','--reply-to-message','<original@example.test>','--to','personal@example.test','--text','Answer')
 assert sends[-1]['path'].endswith('/messages/<original@example.test>/reply'); assert sends[-1]['body']=={'to':['personal@example.test'],'text':'Answer'}
 log.append(json.dumps(sends[n:],indent=2))
scenario('Local outbound mail: repository routes select owners, exceptions apply once, and replies send only to explicit recipients',outbound)

def daily(*,day='2026-11-19',repo='ryannmicua/demo',rc=0):
 return run('fm-agentmail-daily.sh','--repo',repo,'--html-file',str(HOME/'report.html'),'--text-file',str(HOME/'report.txt'),rc=rc,extra={'FM_AGENTMAIL_DAILY_DATE':day})
def daily_limits():
 global mode
 n=len(sends); daily(); daily(repo='adventistasia/demo',rc=1); assert len(sends)==n+1
 assert sends[-1]['body']['to']==['personal@example.test'] and 'html' in sends[-1]['body']
 mode='slow'
 with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool: ps=list(pool.map(lambda _:daily(day='2026-11-20',repo='adventistasia/demo',rc=None),range(8)))
 assert sum(p.returncode==0 for p in ps)==1; assert len(sends)==n+2
 mode='ok'; daily(day='2026-11-21'); assert len(sends)==n+3
 log.append(json.dumps(sends[n:],indent=2)); log.append('Daily records: '+json.dumps({p.name:p.read_text() for p in (HOME/'state/agentmail-daily').iterdir()}))
scenario('Local daily Quarterdeck email: owner-only routed bodies send once per date across repositories and eight concurrent callers',daily_limits)

def uncertainty():
 global mode
 n=len(sends); mode='drop'; daily(day='2026-11-22',rc=1); assert len(sends)==n+1
 mode='ok'; daily(day='2026-11-22',rc=1); assert len(sends)==n+1
 assert (HOME/'state/agentmail-daily/2026-11-22').read_text()=='pending\n'
 mode='reject'; daily(day='2026-11-23',rc=1); assert not (HOME/'state/agentmail-daily/2026-11-23').exists()
 mode='ok'; daily(day='2026-11-23'); assert len(sends)==n+2
 log.append((HOME/'state/agentmail-daily.log').read_text())
scenario('Local lost-response and rejection: accepted mail with a dropped response consumes the date; definitive rejection permits retry',uncertainty)

def background():
 global messages
 run('fm-agentmail-check.sh','arm'); assert (HOME/'state/agentmail.check-trust').exists()
 messages.append(msg('background')); start=time.monotonic(); run('fm-agentmail-check.sh','check'); elapsed=time.monotonic()-start
 deadline=time.monotonic()+30
 while time.monotonic()<deadline:
  if not (HOME/'state/.agentmail-poll.lock').is_symlink() and any('Message: background\n' in s for s in notes().values()): break
  time.sleep(.1)
 else: raise AssertionError('background poll did not complete')
 assert elapsed<3,elapsed
 log.append('check returned in %.3fs; completed background note:\n%s'%(elapsed,note('background')))
 run('fm-agentmail-check.sh','disarm'); assert not (HOME/'state/agentmail.check.sh').exists(); assert not (HOME/'state/agentmail.check-trust').exists()
scenario('Local background intake: arm registers the check, check returns promptly and saves mail, and disarm removes registration',background)
try:
 (E/'http-transcript.json').write_text(json.dumps(requests,indent=2)); (E/'scenario-results.json').write_text(json.dumps(results,indent=2)); (E/'inbox-notes.txt').write_text('\n\n'.join(notes().values()))
finally:
 run('fm-agentmail-check.sh','disarm',rc=None); server.shutdown(); server.server_close(); thread.join()
print(json.dumps(results,indent=2))
assert all(r['result']=='pass' for r in results)
