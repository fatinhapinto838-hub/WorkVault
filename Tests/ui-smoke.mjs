// Actual loopback HTTP + browser UI E2E. Only use an isolated --root test library.
import fs from 'node:fs/promises';
import path from 'node:path';
import {createRequire} from 'node:module';
const require=createRequire(import.meta.url);
const {chromium}=require(process.env.WORKVAULT_PLAYWRIGHT || 'playwright');
const readyPath=process.argv[2];
if(!readyPath)throw new Error('Usage: node Tests/ui-smoke.mjs /absolute/path/to/ready.json');
const ready=JSON.parse(await fs.readFile(readyPath,'utf8'));
const root=path.resolve(path.dirname(readyPath),'ui-fixtures');await fs.mkdir(root,{recursive:true});
const fixture=path.join(root,'验收测试-CCUS研究札记.md');
await fs.writeFile(fixture,'# 验收测试资料\n\nThis is an isolated WorkVault acceptance fixture.\n\nCCUS carbon storage requires integrity verification.\n\n**测试文件，不是真实科研成果。**\n\n<script>throw new Error("UNSAFE_MARKDOWN")</script>\n');
const browser=await chromium.launch({executablePath:process.env.WORKVAULT_CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless:true,args:['--no-first-run','--disable-background-networking','--disable-component-update']});
const context=await browser.newContext({viewport:{width:1440,height:960},locale:'zh-CN'});
const page=await context.newPage(),errors=[],requests=[],checks=[];
page.on('pageerror',e=>errors.push(String(e)));
page.on('request',r=>{if(!new URL(r.url()).hostname.match(/^(127\.0\.0\.1|localhost)$/))requests.push(r.url());});
const check=(name,ok=true)=>{checks.push({name,passed:!!ok});if(!ok)throw new Error(name);};
const action=async(name)=>{await page.locator(`[data-action="${name}"]`).first().click();};
const nav=async(name)=>{await page.locator(`.sidebar [data-page="${name}"]`).click();await page.locator(`.sidebar [data-page="${name}"].active`).waitFor();await page.locator('.loading').waitFor({state:'detached'});};
const waitToast=async(text)=>{await page.locator('#toasts').getByText(text,{exact:false}).first().waitFor();};
try{
 await page.goto(ready.url);await page.waitForSelector('#onboard-next,.sidebar');
 if(await page.locator('#onboard-next').count()){
  for(let i=0;i<9;i++){await page.locator('#onboard-next').click();if(i<8)await page.waitForTimeout(70);}
  await page.waitForSelector('.sidebar');check('9-step first-run wizard initializes real library');
 }
 await page.getByText('你的成果，井然有序。').waitFor();check('Dashboard renders actual database empty state');
 await action('new-project');await page.locator('#modal-root [name=title]').fill('验收测试 · CCUS成果归档');await page.locator('#modal-root [name=original_title]').fill('验收测试 · 原始 Work 标题');await page.locator('#modal-root [name=conversation_id]').fill('ui-acceptance-'+Date.now());await action('project-submit');await waitToast('项目已保存');check('Project title form saves to SQLite with distinct conversation identity');
 await nav('projects');await page.locator('.projectcard').filter({hasText:'验收测试 · CCUS成果归档'}).click();await page.getByText('验收测试 · 原始 Work 标题',{exact:true}).waitFor();check('Project detail retains original Work title');
 await action('import');await page.locator('#import-paths').fill(fixture);await action('import-submit');await waitToast('导入完成');check('Native-path import form imports fixture through real backend');
 await nav('files');await page.locator('#file-q').fill('CCUS');await page.waitForTimeout(650);await page.locator('[data-detail]').filter({hasText:'验收测试-CCUS研究札记.md'}).first().click();await page.locator('.markdown').getByText('CCUS carbon storage requires integrity verification.',{exact:false}).waitFor();check('Markdown safely previews real imported file');check('Markdown HTML is escaped',await page.locator('.markdown script').count()===0);
 await action('detail-favorite');await page.getByRole('button',{name:'取消收藏',exact:true}).waitFor();check('Favorite mutation persists and refreshes file detail');
 await action('detail-rename');await page.locator('#modal-root [name=name]').fill('验收测试-已整理-CCUS.md');await action('rename-submit');await waitToast('文件名称已更新');check('File rename through UI updates real metadata');
 await page.waitForSelector('[data-select]');await page.locator('[data-select]').first().check();await action('batch-tags');await page.locator('#modal-root [name=tags]').fill('验收测试, CCUS');await action('tags-submit');await waitToast('标签已保存');check('Batch tags update real metadata');
 await action('view-grid');await page.locator('.filegrid .filecard').waitFor();check('Grid view displays actual managed file');
 await page.waitForTimeout(5500);await page.screenshot({path:path.resolve('docs/screenshots/验收测试-文件中心.png'),fullPage:true});
 await nav('ai');await action('ai-index');await page.locator('#modal-root [name=project_id]').selectOption({label:'验收测试 · CCUS成果归档'});await action('index-run');await page.locator('#job-state').filter({hasText:/completed|done|success/}).waitFor({timeout:30000});check('Manual project text index completes without an AI model');await action('close');
 await page.locator('#ai-query').fill('CCUS');await action('ai-search');await page.locator('.searchhit').first().waitFor();check('Local knowledge search returns actual indexed file citation');
 await nav('sources');await page.getByText('ChatGPT 官方账户接口',{exact:false}).waitFor();check('Sync page truthfully reports public ChatGPT account interface unavailable');
 await nav('settings');await page.locator('[name=deepseek_url]').waitFor();check('AI controls, storage and backup settings are present');await action('theme');check('Theme can switch',await page.locator('html').getAttribute('data-theme')==='dark');await action('theme');
 await nav('files');await page.locator('[data-select]').first().check();await action('batch-trash');await action('confirm');await waitToast('已移至回收站');await nav('trash');await page.locator('[data-select]').first().check();await action('batch-restore');await waitToast('已恢复文件');check('Trash and restore workflow preserves imported entity');
 await nav('dashboard');await page.getByText('你的成果，井然有序。').waitFor();await page.waitForTimeout(5500);await page.screenshot({path:path.resolve('docs/screenshots/验收测试-首页.png'),fullPage:true});
 check('No browser JavaScript errors',errors.length===0);check('No requests to external file or AI services',requests.length===0);
 await fs.rm(path.resolve('docs/screenshots/验收测试-失败.png'),{force:true});
 console.log(JSON.stringify({passed:checks.length,checks,errors,external_requests:requests},null,2));
}catch(e){await page.screenshot({path:path.resolve('docs/screenshots/验收测试-失败.png'),fullPage:true});console.log(JSON.stringify({checks,errors,external_requests:requests,failure:String(e)},null,2));throw e;}
finally{await browser.close();}
