import os,subprocess,hashlib
from pathlib import Path
R=Path.cwd(); D=R/'.test-phase'; C=D/'code'; E=Path('/home/rgm/.no-mistakes/evidence/01M4WGXDNGGQ4VYQ87MTYR9JHP'); log=[]
env={k:v for k,v in os.environ.items() if not (k.startswith('FM_') or k.startswith('GIT_') or k in ('NO_MISTAKES_GATE','TMUX','TMUX_PANE','TASKS_AXI_FILE','TASKS_AXI_BACKEND'))}
env.update(TMPDIR=str(D/'tmp'),GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1')
def run(args,expect=0,cwd=R):
    p=subprocess.run(list(map(str,args)),env=env,cwd=cwd,text=True,capture_output=True,timeout=60); log.append('$ '+' '.join(map(str,args))+'\n'+p.stdout+p.stderr+f'\nexit={p.returncode}\n'); (E/'seed-backlog-live.log').write_text('\n'.join(log)); assert p.returncode==expect,log[-1]; return p.stdout
h=D/'seed-parent'; sub=D/'seed-child'; run(['bin/fm-lab-home.sh','create',h]); env.update(FM_HOME=str(h),FM_ROOT_OVERRIDE=str(C),FM_SECONDMATE_CHARTER='Own the disposable spaced project',FM_SECONDMATE_SCOPE='Disposable testing')
proj=h/'projects/space project'; run(['git','clone','-q',D/'treehouse-project',proj])
(h/'data/projects.md').write_text('## Projects\n- space [local-only] - Neighbor must remain untouched\n- space project [direct-PR +yolo] - Spaced project\n')
run([C/'bin/fm-home-seed.sh','mate',sub,'space project'])
registry=(sub/'data/projects.md').read_text(); assert '- space project [direct-PR +yolo]' in registry and '- space [' not in registry
assert run([C/'bin/fm-project-mode.sh','space project']).strip()=='direct-PR on'
# Give the caller a conflicting tasks backend; explicit markdown must win.
caller=D/'conflicting-caller'; caller.mkdir(); (caller/'.tasks.toml').write_text('backend = "beads"\n')
(h/'data/backlog.md').write_text('## In flight\n\n## Queued\n- [ ] routed - Disposable work (repo: space project) (kind: ship)\n  Body must move intact.\n\n## Done\n')
run([C/'bin/fm-backlog-handoff.sh','mate','routed'],expect=1,cwd=caller)
assert '- [ ] routed ' not in (h/'data/backlog.md').read_text(); assert '  Body must move intact.' in (sub/'data/backlog.md').read_text()
# Remote receiver contract under the same conflicting caller configuration.
q=sub/'state/handoff'; q.mkdir(parents=True,exist_ok=True); payload=b'## In flight\n\n## Queued\n- [ ] received - Remote work (repo: space project) (kind: ship)\n\n## Done\n'; delivered=q/'mate.outbox.md'; delivered.write_bytes(payload); sha=hashlib.sha256(payload).hexdigest(); (q/'.mate.upload-generation').write_text(f'1\n{len(payload)}\n{sha}\n'); env['FM_HOME']=str(sub)
run([C/'bin/fm-backlog-receive.sh','state/handoff/mate.outbox.md',len(payload),sha,'1'],cwd=caller)
assert not delivered.exists() and '- [ ] received ' in (sub/'data/backlog.md').read_text()
(E/'seeded-project-registry.md').write_text(registry); (E/'received-backlog.md').write_text((sub/'data/backlog.md').read_text())
print('Spaced project seeding and markdown handoff/receipt passed under conflicting caller config.')
