// Real UI + SQLite/filesystem E2E for per-project pinned final outputs.
// Run only against a freshly isolated WorkVault --root, never a user's library.
// The native directory chooser is replaced only when testing Export; all file,
// version, collection and export operations use the actual local Swift service.
import fs from 'node:fs/promises';
import path from 'node:path';
import {createRequire} from 'node:module';
const require=createRequire(import.meta.url);
const {chromium}=require(process.env.WORKVAULT_PLAYWRIGHT || 'playwright');
if(!process.argv[2])throw new Error('Usage: node Tests/final-ui-smoke.mjs /absolute/test/ready.json');
const ready=JSON.parse(await fs.readFile(process.argv[2],'utf8'));
const base=new URL(ready.url).origin;
const fixtureRoot=path.resolve(path.dirname(process.argv[2]),'fixtures');await fs.mkdir(fixtureRoot,{recursive:true});
const fixture=path.join(fixtureRoot,'验收测试-交付报告.md'),newVersion=path.join(fixtureRoot,'验收测试-更新版本.md');
const first='# 验收测试资料\n\nVersion One Pinned Delivery.\n\n这是隔离验收文件，不是真实用户报告。\n';
const second='# 验收测试资料\n\nVersion Two Updated Content.\n\n这是后续版本，不能覆盖其他项目已经锁定的交付。\n';
await fs.writeFile(fixture,first);await fs.writeFile(newVersion,second);
const browser=await chromium.launch({executablePath:process.env.WORKVAULT_CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless:true,args:['--no-first-run','--disable-background-networking','--disable-component-update']});
const context=await browser.newContext({viewport:{width:1440,height:1000},locale:'zh-CN'}),page=await context.newPage();
const checks=[],errors=[],external=[],exportRequests=[];let chooserDestination=null;
page.on('pageerror',e=>errors.push(String(e)));
page.on('request',r=>{if(!['127.0.0.1','localhost'].includes(new URL(r.url()).hostname))external.push(r.url());});
await page.route('**/api/rpc',async route=>{const data=route.request().postDataJSON();if(data.action==='export_file')exportRequests.push(data);if(data.action==='choose_directory'&&chooserDestination){const destination=chooserDestination;chooserDestination=null;await route.fulfill({json:{path:destination}});}else await route.continue();});
const check=(name,pass=true)=>{checks.push({name,passed:!!pass});if(!pass)throw new Error(name);};
async function api(action,data={}){const r=await context.request.post(base+'/api/rpc',{headers:{Origin:base},data:{action,...data}});const body=await r.json();if(!r.ok()||body.error)throw new Error(body.error || `${action} ${r.status()}`);return body;}
const action=async name=>{await page.locator(`[data-action="${name}"]`).first().click();};
const nav=async name=>{await page.locator(`.sidebar [data-page="${name}"]`).click();await page.locator(`.sidebar [data-page="${name}"].active`).waitFor();await page.locator('.loading').waitFor({state:'detached'});};
const toast=async text=>{await page.locator('#toasts').getByText(text,{exact:false}).first().waitFor();};
const scope=async id=>{await page.locator('#final-project').selectOption(id);await page.waitForTimeout(150);await page.locator('.loading').waitFor({state:'detached'});await page.locator(`#final-groups [data-final-group="${id}"]`).waitFor();};
try{
 await context.request.get(ready.url);
 const before=await api('status');if(before.projects||before.files)throw new Error('Refusing to test a nonempty library');
 await api('setup');
 const a=(await api('project_save',{title:'验收测试 · 同名任务',original_title:'验收原始标题 A',conversation_id:'final-ui-A'})).project;
 const b=(await api('project_save',{title:'验收测试 · 同名任务',original_title:'验收原始标题 B',conversation_id:'final-ui-B'})).project;
 for(let i=0;i<13;i++)await api('project_save',{title:`验收测试 · 未收录项目 ${String(i+1).padStart(2,'0')}`});
 const imported=await api('import',{paths:[fixture],project_id:a.id,confirmed:true,source:'manual'}),file=imported.results[0].file,fileID=file.id,v1=file.current_version;
 await api('import',{paths:[fixture],project_id:b.id,confirmed:true,source:'manual'});
 await page.goto(ready.url);await page.waitForSelector('.sidebar');await nav('deliverables');
 check('Independent final outputs sidebar follows project center',await page.locator('.sidebar .nav button').evaluateAll(nodes=>{const ids=nodes.map(n=>n.dataset.page);return ids.indexOf('deliverables')===ids.indexOf('projects')+1;}));
 check('Project overview paginates 12 real projects',await page.locator('[data-final-group]').count()===12);
 await page.getByText('尚未收录最终成果',{exact:true}).first().waitFor();check('Unmarked projects have explicit honest empty states');
 await action('final-next');await page.locator('.loading').waitFor({state:'detached'});await page.waitForTimeout(150);check('Project pagination reaches remaining projects',await page.locator('[data-final-group]').count()===3);
 await action('final-pick');await page.locator('[name=pick_project]').selectOption(a.id);await page.locator(`[data-final-pick-id="${fileID}"]`).check();await action('final-pick-save');await toast('已收录');
 const selectedA=(await api('deliverables',{project_id:a.id})).groups[0].items[0];check('Explicit picker pins a real current version',selectedA.version_id===v1&&selectedA.evidence_source==='user');
 await scope(a.id);await page.locator('[data-final-preview]').first().click();await page.locator('.previewbox').getByText('Version One Pinned Delivery.',{exact:false}).waitFor();check('Pinned preview reads actual selected version');await action('close');
 await api('version_add',{id:fileID,path:newVersion,note:'验收测试：后续修改'});const detail=await api('file_detail',{id:fileID}),v2=detail.file.current_version;check('Adding a new version retains A’s previous selection',(await api('deliverables',{project_id:a.id})).groups[0].items[0].version_id===v1&&v1!==v2);
 await nav('files');await page.locator(`[data-detail="${fileID}"]`).first().click();await action('detail-final');await page.locator('[name=final_project]').selectOption(b.id);await page.locator('[name=final_version]').selectOption(v2);await action('manager-save');await toast('本项目最终成果已更新');
 const selectedB=(await api('deliverables',{project_id:b.id})).groups[0].items[0];check('Same shared file can pin different versions in two same-title projects',selectedB.version_id===v2&&(await api('deliverables',{project_id:a.id})).groups[0].items[0].version_id===v1);
 await nav('deliverables');await scope(a.id);await page.locator('[data-final-preview]').first().click();await page.locator('.previewbox').getByText('Version One Pinned Delivery.',{exact:false}).waitFor();check('Historical final preview does not follow newer current content');
 const exportA=path.join(fixtureRoot,'export-A');await fs.mkdir(exportA,{recursive:true});chooserDestination=exportA;await action('pinned-export');await toast('文件已导出');check('Export button passes pinned version and exports real original bytes',exportRequests.at(-1).version_id===v1&&exportRequests.at(-1).name===selectedA.display_name&&await fs.readFile(path.join(exportA,file.name),'utf8')===first);await action('close');
 await scope(b.id);await page.locator('[data-final-preview]').first().click();await page.locator('.previewbox').getByText('Version Two Updated Content.',{exact:false}).waitFor();check('Other project previews its independently selected version');await action('close');
 await page.locator('#final-q').fill('不存在的成果关键词');await page.waitForTimeout(700);check('Project title search hides unrelated projects',await page.locator('.deliverable-card').count()===0);await page.locator('#final-q').fill('');await page.waitForTimeout(700);await page.locator('.deliverable-card').waitFor();
 await page.locator('#final-project').selectOption('');await page.waitForTimeout(250);await page.locator('.loading').waitFor({state:'detached'});const groupA=page.locator(`[data-final-group="${a.id}"]`);await groupA.waitFor();await groupA.locator('[data-project]').click();await page.locator('.projecthero h1').waitFor();await page.locator(`.deliverable-group[data-final-group="${a.id}"]`).waitFor();check('Project detail contains a dedicated final outputs subsection');
 await page.locator(`.deliverable-group[data-final-group="${a.id}"] [data-final-project]`).click();await page.locator('#final-project').waitFor();check('View-all opens the correct project collection',await page.locator('#final-project').inputValue()===a.id);
 await page.locator('[data-final-remove]').first().click();await action('confirm');await toast('已移出最终成果清单');
 check('Removal affects only the chosen project collection',(await api('deliverables',{project_id:a.id})).total===0&&(await api('deliverables',{project_id:b.id})).total===1);
 const after=await api('file_detail',{id:fileID});check('Removal preserves managed file, all versions and both project relations',after.file.status==='managed'&&after.versions.length===2&&after.projects.length===2);
 await scope(b.id);await page.locator('[data-final-preview]').first().click();await action('pinned-detail');await page.locator(`[data-version-final="${v1}"]`).click();await page.locator('[name=final_project]').selectOption(a.id);check('History version action opens explicit project/version chooser',await page.locator('[name=final_version]').inputValue()===v1);await action('manager-save');await toast('本项目最终成果已更新');
 check('Historical version can be explicitly re-collected for one project',(await api('deliverables',{project_id:a.id})).groups[0].items[0].version_id===v1);
 await nav('deliverables');await page.locator('#final-project').selectOption('');await page.waitForTimeout(350);await page.locator('.loading').waitFor({state:'detached'});await page.waitForTimeout(5200);
 await fs.mkdir('docs/screenshots',{recursive:true});await page.screenshot({path:'docs/screenshots/验收测试-最终成果.png',fullPage:true});
 check('No browser JavaScript errors',errors.length===0);check('No external browser requests or AI invocation',external.length===0);
 await fs.rm('docs/screenshots/验收测试-最终成果失败.png',{force:true});
 console.log(JSON.stringify({passed:checks.length,checks,errors,external_requests:external,native_dialog_note:'仅导出测试替代目录选择器返回值；导出RPC、SHA校验与文件内容均为真实执行。'},null,2));
}catch(e){await fs.mkdir('docs/screenshots',{recursive:true});await page.screenshot({path:'docs/screenshots/验收测试-最终成果失败.png',fullPage:true});console.log(JSON.stringify({checks,errors,failure:String(e)},null,2));throw e;}
finally{await browser.close();}
