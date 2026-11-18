// Real Swift service + browser test for newest-first final-output timestamps.
// Only test fixtures are written. The app is shut down before isolated SQLite
// metadata is seeded, then restarted with the same files/version database.
import fs from 'node:fs/promises';
import path from 'node:path';
import {createRequire} from 'node:module';
import {spawn,execFile} from 'node:child_process';
import {promisify} from 'node:util';
const execFileAsync=promisify(execFile),require=createRequire(import.meta.url);
const {chromium}=require(process.env.WORKVAULT_PLAYWRIGHT || 'playwright');
if(!process.argv[2])throw new Error('Usage: node Tests/final-time-ui.mjs /absolute/work/final-time-*/ready.json [/absolute/WorkVault]');
const readyPath=path.resolve(process.argv[2]);let ready=JSON.parse(await fs.readFile(readyPath,'utf8')),base=new URL(ready.url).origin,owned=false,child=null;
const binary=path.resolve(process.argv[3] || 'dist/WorkVault.app/Contents/MacOS/WorkVault');
const browser=await chromium.launch({executablePath:process.env.WORKVAULT_CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless:true,args:['--no-first-run','--disable-background-networking','--disable-component-update']});
// Deliberately test outside Shanghai so machine defaults cannot mask a timezone bug.
const context=await browser.newContext({viewport:{width:1440,height:1050},locale:'zh-CN',timezoneId:'America/Los_Angeles'}),page=await context.newPage();
const checks=[],errors=[],external=[];page.on('pageerror',e=>errors.push(String(e)));page.on('request',r=>{if(!['127.0.0.1','localhost'].includes(new URL(r.url()).hostname))external.push(r.url());});
const check=(name,ok=true)=>{checks.push({name,passed:!!ok});if(!ok)throw new Error(name);};
const pause=ms=>new Promise(resolve=>setTimeout(resolve,ms));
async function api(action,data={}){const response=await context.request.post(base+'/api/rpc',{headers:{Origin:base},data:{action,...data},timeout:10000});const body=await response.json();if(!response.ok()||body.error)throw new Error(body.error || `${action}: ${response.status()}`);return body;}
async function project(title){return (await api('project_save',{title:'时间排序验收 · '+title})).project;}
async function importTo(project,name,body){const filename=path.join(path.dirname(readyPath),name);await fs.writeFile(filename,body);const result=await api('import',{paths:[filename],project_id:project.id,confirmed:true,source:'manual'});const file=result.results[0].file;await api('deliverable_set',{project_id:project.id,file_ids:[file.id],version_id:file.current_version});return file;}
async function waitForFileGone(){for(let i=0;i<100;i++){try{await fs.access(readyPath);}catch{return;}await pause(50);}throw new Error('Test server did not remove its ready file on exit');}
try{
 await context.request.get(ready.url);const before=await api('status');if(!String(before.root).includes('/work/final-time')||before.files||before.projects)throw new Error('Refusing to modify anything except a fresh isolated final-time test library');owned=true;await api('setup');
 const a=await project('上一年度交付'),b=await project('十一月交付'),c=await project('交付时间未知'),d=await project('最新实测交付'),empty=await project('空项目');
 const aFile=await importTo(a,'验收-上一年度锁定报告.md','# Locked version one\n\nOriginal pinned output from the prior year.\n');
 const bNew=await importTo(b,'验收-十一月新版.md','# November delivery\n'),bOld=await importTo(b,'验收-十月旧版.md','# October delivery\n'),bUnknown=await importTo(b,'验收-交付时间未记录.md','# Collection fallback\n');
 const cFile=await importTo(c,'验收-仅知收录时间.md','# Unknown actual delivery date\n'),dFile=await importTo(d,'验收-本机实测交付.md','# Local verified release\n');
 const later=path.join(path.dirname(readyPath),'验收-后续未收录版本.md');await fs.writeFile(later,'# Current version two\n\nThis later edit must not replace the pinned prior-year output.\n');await api('version_add',{id:aFile.id,path:later,note:'验收：后续编辑，保留旧交付'});
 const rows=[
  {project:a.id,file:aFile.id,delivered:'2025-10-31T15:40:00Z',selected:'2030-01-01T00:00:00Z',source:'verified_task_delivery'},
  {project:b.id,file:bNew.id,delivered:'2026-11-04T18:30:00Z',selected:'2026-11-01T01:00:00Z',source:'task_final_message'},
  {project:b.id,file:bOld.id,delivered:'2026-10-20T03:00:00Z',selected:'2030-01-02T00:00:00Z',source:'verified_task_delivery'},
  {project:b.id,file:bUnknown.id,delivered:null,selected:'2026-11-03T01:00:00Z',source:'user'},
  {project:c.id,file:cFile.id,delivered:null,selected:'2026-11-06T01:02:03Z',source:'user'},
  {project:d.id,file:dFile.id,delivered:'2026-11-15T09:00:00Z',selected:'2026-11-01T00:00:00Z',source:'local_release'}
 ];
 await api('shutdown');await waitForFileGone();
 const seed=`import json,sqlite3,sys\ndb=sqlite3.connect(sys.argv[1])\nrows=json.loads(sys.argv[2])\nwith db:\n for row in rows:\n  db.execute('UPDATE project_deliverables SET delivered_at=?,time_source=?,selected_at=?,evidence_source=?,evidence_note=? WHERE project_id=? AND file_id=?',(row['delivered'],('local_release' if row['source']=='local_release' else 'task_delivery') if row['delivered'] else 'collection',row['selected'],row['source'],('用户明确选择的成果，交付时间尚未记录。' if row['source']=='user' else 'ISOLATED_TEST_PROOF_UUID_12345678; original task delivery metadata verified for test fixture'),row['project'],row['file']))\ndb.close()\n`;
 await execFileAsync('/usr/bin/python3',['-c',seed,path.join(before.root,'workvault.sqlite'),JSON.stringify(rows)]);
 child=spawn(binary,['--headless','--root',before.root,'--web',path.resolve('Web'),'--ready-file',readyPath],{stdio:['ignore','ignore','pipe']});let childError='';child.stderr.on('data',data=>{childError+=data.toString();});
 let found=false;for(let i=0;i<200;i++){try{ready=JSON.parse(await fs.readFile(readyPath,'utf8'));found=true;break;}catch{if(child.exitCode!==null)throw new Error('Restart failed: '+childError);await pause(50);}}if(!found)throw new Error('Restart did not become ready');base=new URL(ready.url).origin;await context.request.get(ready.url);
 const result=await api('deliverables',{limit:12});const order=result.groups.map(group=>group.project.id);check('Backend project ordering uses real delivery date or explicit collection fallback',JSON.stringify(order)===JSON.stringify([d.id,c.id,b.id,a.id,empty.id]));
 await page.goto(ready.url);await page.waitForSelector('.sidebar');await page.locator('.sidebar [data-page=deliverables]').click();await page.locator('#final-groups').waitFor();
 const shown=await page.locator('#final-groups>[data-final-group]').evaluateAll(nodes=>nodes.map(n=>n.dataset.finalGroup));check('UI preserves server newest-first project order',JSON.stringify(shown)===JSON.stringify(order));
 await page.getByText('最近在前',{exact:true}).waitFor();check('Newest-first order is explicitly labeled');
 const aGroup=page.locator(`[data-final-group="${a.id}"]`),dGroup=page.locator(`[data-final-group="${d.id}"]`),cGroup=page.locator(`[data-final-group="${c.id}"]`);
 check('Dates show years and explicit Shanghai timezone despite Los Angeles browser setting',(await aGroup.locator('.deliverable-time').innerText()).includes('2025/10/31')&&(await page.locator('.deliverable-sort-note').innerText()).includes('北京时间'));
 check('Verified task-delivery evidence has a readable label',(await aGroup.innerText()).includes('任务交付记录已核实'));
 check('Local release evidence has a readable label',(await dGroup.innerText()).includes('本机实测交付'));
 check('Automatic cards use a concise note instead of raw proof IDs',!(await aGroup.locator('.deliverable-note').innerText()).includes('ISOLATED_TEST_PROOF_UUID'));
 check('Unknown delivery cards truthfully label collection time and pending verification',(await cGroup.locator('.deliverable-time').innerText()).includes('收录')&&(await cGroup.locator('.deliverable-time').innerText()).includes('交付时间待核实'));
 check('Group headers distinguish latest delivery and latest collection',(await dGroup.locator('.deliverable-latest').innerText()).includes('最近交付')&&(await cGroup.locator('.deliverable-latest').innerText()).includes('最近收录'));
 await page.locator('#final-project').selectOption(b.id);await page.waitForFunction(id=>document.querySelectorAll('#final-groups>[data-final-group]').length===1&&document.querySelector('#final-groups>[data-final-group]')?.getAttribute('data-final-group')===id,b.id);
 const fileOrder=await page.locator('.deliverable-card').evaluateAll(nodes=>nodes.map(n=>n.dataset.deliverableKey.split(':')[1]));check('Within-project files remain newest first across known and fallback dates',JSON.stringify(fileOrder)===JSON.stringify([bNew.id,bUnknown.id,bOld.id]));
 check('UTC crossing midnight is rendered as November 5 in Shanghai',(await page.locator('.deliverable-time').first().innerText()).includes('2026/11/05'));
 await page.locator('#final-project').selectOption(a.id);await page.waitForFunction(id=>document.querySelector('#final-groups>[data-final-group]')?.getAttribute('data-final-group')===id,a.id);await page.locator('[data-final-preview]').first().click();await page.locator('.previewbox').getByText('Original pinned output from the prior year.',{exact:false}).waitFor();check('Chronological display still previews the immutable pinned version');
 check('Preview shows real delivery and collection as separate timestamps',(await page.locator('.modal .kv').innerText()).includes('真实交付时间')&&(await page.locator('.modal .kv').innerText()).includes('2025/10/31')&&(await page.locator('.modal .kv').innerText()).includes('2030/01/01'));
 await page.locator('.deliverable-proof-details summary').click();check('Complete proof is retained in expandable preview details',(await page.locator('.deliverable-proof').innerText()).includes('ISOLATED_TEST_PROOF_UUID'));
 await page.locator('.modalhead [data-action=close]').click();await page.locator('#final-project').selectOption(c.id);await page.waitForFunction(id=>document.querySelector('#final-groups>[data-final-group]')?.getAttribute('data-final-group')===id,c.id);await page.locator('[data-final-preview]').first().click();check('Preview never substitutes collection for a missing real delivery date',(await page.locator('.modal .kv').innerText()).includes('未记录 · 交付时间待核实'));await page.locator('.modalhead [data-action=close]').click();
 await page.locator('#final-project').selectOption('');await page.waitForFunction(()=>document.querySelectorAll('#final-groups>[data-final-group]').length===5);await page.screenshot({path:path.join(path.dirname(readyPath),'final-time-ui.png'),fullPage:true});
 check('No JavaScript errors',errors.length===0);check('No external browser requests',external.length===0);check('Timestamp test creates no AI requests',(await api('ai_status')).requests.length===0);
 console.log(JSON.stringify({passed:checks.length,checks,errors,external_requests:external,note:'日期为隔离测试夹具；SQLite仅在测试应用退出后写入。真实文件与固定版本均经本地服务读取。浏览器时区刻意设为洛杉矶，界面仍按上海显示。'},null,2));
}catch(error){console.log(JSON.stringify({checks,errors,failure:String(error)},null,2));throw error;}
finally{if(owned){try{await api('shutdown');await waitForFileGone();}catch{if(child&&child.exitCode===null)child.kill('SIGTERM');}}await browser.close();}
