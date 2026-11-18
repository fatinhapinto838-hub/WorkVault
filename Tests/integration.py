#!/usr/bin/env python3
"""Actual compiled HTTP + SQLite + files integration tests. No account mocks."""
import collections, hashlib, http.client, http.cookiejar, json, os, pathlib, shutil, sqlite3, subprocess, sys, time, unittest, urllib.error, urllib.parse, urllib.request, zipfile
BASE=pathlib.Path(__file__).resolve().parents[1]
RUN=pathlib.Path(os.environ.get('WORKVAULT_TEST_DIR', str(BASE.parents[1]/'work'/'integration-runtime'))).resolve()
BINARY=BASE/'dist/WorkVault.app/Contents/MacOS/WorkVault'
RESULTS=[]
class Vault:
 def __init__(self,root):
  self.root=root;self.ready=RUN/(root.name+'-ready.json');self.log=open(RUN/(root.name+'.log'),'w')
  self.proc=subprocess.Popen([str(BINARY),'--headless','--root',str(root),'--web',str(BASE/'Web'),'--ready-file',str(self.ready)],stdout=self.log,stderr=self.log)
  for _ in range(300):
   if self.ready.exists():break
   if self.proc.poll() is not None:raise RuntimeError('App exited: '+(RUN/(root.name+'.log')).read_text())
   time.sleep(.1)
  else:raise RuntimeError('No ready file')
  self.url=json.loads(self.ready.read_text())['url'];self.origin=self.url.split('/?')[0]
  jar=http.cookiejar.CookieJar();self.client=urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar));self.client.open(self.url).read()
 def rpc(self,action,**p):
  r=urllib.request.Request(self.origin+'/api/rpc',json.dumps(dict(action=action,**p)).encode(),{'Content-Type':'application/json','Origin':self.origin})
  try:return json.load(self.client.open(r,timeout=180))
  except urllib.error.HTTPError as e:raise RuntimeError(json.load(e).get('error',str(e)))
 def close(self):
  if self.proc.poll() is None:
   self.proc.terminate()
   try:self.proc.wait(10)
   except subprocess.TimeoutExpired:self.proc.kill();self.proc.wait()
  self.log.close()
