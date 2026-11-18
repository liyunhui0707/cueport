"""Isolated native startup-preference regression; requires logged-in macOS.

Uses a unique clone/bundle ID, its own preference domain and private synthetic
data. Never changes real app preferences, calls terminal APIs or runs a model.
"""
import json, os, pathlib, plistlib, shutil, signal, subprocess, time, uuid
def interrupted(signum, frame): raise SystemExit('Owned startup check interrupted')
signal.signal(signal.SIGTERM, interrupted)
R=pathlib.Path(__file__).resolve().parent.parent
B=R/'build/poc/startup169'; B.mkdir(parents=True,exist_ok=True)
W=B/('native-'+uuid.uuid4().hex); W.mkdir(mode=0o700)
APP=W/'StartupCheck.app'; shutil.copytree(pathlib.Path(os.environ.get('AAR_REVIEW_APP',str(R/'build/artifacts.noindex/Cueport.app'))),APP)
ID='org.agentattentionrouter.startup-check.'+uuid.uuid4().hex
P=APP/'Contents/Info.plist'; info=plistlib.loads(P.read_bytes());info['CFBundleIdentifier']=ID;info['CFBundleDisplayName']='Cueport Startup Check';info['AARBuildChannel']='daily';info['AARValidationBuild']=True;P.write_bytes(plistlib.dumps(info))
subprocess.run(['/usr/bin/codesign','--force','--sign','-','--identifier',ID,str(APP)],check=True,capture_output=True)
D=W/'data';D.mkdir(mode=0o700); stat=D.stat()
profile={'schema':1,'rootPath':str(D),'device':stat.st_dev,'inode':stat.st_ino}
encoded=json.dumps(profile).encode(); key='rememberedBridgeStartup.v1'
subprocess.run(['/usr/bin/defaults','write',ID,key,'-data',encoded.hex()],check=True,capture_output=True)
native_key='nativeCodexExecutable.v1'
native_encoded=json.dumps({'schema':1,'path':"/synthetic/native's/$(literal)/codex"}).encode()
subprocess.run(['/usr/bin/defaults','write',ID,native_key,'-data',native_encoded.hex()],check=True,capture_output=True)
E=APP/'Contents/MacOS/CueportApp'; child=None; log=(W/'app.log').open('wb')
def start(args,root,mode,restored):
 global child
 child=subprocess.Popen([str(E),*args,'--no-notifications'],stdout=log,stderr=log)
 end=time.monotonic()+20
 while time.monotonic()<end:
  assert child.poll() is None,'Owned app exited'
  try:
   h=json.loads((root/'runtime-health.json').read_text())
   if h['pid']==child.pid:
    assert h['monitoring']=='ready' and h['connectionMode']==mode and h['restoredStartup']==restored
    return h
  except (FileNotFoundError,json.JSONDecodeError):pass
  time.sleep(.05)
 raise AssertionError('No matching owned runtime report')
def stop():
 global child
 if child and child.poll() is None:
  child.terminate();child.wait(timeout=5)
 child=None
try:
 h=start([],D,'bridge',True)
 assert h['nativeDependencyChoice']=='custom'
 # A second plain launch must reuse the existing receiver, without a second
 # root consumer or status item. Explicit isolated launches remain independent.
 duplicate=subprocess.run([str(E),'--no-notifications'],stdout=log,stderr=log,timeout=10)
 assert duplicate.returncode==0 and child.poll() is None
 assert json.loads((D/'runtime-health.json').read_text())['pid']==child.pid
 payload={'hook_event_name':'UserPromptSubmit','session_id':'synthetic-startup','turn_id':'synthetic-turn','cwd':'/synthetic/project','prompt':'Synthetic private input'}
 subprocess.run([str(E.with_name('aar')),'hook','--data-dir',str(D)],input=json.dumps(payload).encode(),check=True,capture_output=True)
 end=time.monotonic()+10
 while not (D/'state.json').exists() and time.monotonic()<end:time.sleep(.05)
 snapshot=(D/'state.json').read_bytes();assert b'Synthetic private input' not in snapshot
 stop();h=start([],D,'bridge',True)
 assert h['nativeDependencyChoice']=='custom'
 assert (D/'state.json').read_bytes()==snapshot
 stop();other=W/'explicit';h=start(['--data-dir',str(other)],other,'ordinary',False)
 assert h['nativeDependencyChoice']=='default'
 assert (D/'state.json').read_bytes()==snapshot
 stop()
 # The explicit launch must not rewrite the saved app preference.
 persisted=plistlib.loads(subprocess.check_output(['/usr/bin/defaults','export',ID,'-']))
 assert persisted[key]==encoded
 assert persisted[native_key]==native_encoded
 subprocess.run(['/usr/bin/defaults','write',ID,native_key,'-data',b'not-json'.hex()],check=True,capture_output=True)
 h=start([],D,'bridge',True)
 assert h['nativeDependencyChoice']=='unreadable' and (D/'state.json').read_bytes()==snapshot
 stop()
 result={'native_plain_reopen_restored_saved_bridge':True,'duplicate_plain_receiver_exited':True,'same_data_preserved':True,'explicit_directory_isolated':True,'explicit_launch_preserved_saved_preference':True,'native_choice_restored_on_plain_reopen':True,'isolated_launch_did_not_inherit_native_choice':True,'corrupt_native_choice_visible_without_blocking_monitoring_or_resetting_data':True,'real_app_preferences_modified':False,'notifications':'disabled','terminal_api':'not called','model_tasks':0,'working_directory':W.name}
 (B/'native-results.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2))
finally:
 stop();log.close()
 subprocess.run(['/usr/bin/defaults','delete',ID],capture_output=True)
