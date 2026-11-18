#!/usr/bin/env python3
"""Real compiled-service tests for project-scoped immutable final deliveries."""
import os, pathlib, sqlite3, json, unittest, time
os.environ['WORKVAULT_TEST_DIR']=str(pathlib.Path(__file__).resolve().parents[3]/'work'/'deliverable-tests')
from integration import Vault, RUN

class Deliverables(unittest.TestCase):
 @classmethod
 def setUpClass(cls):
  RUN.mkdir(parents=True,exist_ok=True)
  cls.base=RUN/str(time.time_ns());cls.base.mkdir();cls.v=Vault(cls.base/'library')
 @classmethod
 def tearDownClass(cls):cls.v.close()
 def rpc(self,action,**p):return self.v.rpc(action,**p)
 def project(self,title):return self.rpc('project_save',title=title)['project']['id']
 def fixture(self,text):
  p=self.base/(str(time.time_ns())+'.txt');p.write_text(text);return str(p)
 def add(self,project,text='initial',confirmed=True):
  return self.rpc('import',paths=[self.fixture(text+str(time.time_ns()))],project_id=project,confirmed=confirmed)['results'][0]['file']
 def items(self,project):return self.rpc('deliverables',project_id=project)['groups'][0]['items']
 def test_01_scope_and_pin(self):
  a=self.project('A');b=self.project('B');f=self.add(a);fid=f['id'];old=f['current_version']
  self.rpc('file_update',ids=[fid],project_id=b)
  self.rpc('deliverable_set',project_id=a,file_ids=[fid]);new=self.rpc('version_add',id=fid,path=self.fixture('later'))['version_id']
  self.rpc('deliverable_set',project_id=b,file_ids=[fid])
  self.assertEqual(self.items(a)[0]['version_id'],old);self.assertEqual(self.items(b)[0]['version_id'],new)
  self.assertEqual(self.items(a)[0]['version_is_current'],0)
  self.rpc('deliverable_remove',project_id=a,file_id=fid,version_id=old)
  self.assertEqual(self.items(a),[]);self.assertEqual(len(self.items(b)),1)
  self.assertEqual(self.rpc('file_detail',id=fid)['file']['final'],1)
  self.rpc('deliverable_remove',project_id=b,file_id=fid)
  self.assertEqual(self.rpc('file_detail',id=fid)['file']['final'],0)
  self.assertEqual(len(self.rpc('file_detail',id=fid)['versions']),2)
 def test_02_reject_unconfirmed_unrelated_and_wrong_version(self):
  a=self.project('constraints');b=self.project('other');f=self.add(a,confirmed=False);g=self.add(a)
  for p in [dict(project_id=a,file_ids=[f['id']]),dict(project_id=b,file_ids=[g['id']]),dict(project_id=a,file_ids=[g['id']],version_id=f['current_version'])]:
   with self.assertRaises(RuntimeError):self.rpc('deliverable_set',**p)
  self.assertEqual(self.items(a),[])
 def test_03_atomic_batch_and_replace_single_project(self):
  a=self.project('batch');b=self.project('outside');f=self.add(a);g=self.add(b)
  with self.assertRaises(RuntimeError):self.rpc('deliverable_set',project_id=a,file_ids=[f['id'],g['id']])
  self.assertEqual(self.items(a),[])
  self.rpc('deliverable_set',project_id=a,file_ids=[f['id']]);self.rpc('deliverable_set',project_id=a,file_ids=[f['id']]);self.assertEqual(len(self.items(a)),1)
 def test_04_trash_restore_preserves_pin(self):
  a=self.project('trash');f=self.add(a);self.rpc('deliverable_set',project_id=a,file_ids=[f['id']])
  self.rpc('file_update',ids=[f['id']],status='trash');self.assertEqual(self.items(a),[])
  self.rpc('file_update',ids=[f['id']],status='managed');self.assertEqual(self.items(a)[0]['version_id'],f['current_version'])
 def test_05_merge_split_keep_selected_versions(self):
  a=self.project('merge a');b=self.project('merge b');f=self.add(a);self.rpc('file_update',ids=[f['id']],project_id=b)
  self.rpc('deliverable_set',project_id=a,file_ids=[f['id']]);new=self.rpc('version_add',id=f['id'],path=self.fixture('new merged'))['version_id']
  self.rpc('deliverable_set',project_id=b,file_ids=[f['id']]);self.rpc('project_merge',from_id=a,to_id=b)
  self.assertEqual({i['version_id'] for i in self.items(b)},{f['current_version'],new})
  c=self.rpc('project_split',id=b,title='split pins',file_ids=[f['id']])['project']['id']
  self.assertEqual(len(self.items(c)),2);self.assertEqual(self.items(b),[])
 def test_06_scoped_filters_and_search(self):
  a=self.project('scoped A');b=self.project('scoped B');f=self.add(a);self.rpc('file_update',ids=[f['id']],project_id=b)
  self.rpc('deliverable_set',project_id=a,file_ids=[f['id']])
  self.assertEqual(self.rpc('files',project_id=b,final=True)['total'],0)
  self.assertEqual(self.rpc('project_detail',id=b)['files'][0]['final'],0)
  self.assertEqual(self.rpc('deliverables',q='scoped A')['total'],1)
  self.assertEqual(self.rpc('deliverables',project_id=a,q='definitely missing')['total'],0)
 def test_07_project_reassignment_removes_only_lost_relation(self):
  a=self.project('retained');b=self.project('removed');f=self.add(a);self.rpc('file_update',ids=[f['id']],project_id=b)
  for p in [a,b]:self.rpc('deliverable_set',project_id=p,file_ids=[f['id']])
  self.rpc('file_update',ids=[f['id']],project_id=a,replace_projects=True)
  self.assertEqual(len(self.items(a)),1);self.assertEqual(self.items(b),[])
  self.rpc('file_update',ids=[f['id']],project_id='',replace_projects=True)
  self.assertEqual(self.rpc('file_detail',id=f['id'])['file']['final'],0)
 def test_08_pagination_and_empty_projects(self):
  a=self.project('paging');fs=[self.add(a) for _ in range(5)];self.rpc('deliverable_set',project_id=a,file_ids=[f['id'] for f in fs])
  d=self.rpc('deliverables',project_id=a,limit=2,offset=4);self.assertEqual(d['total'],5);self.assertEqual(len(d['groups'][0]['items']),1)
  self.assertEqual(self.rpc('deliverables',limit=2)['limit'],2)
  empty=self.project('empty collection');self.assertEqual(self.rpc('deliverables',project_id=empty)['groups'][0]['total'],0)
 def test_09_legacy_marker_and_version_action(self):
  a=self.project('legacy');f=self.add(a);self.rpc('file_update',ids=[f['id']],final=True)
  self.assertEqual(len(self.items(a)),1);self.rpc('file_update',ids=[f['id']],final=False);self.assertEqual(self.items(a),[])
  self.rpc('version_final',id=f['id'],version_id=f['current_version']);self.assertEqual(len(self.items(a)),1)
 def test_10_backup_restore_and_integrity(self):
  a=self.project('backup pin');f=self.add(a);self.rpc('deliverable_set',project_id=a,file_ids=[f['id']])
  (self.base/'backups').mkdir()
  backup=self.rpc('backup_create',destination=str(self.base/'backups'))
  path=backup['path'];restored=self.rpc('backup_restore',path=path,destination=str(self.base/'restored'),confirmed=True)
  db=sqlite3.connect(self.base/'restored'/'workvault.sqlite')
  self.assertEqual(db.execute('SELECT version_id FROM project_deliverables WHERE project_id=?',(a,)).fetchone()[0],f['current_version'])
  self.assertEqual(db.execute('PRAGMA integrity_check').fetchone()[0],'ok');self.assertEqual(db.execute('PRAGMA foreign_key_check').fetchall(),[]);db.close()
 def test_11_schema3_explicit_marker_migrates(self):
  root=self.base/'legacy';v=Vault(root)
  try:
   pid=v.rpc('project_save',title='existing explicit selection')['project']['id']
   f=v.rpc('import',paths=[self.fixture('legacy original')],project_id=pid,confirmed=True)['results'][0]['file']
   v.rpc('file_update',ids=[f['id']],final=True)
  finally:v.close()

  db=sqlite3.connect(root/'workvault.sqlite');db.execute('DROP TABLE project_deliverables');db.execute('DELETE FROM schema_migrations WHERE version>=4');db.execute('PRAGMA user_version=3');db.commit();db.close()
  v.ready.unlink(missing_ok=True);v=Vault(root)
  try:
   item=v.rpc('deliverables',project_id=pid)['groups'][0]['items'][0]
   self.assertEqual(item['version_id'],f['current_version']);self.assertEqual(item['evidence_source'],'legacy_final')
   self.assertEqual(v.rpc('file_detail',id=f['id'])['file']['name'],f['name'])
  finally:v.close()


 def test_12_chronological_order_uses_delivery_not_import_order(self):
  a=self.project('time older project');b=self.project('time newer project');empty=self.project('time empty project')
  old=self.add(a);middle=self.add(a);new=self.add(b)
  for pid,fs in [(b,[new]),(a,[middle,old])]:self.rpc('deliverable_set',project_id=pid,file_ids=[f['id'] for f in fs])
  db=sqlite3.connect(self.v.root/'workvault.sqlite')
  for f,date in [(old,'2025-10-01T00:00:00Z'),(middle,'2025-10-20T00:00:00Z'),(new,'2025-11-10T00:00:00Z')]:
   db.execute("UPDATE project_deliverables SET delivered_at=?,time_source='task_delivery' WHERE file_id=?",(date,f['id']))
  db.commit();db.close()
  group=self.rpc('deliverables',q='time ',limit=50)['groups'];self.assertEqual([g['project']['id'] for g in group],[b,a,empty])
  self.assertEqual([i['file_id'] for i in self.items(a)],[middle['id'],old['id']])
  self.assertEqual(self.items(a)[0]['effective_at'],'2025-10-20T00:00:00Z')
  self.assertEqual(group[0]['latest_time_source'],'task_delivery')
  self.rpc('deliverable_set',project_id=a,file_ids=[middle['id']],evidence_note='note only')
  self.assertEqual(self.items(a)[0]['delivered_at'],'2025-10-20T00:00:00Z')
  self.rpc('version_add',id=middle['id'],path=self.fixture('new working version'))
  self.rpc('deliverable_set',project_id=a,file_ids=[middle['id']],delivered_at='2099-01-01T00:00:00Z',time_source='task_delivery')
  item=self.items(a)[0];self.assertIsNone(item.get('delivered_at'));self.assertEqual(item['time_source'],'collection')
  self.assertEqual(item['effective_at'],item['selected_at'])
  self.rpc('project_merge',from_id=b,to_id=a)
  merged={i['file_id']:i for i in self.items(a)};self.assertEqual(merged[new['id']]['delivered_at'],'2025-11-10T00:00:00Z')
  split=self.rpc('project_split',id=a,title='time split',file_ids=[new['id']])['project']['id']
  self.assertEqual(self.items(split)[0]['delivered_at'],'2025-11-10T00:00:00Z')

 def test_13_schema4_collection_time_migrates_without_inventing_delivery(self):
  root=self.base/'schema4';v=Vault(root)
  try:
   pid=v.rpc('project_save',title='schema4 fixture')['project']['id']
   f=v.rpc('import',paths=[self.fixture('schema4 fixture')],project_id=pid,confirmed=True)['results'][0]['file']
   v.rpc('deliverable_set',project_id=pid,file_ids=[f['id']])
   selected=v.rpc('deliverables',project_id=pid)['groups'][0]['items'][0]['selected_at']
  finally:v.close()
  db=sqlite3.connect(root/'workvault.sqlite');db.execute('DROP INDEX deliverables_time');db.execute('ALTER TABLE project_deliverables DROP COLUMN delivered_at');db.execute('ALTER TABLE project_deliverables DROP COLUMN time_source');db.execute('DELETE FROM schema_migrations WHERE version=5');db.execute('PRAGMA user_version=4');db.commit();db.close()
  v.ready.unlink(missing_ok=True);v=Vault(root)
  try:
   item=v.rpc('deliverables',project_id=pid)['groups'][0]['items'][0]
   self.assertIsNone(item.get('delivered_at'));self.assertEqual(item['selected_at'],selected);self.assertEqual(item['effective_at'],selected);self.assertEqual(item['time_source'],'collection')
  finally:v.close()

if __name__=='__main__':unittest.main(verbosity=2)