class TestWorkVault(unittest.TestCase):
 @classmethod
 def setUpClass(cls):
  if RUN.exists():shutil.rmtree(RUN)
  RUN.mkdir(parents=True);cls.fixtures=RUN/'fixtures';cls.fixtures.mkdir();cls.v=Vault(RUN/'library')
  (cls.fixtures/'report.txt').write_text('CCUS geological carbon storage. Porosity 0.18.\n石油工程实验结果。',encoding='utf-8')
  (cls.fixtures/'table.csv').write_text('sample,porosity\nA,0.18\nB,0.22\n')
  (cls.fixtures/'code.py').write_text('print("WorkVault test")\n')
  (cls.fixtures/'note.md').write_text('# CCUS\n\n**Research** <script>alert(1)</script>\n')
  (cls.fixtures/'data.json').write_text('{"ccus":true}')
  (cls.fixtures/'unknown.xyz').write_bytes(b'unknown\x00format')
  # Valid tiny PDF with text; byte offsets computed rather than simulated API.
  objs=[b'<< /Type /Catalog /Pages 2 0 R >>',b'<< /Type /Pages /Kids [3 0 R] /Count 1 >>',b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 400] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>',b'<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>']
  stream=b'BT /F1 20 Tf 40 320 Td (CCUS test porosity 0.18) Tj ET';objs.append(b'<< /Length '+str(len(stream)).encode()+b' >>\nstream\n'+stream+b'\nendstream')
  pdf=b'%PDF-1.4\n';offs=[0]
  for i,o in enumerate(objs,1):offs.append(len(pdf));pdf+=str(i).encode()+b' 0 obj\n'+o+b'\nendobj\n'
  xref=len(pdf);pdf+=b'xref\n0 6\n0000000000 65535 f \n'+b''.join(f'{o:010d} 00000 n \n'.encode() for o in offs[1:])+b'trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n'+str(xref).encode()+b'\n%%EOF'
  (cls.fixtures/'test.pdf').write_bytes(pdf)
  for ext,member,text in [('docx','word/document.xml','<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>CCUS Word test</w:t></w:r></w:p></w:body></w:document>'),('xlsx','xl/worksheets/sheet1.xml','<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row><c t="inlineStr"><is><t>CCUS Excel test</t></is></c></row></sheetData></worksheet>'),('pptx','ppt/slides/slide1.xml','<p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><a:t>CCUS PPT test</a:t></p:sld>')]:
   with zipfile.ZipFile(cls.fixtures/('test.'+ext),'w',zipfile.ZIP_DEFLATED) as z:
    z.writestr('[Content_Types].xml','<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"/>');z.writestr(member,text)
  cls.fixture_type='minimal_ooxml'
  try:
   import docx,openpyxl,pptx
   d=docx.Document();d.add_heading('CCUS Word test',0);d.add_paragraph('Porosity 0.18; fixture document.');d.save(cls.fixtures/'test.docx')
   w=openpyxl.Workbook();w.active.append(['CCUS Excel test','porosity']);w.active.append(['A',0.18]);w.save(cls.fixtures/'test.xlsx')
   deck=pptx.Presentation();slide=deck.slides.add_slide(deck.slide_layouts[1]);slide.shapes.title.text='CCUS PPT test';slide.placeholders[1].text='Porosity 0.18; fixture slide.';deck.save(cls.fixtures/'test.pptx')
   cls.fixture_type='real_docx_openpyxl_pythonpptx'
  except ImportError: pass
 @classmethod
 def tearDownClass(cls):cls.v.close()
 def run(self,result=None):
  start=time.perf_counter();super().run(result);RESULTS.append({'name':self.id().split('.')[-1],'seconds':round(time.perf_counter()-start,4)})
 def rpc(self,a,**p):return self.v.rpc(a,**p)
 def new_project(self,title='石油工程真实油田数据复现',**p):return self.rpc('project_save',title=title,**p)['project']
 def add(self,name='report.txt',**p):
  r=self.rpc('import',paths=[str(self.fixtures/name)],**p);self.assertEqual(r['failed'],0);return r['results'][0]
 def test_01_first_launch_setup(self):
  s=self.rpc('status');self.assertEqual(s['files'],0);self.assertEqual(s['projects'],0);self.assertTrue((self.v.root/'workvault.sqlite').exists());self.assertTrue(s['storage_available']);self.assertFalse(s['setup_complete']);self.rpc('setup');self.assertTrue(self.rpc('status')['setup_complete'])
 def test_02_projects_title_conflict_and_manual_override(self):
  a=self.new_project('同名任务');b=self.new_project('同名任务');self.assertNotEqual(a['id'],b['id'])
  c=self.new_project('原始任务',conversation_id='real-fixture-id',title_source='用户提供')
  self.rpc('project_save',id=c['id'],title='我的显示标题')
  d=self.rpc('project_save',title='导出更新标题',original_title='导出更新标题',conversation_id='real-fixture-id',title_source='官方导出')['project']
  self.assertEqual(d['id'],c['id']);self.assertEqual(d['title'],'我的显示标题')
 def test_03_multiformat_import_and_previews(self):
  p=self.new_project('多格式管理')
  for name in ['test.pdf','test.docx','test.xlsx','test.pptx','table.csv','code.py','note.md','data.json','unknown.xyz']:
   f=self.add(name,project_id=p['id'],confirmed=True)['file'];preview=self.rpc('preview',id=f['id']);self.assertIn('kind',preview)
   if name.endswith(('.docx','.xlsx','.pptx')):self.assertIn('CCUS',preview.get('text',''))
   if name=='unknown.xyz':self.assertEqual(preview['kind'],'unsupported')
  self.assertEqual(self.rpc('files',project_id=p['id'])['total'],9)
 def test_04_content_dedup_and_multi_project(self):
  a=self.new_project('去重一');b=self.new_project('去重二');first=self.add(project_id=a['id'],confirmed=True)
  s=self.rpc('status')['bytes'];second=self.add(project_id=b['id'],confirmed=True)
  self.assertTrue(second['duplicate']);self.assertEqual(first['id'],second['id']);self.assertEqual(s,self.rpc('status')['bytes'])
  self.assertTrue(set([a['id'],b['id']]).issubset(set(self.rpc('file_detail',id=first['id'])['file']['project_ids'])))
 def test_05_same_name_different_content(self):
  folder=self.fixtures/'different';folder.mkdir(exist_ok=True);(folder/'report.txt').write_text('completely changed content')
  a=self.add()['id'];b=self.rpc('import',paths=[str(folder/'report.txt')])['results'][0]['id'];self.assertNotEqual(a,b)
 def test_06_unknown_inbox_confirm_trash_restore(self):
  path=self.fixtures/'pending.txt';path.write_text('Pending unique file');f=self.rpc('import',paths=[str(path)])['results'][0]['file'];self.assertEqual(f['status'],'pending');self.assertEqual(f['confidence'],'待确认')
  self.rpc('file_update',ids=[f['id']],status='managed',favorite=True,tags=['CCUS','待核验']);self.assertEqual(self.rpc('file_detail',id=f['id'])['file']['confidence'],'用户确认')
  self.rpc('file_update',ids=[f['id']],status='trash');self.assertEqual(self.rpc('file_detail',id=f['id'])['file']['status'],'trash');self.rpc('file_update',ids=[f['id']],status='managed');self.assertTrue(path.exists())
 def test_07_search_filters_pagination(self):
  self.assertGreater(self.rpc('files',q='多格式管理')['total'],0);self.assertTrue(all(f['ext']=='pdf' for f in self.rpc('files',ext='pdf')['items']))
  self.assertLessEqual(len(self.rpc('files',limit=2)['items']),2);self.assertGreater(self.rpc('files',q='report')['total'],0)
 def test_08_versions_restore_without_loss(self):
  f=self.add(confirmed=True)['id'];old=self.rpc('file_detail',id=f)['versions'][0]['id'];new=self.fixtures/'changed.txt';new.write_text('changed version CCUS')
  self.rpc('version_add',id=f,path=str(new),note='真实更新');d=self.rpc('file_detail',id=f);before=len(d['versions']);self.assertGreaterEqual(before,2)
  self.rpc('version_add',id=f,path=str(new));self.assertEqual(len(self.rpc('file_detail',id=f)['versions']),before)
  self.rpc('version_restore',id=f,version_id=old);self.assertEqual(len(self.rpc('file_detail',id=f)['versions']),before+1)
 def test_09_working_copy_change_detection(self):
  f=self.add('code.py',confirmed=True)['id'];d=self.rpc('file_detail',id=f);working=self.v.root/'working'/f/d['file']['name'];working.parent.mkdir(parents=True,exist_ok=True)
  working.write_text('print("external edited")\n')
  edits=self.rpc('check_edits')['items'];self.assertTrue(any(x['id']==f and x['changed'] for x in edits));self.rpc('commit_edit',id=f,note='external edit fixture');self.assertIn('external edited',self.rpc('preview',id=f)['text'])
 def test_10_project_split_merge(self):
  p=self.new_project('拆分源');f=self.add('table.csv',project_id=p['id'],confirmed=True)['id'];split=self.rpc('project_split',id=p['id'],title='拆分目标',file_ids=[f])['project'];self.assertIn(split['id'],self.rpc('file_detail',id=f)['file']['project_ids']);self.rpc('project_merge',from_id=split['id'],to_id=p['id']);self.assertIn(p['id'],self.rpc('file_detail',id=f)['file']['project_ids'])
 def test_11_official_export_title_and_missing_metadata(self):
  path=self.fixtures/'conversations.json';path.write_text(json.dumps([{'id':'export-conv-1','title':'导出标题','create_time':1700000000,'mapping':{'m':{'message':{'content':{'parts':['sandbox:/mnt/data/missing-report.pdf']},'metadata':{'attachments':[{'file_id':'file-missing','name':'missing-report.pdf'}]}}}}}]))
  r=self.rpc('import_export',path=str(path));self.assertGreaterEqual(r['projects'],1);self.assertGreaterEqual(r['missing_files'],1)
  items=self.rpc('projects')['items'];p=next(x for x in items if x['conversation_id']=='export-conv-1');self.assertEqual(p['original_title'],'导出标题');self.assertIn('确认',p['title_source'])
 def test_12_authorized_watch_stable_pending(self):
  folder=self.fixtures/'watched';folder.mkdir(exist_ok=True);source=self.rpc('source_save',path=str(folder),kind='downloads',enabled=True)['source'];file=folder/'watch.txt';file.write_text('unique watcher file');(folder/'partial.crdownload').write_text('ignore')
  self.rpc('scan');self.rpc('scan');self.rpc('scan');items=self.rpc('files',status='pending',q='watch.txt')['items'];self.assertEqual(len(items),1);self.assertTrue(file.exists());self.assertEqual(self.rpc('files',status='pending',q='partial.crdownload')['total'],0)
  self.rpc('source_save',id=source['id'],path=str(folder),kind='downloads',enabled=False);(folder/'after-disable.txt').write_text('disabled');self.rpc('scan');self.rpc('scan');self.assertEqual(self.rpc('files',status='pending',q='after-disable')['total'],0)
 def test_12b_codex_outputs_watch_new_tasks_and_keep_baseline(self):
  codex=self.fixtures/'codex-root'
  task=codex/'2026-11-17'/'old-task'
  outputs=task/'outputs'
  outputs.mkdir(parents=True)
  old=outputs/'codex-baseline.txt'
  old.write_text('baseline bytes')
  outside=task/'work'
  outside.mkdir()
  ignored=outside/'codex-outside.txt'
  ignored.write_text('private task work fixture')
  source=self.rpc('source_save',path=str(codex),kind='codex_outputs',enabled=True)
  self.assertEqual(source['baseline_count'],1)
  for _ in range(3):self.rpc('scan')
  self.assertEqual(self.rpc('files',status='pending',q='codex-baseline')['total'],0)

  new_task=codex/'2026-11-18'/'new-task'
  new_outputs=new_task/'outputs'
  new_outputs.mkdir(parents=True)
  new=new_outputs/'codex-new-report.txt'
  new.write_text('first write')
  (new_outputs/'codex-link.txt').symlink_to(ignored)
  (new_outputs/'codex-download.partial').write_text('partial download')
  (new_outputs/'node_modules').mkdir()
  (new_outputs/'node_modules'/'codex-dependency.txt').write_text('generated dependency')
  (codex/'other-folder'/'outputs').mkdir(parents=True)
  (codex/'other-folder'/'outputs'/'codex-unscoped.txt').write_text('outside date layout')
  self.rpc('scan')
  new.write_text('completed report')
  old.write_text('baseline changed after authorization')
  self.rpc('scan')
  self.rpc('scan')
  self.assertEqual(self.rpc('files',status='pending',q='codex-new-report')['total'],0)
  result=self.rpc('scan')
  self.assertEqual(result['discovered'],2)
  self.assertEqual(result['errors'],[])
  imported=self.rpc('files',status='pending',q='codex-new-report')['items'][0]
  self.assertEqual(imported['source'],'codex_outputs')
  self.assertEqual(imported['source_path'],str(new))
  self.assertEqual(imported['project_ids'],[])
  self.assertEqual(new.read_text(),'completed report')
  self.assertEqual(self.rpc('files',status='pending',q='codex-')['total'],2)
  self.assertEqual(self.rpc('scan')['discovered'],0)
  source_id=source['source']['id']
  self.rpc('source_save',id=source_id,path=str(codex),kind='codex_outputs',enabled=False)
  (new_outputs/'codex-paused.txt').write_text('file created during pause')
  for _ in range(3):self.rpc('scan')
  self.assertEqual(self.rpc('files',status='pending',q='codex-paused')['total'],0)
  self.rpc('source_save',id=source_id,path=str(codex),kind='codex_outputs',enabled=True)
  for _ in range(3):self.rpc('scan')
  self.assertEqual(self.rpc('files',status='pending',q='codex-paused')['total'],1)
  self.rpc('source_delete',id=source_id)

 def test_13_symlink_and_zip_traversal(self):
  link=self.fixtures/'link.txt';link.symlink_to(self.fixtures/'report.txt')
  with self.assertRaises(RuntimeError):self.rpc('import',paths=[str(link)])
  attack=self.fixtures/'attack.zip'
  with zipfile.ZipFile(attack,'w') as z:z.writestr('../outside.txt','bad')
  with self.assertRaises(RuntimeError):self.rpc('import',paths=[str(attack)])
  self.assertFalse((RUN/'outside.txt').exists())
 def test_14_ai_no_service_and_denied_cloud(self):
  status=self.rpc('ai_status');self.assertIn('ollama_available',status)
  p=self.new_project('隐私项目');f=self.add('report.txt',project_id=p['id'],confirmed=True)['id']
  with self.assertRaisesRegex(RuntimeError,'授权'):self.rpc('ai_prepare',file_ids=[f],provider='deepseek')
  self.assertFalse(any(x['provider']=='deepseek' for x in self.rpc('ai_status')['requests']))
 def test_15_manual_local_index_search_delete(self):
  f=self.add('report.txt',confirmed=True)['id'];job=self.rpc('ai_index',file_ids=[f],embeddings=False)['job_id']
  for _ in range(100):
   state=self.rpc('ai_job',job_id=job)
   if state['status'] in ['completed','failed','cancelled']:break
   time.sleep(.05)
  self.assertEqual(state['status'],'completed',state);self.assertGreater(len(self.rpc('ai_search',q='CCUS')['items']),0)
  self.rpc('ai_delete_index',file_ids=[f]);self.assertEqual(len([x for x in self.rpc('ai_search',q='CCUS')['items'] if x['file_id']==f]),0)
 def test_16_backup_restore_integrity_tamper(self):
  folder=RUN/'backup-output';folder.mkdir(exist_ok=True);r=self.rpc('backup_create',destination=str(folder),include_index=False);backup=pathlib.Path(r['path']);self.assertTrue(self.rpc('backup_inspect',path=str(backup))['valid'])
  dest=RUN/'restored-library';self.rpc('backup_restore',path=str(backup),destination=str(dest),confirmed=True);self.assertTrue((dest/'workvault.sqlite').exists())
  with sqlite3.connect(dest/'workvault.sqlite') as con:self.assertEqual(con.execute('pragma integrity_check').fetchone()[0],'ok')
  self.assertEqual(self.rpc('integrity')['errors'],[])
  db=backup/'workvault.sqlite';db.write_bytes(db.read_bytes()+b'tamper');self.assertFalse(self.rpc('backup_inspect',path=str(backup))['valid'])
  with self.assertRaises(RuntimeError):self.rpc('backup_restore',path=str(backup),destination=str(RUN/'bad-restore'),confirmed=True)
 def test_17_auth_origin_json_and_content(self):
  req=urllib.request.Request(self.v.origin+'/api/rpc',b'{"action":"status"}',{'Content-Type':'application/json'})
  with self.assertRaises(urllib.error.HTTPError) as caught:urllib.request.urlopen(req)
  self.assertEqual(caught.exception.code,401)
  req=urllib.request.Request(self.v.origin+'/api/rpc',b'{"action":"status"}',{'Content-Type':'application/json','Origin':'https://evil.example'})
  with self.assertRaises(urllib.error.HTTPError) as caught:self.v.client.open(req)
  self.assertEqual(caught.exception.code,403)
  f=self.add('test.pdf',confirmed=True)['id'];response=self.v.client.open(self.v.origin+'/content/'+f);self.assertEqual(response.read()[:4],b'%PDF');self.assertEqual(response.headers['Content-Type'],'application/pdf')
  r=self.v.client.open(urllib.request.Request(self.v.origin+'/content/'+f,headers={'Range':'bytes=0-3'}));self.assertEqual(r.status,206);self.assertEqual(r.read(),b'%PDF')
 def test_18_stream_upload(self):
  payload=b'upload streamed fixture unique';request=urllib.request.Request(self.v.origin+'/api/upload?name=upload.txt',payload,{'Content-Type':'application/octet-stream','Origin':self.v.origin});r=json.load(self.v.client.open(request));self.assertEqual(r['file']['size'],len(payload));self.assertEqual(r['file']['status'],'pending')
 def test_18a_dedicated_manifest_real_title(self):
  folder=self.fixtures/'dedicated';folder.mkdir();(folder/'成果.md').write_text('unique manifest outcome CCUS')
  (folder/'task.workvault.json').write_text(json.dumps({'workvault':1,'title':'清单原始 Work 标题','conversation_id':'manifest-conv-1','source_url':'https://chatgpt.com/c/manifest-conv-1','files':['成果.md']},ensure_ascii=False))
  self.rpc('source_save',path=str(folder),kind='dedicated',enabled=True)
  self.rpc('scan');self.rpc('scan');self.rpc('scan')
  p=next(x for x in self.rpc('projects')['items'] if x['conversation_id']=='manifest-conv-1');self.assertEqual(p['original_title'],'清单原始 Work 标题');self.assertEqual(self.rpc('files',project_id=p['id'])['total'],1)
 def test_18b_disk_space_failure_no_partial(self):
  huge=self.fixtures/'huge-sparse.bin'
  with open(huge,'wb') as out:out.truncate(128*1024**3)
  try:
   r=self.rpc('import',paths=[str(huge)]);self.assertEqual(r['failed'],1);self.assertIn('空间',r['results'][0]['error']);self.assertEqual(self.rpc('files',q='huge-sparse',status='pending')['total'],0);self.assertTrue(huge.exists())
  finally:huge.unlink()
 def test_18c_storage_unavailable_preserves_records(self):
  old=self.v.root;offline=old.with_name(old.name+'-disconnected');before=self.rpc('status');old.rename(offline)
  try:
   status=self.rpc('status');self.assertFalse(status['storage_available']);self.assertEqual(status['files'],before['files'])
  finally:offline.rename(old)
  self.assertTrue(self.rpc('status')['storage_available'])
 def test_18d_export_and_future_schema_guard(self):
  f=self.add('table.csv',confirmed=True)['id'];directory=RUN/'exported';directory.mkdir()
  self.rpc('export_file',id=f,destination=str(directory));self.assertEqual((directory/'table.csv').read_bytes(),(self.fixtures/'table.csv').read_bytes())
  with self.assertRaises(RuntimeError):self.rpc('export_file',id=f,destination=str(directory))
  future=RUN/'future-library';future.mkdir()
  with sqlite3.connect(future/'workvault.sqlite') as c:c.execute('pragma user_version=999')
  before=(future/'workvault.sqlite').read_bytes()
  with self.assertRaises(RuntimeError):self.rpc('switch_library',path=str(future))
  self.assertEqual(before,(future/'workvault.sqlite').read_bytes())
 def test_19_migration_failure_success_relaunch(self):
  old=self.v.root;before=self.rpc('status');favorites=self.rpc('files',favorite=True)['items'];versions={f['id']:len(self.rpc('file_detail',id=f['id'])['versions']) for f in favorites};occupied=RUN/'occupied';occupied.mkdir();(occupied/'keep.txt').write_text('keep')
  with self.assertRaises(RuntimeError):self.rpc('migrate',destination=str(occupied))
  self.assertEqual(self.rpc('status')['root'],str(old));self.assertEqual(self.rpc('integrity')['errors'],[])
  target=RUN/'migrated-library';self.rpc('migrate',destination=str(target));self.assertTrue((old/'workvault.sqlite').exists());self.assertEqual(self.rpc('status')['files'],before['files']);self.assertEqual(self.rpc('integrity')['errors'],[])
  self.v.close();self.__class__.v=Vault(target);after=self.rpc('status');self.assertEqual(after['files'],before['files']);self.assertEqual(after['projects'],before['projects']);self.assertEqual(self.rpc('files',favorite=True)['items'],favorites);self.assertEqual({f['id']:len(self.rpc('file_detail',id=f['id'])['versions']) for f in favorites},versions)
 def test_20_shutdown_no_orphan(self):
  pid=self.v.proc.pid;self.rpc('shutdown');self.v.proc.wait(10);self.assertFalse(self.v.ready.exists());self.__class__.v=Vault(RUN/'migrated-library')
if __name__=='__main__':
 suite=unittest.defaultTestLoader.loadTestsFromTestCase(TestWorkVault);result=unittest.TextTestRunner(verbosity=2).run(suite)
 report={'date':'2026-11-17','tests':result.testsRun,'passed':result.testsRun-len(result.failures)-len(result.errors),'failures':[(str(t),e) for t,e in result.failures+result.errors],'timings':RESULTS,'test_root':str(RUN),'fixture_type':getattr(TestWorkVault,'fixture_type','unknown')}
 (BASE/'docs/integration-results.json').write_text(json.dumps(report,ensure_ascii=False,indent=2));sys.exit(not result.wasSuccessful())
