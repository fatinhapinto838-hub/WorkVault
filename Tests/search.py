#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Compiled-service regression: keyword searches exclude Markdown, browsing does not."""
import os,pathlib,json,sqlite3,time,hashlib,unittest,subprocess
os.environ['WORKVAULT_TEST_DIR']=str(pathlib.Path(__file__).resolve().parents[3]/'work'/'search-tests')
from integration import Vault,RUN,BASE

class Search(unittest.TestCase):
 @classmethod
 def setUpClass(cls):
  RUN.mkdir(parents=True,exist_ok=True);cls.base=RUN/str(time.time_ns());cls.base.mkdir();cls.v=Vault(cls.base/'library');cls.v.rpc('setup')
  cls.a=cls.v.rpc('project_save',title='CCUS SearchScope mixed project')['project']['id']
  cls.b=cls.v.rpc('project_save',title='OnlyNotes ProjectScope')['project']['id']
  cls.alias=cls.v.rpc('project_save',title='Alias Boundary')['project']['id']
  paths=[]
  for n in range(70):
   p=cls.base/f'CCUS-Notes-{n:02}.md';p.write_text(f'# isolated note {n}\n');paths.append(str(p))
  for name,body in [('CCUS-report.txt','report plain'),('CCUS-table.csv','a,b\n1,2'),('CCUS-data.json','{"fixture":true}')]:
   p=cls.base/name;p.write_text(body);paths.append(str(p))
  imported=cls.v.rpc('import',paths=paths,project_id=cls.a,confirmed=True)['results'];cls.aids=[f['id'] for f in imported]
  cls.v.rpc('deliverable_set',project_id=cls.a,file_ids=cls.aids)
  paths=[]
  for ext in ['MD','MARKDOWN']:
   p=cls.base/('MarkdownOnlyXYZ.'+ext);p.write_text('# '+ext+' isolated');paths.append(str(p))
  notes=cls.v.rpc('import',paths=paths,project_id=cls.b,confirmed=True)['results'];cls.bids=[f['id'] for f in notes];cls.v.rpc('deliverable_set',project_id=cls.b,file_ids=cls.bids)
  p=cls.base/'AliasUnique.MD';p.write_text('# alias boundary isolated');f=cls.v.rpc('import',paths=[str(p)],project_id=cls.alias,confirmed=True)['results'][0]['file'];cls.alias_id=f['id']
  cls.v.rpc('deliverable_set',project_id=cls.alias,file_ids=[f['id']]);cls.v.rpc('file_update',ids=[f['id']],name='AliasUnique.txt')
  cls.v.rpc('file_update',ids=[cls.aids[0],cls.aids[-1]],tags=['TagBoundary'])
  cls.before=cls.digest()
  (cls.base/'ui-fixture.json').write_text(json.dumps({'a':cls.a,'b':cls.b,'alias':cls.alias,'base':str(cls.base)},ensure_ascii=False))
 @classmethod
 def digest(cls):
  c=sqlite3.connect(cls.v.root/'workvault.sqlite');out={}
  for table in ['files','versions','file_projects','project_deliverables','provenance']:
   out[table]=hashlib.sha256(json.dumps(c.execute('SELECT * FROM '+table+' ORDER BY rowid').fetchall(),ensure_ascii=False).encode()).hexdigest()
  c.close();return out
 @classmethod
 def tearDownClass(cls):cls.v.close()
 def rpc(self,action,**p):return self.v.rpc(action,**p)
 def test_01_file_search_filters_before_count_and_pagination(self):
  r=self.rpc('files',q='CCUS',limit=2);self.assertEqual(r['total'],3);self.assertTrue(r['search_excludes_markdown']);self.assertEqual(len(r['items']),2)
  tail=self.rpc('files',q='CCUS',limit=2,offset=2);self.assertEqual(len(tail['items']),1)
  self.assertTrue(all(x['ext'] not in ['md','markdown'] for x in r['items']+tail['items']))
 def test_02_project_title_and_tag_matches_exclude_notes(self):
  self.assertEqual(self.rpc('files',q='SearchScope')['total'],3)
  self.assertEqual(self.rpc('files',q='TagBoundary')['total'],1)
  self.assertEqual(self.rpc('files',q='OnlyNotes')['total'],0)
 def test_03_uppercase_markdown_and_explicit_md_filter(self):
  self.assertEqual(self.rpc('files',q='MarkdownOnlyXYZ')['total'],0)
  self.assertEqual(self.rpc('files',q='CCUS',ext='md')['total'],0)
 def test_04_browsing_cleared_and_whitespace_search_keep_notes(self):
  self.assertEqual(self.rpc('files',project_id=self.a)['total'],73)
  self.assertEqual(self.rpc('files',q='   ',project_id=self.a)['total'],73)
  self.assertEqual(self.rpc('files',project_id=self.b,ext='markdown')['total'],1)
  self.assertEqual(self.rpc('deliverables',project_id=self.b)['total'],2)
 def test_05_final_search_counts_pagination_and_project_matching(self):
  r=self.rpc('deliverables',q='CCUS',project_id=self.a,limit=2);self.assertEqual(r['total'],3);self.assertEqual(len(r['groups'][0]['items']),2)
  self.assertEqual(len(self.rpc('deliverables',q='CCUS',project_id=self.a,limit=2,offset=2)['groups'][0]['items']),1)
  global_=self.rpc('deliverables',q='SearchScope');self.assertEqual(global_['total'],3);self.assertEqual(global_['total_projects'],1)
  no=self.rpc('deliverables',q='MarkdownOnlyXYZ');self.assertEqual(no['total'],0);self.assertEqual(no['groups'],[])
  project=self.rpc('deliverables',q='OnlyNotes');self.assertEqual(project['total_projects'],1);self.assertEqual(project['total'],0);self.assertEqual(project['groups'][0]['items'],[])
 def test_06_pinned_markdown_alias_not_leaked_after_rename(self):
  self.assertEqual(self.rpc('files',q='AliasUnique')['total'],1)
  r=self.rpc('deliverables',q='AliasUnique');self.assertEqual(r['total'],0);self.assertEqual(r['groups'],[])
  self.assertEqual(self.rpc('deliverables',project_id=self.alias)['groups'][0]['items'][0]['display_name'],'AliasUnique.MD')
 def test_07_browser_search_routes(self):
  node=shutil.which('node') or 'node'
  r=subprocess.run([node,str(BASE/'Tests/search-ui.mjs'),str(self.v.ready),str(self.base/'ui-fixture.json')],cwd=BASE,capture_output=True,text=True,timeout=100)
  (self.base/'browser-output.json').write_text(r.stdout)
  self.assertEqual(r.returncode,0,r.stdout+'\n'+r.stderr)
  data=json.loads(r.stdout);self.assertGreaterEqual(data['passed'],8)
  (BASE/'Tests/results/search-ui-results.json').write_text(json.dumps(data,ensure_ascii=False,indent=2))
 def test_08_search_does_not_change_archives_or_enable_ai(self):
  self.assertEqual(self.before,self.digest())
  c=sqlite3.connect(self.v.root/'workvault.sqlite');self.assertEqual(c.execute('SELECT count(*) FROM ai_requests').fetchone()[0],0);self.assertEqual(c.execute('SELECT count(*) FROM ai_chunks').fetchone()[0],0);c.close()

if __name__=='__main__':
 suite=unittest.defaultTestLoader.loadTestsFromTestCase(Search);result=unittest.TextTestRunner(verbosity=2).run(suite)
 (BASE/'Tests/results/search-results.json').write_text(json.dumps({'passed':result.testsRun-len(result.errors)-len(result.failures),'run':result.testsRun,'failed':len(result.errors)+len(result.failures),'compiled_native_service':True,'library':'isolated'},indent=2))
 raise SystemExit(0 if result.wasSuccessful() else 1)
