// Real isolated service and browser. No account/model mocks; no native file writes.
import fs from 'node:fs/promises';
import {createRequire} from 'node:module';
const require=createRequire(import.meta.url),{chromium}=require('playwright');
const ready=JSON.parse(await fs.readFile(process.argv[2],'utf8')),fixture=JSON.parse(await fs.readFile(process.argv[3],'utf8'));
const browser=await chromium.launch({executablePath:'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless:true,args:['--disable-background-networking','--disable-component-update']});
const page=await browser.newPage({viewport:{width:1440,height:1000}}),checks=[],errors=[],external=[];
page.on('pageerror',e=>errors.push(String(e)));page.on('request',r=>{if(!['127.0.0.1','localhost'].includes(new URL(r.url()).hostname))external.push(r.url());});
const check=(name,ok)=>{checks.push({name,passed:!!ok});if(!ok)throw new Error(name);};
async function nav(name){await page.locator(`.sidebar [data-page=${name}]`).click();await page.locator('.loading').waitFor({state:'detached'});}
async function query(selector,value,action){const response=page.waitForResponse(r=>{try{const d=r.request().postDataJSON();return d?.action===action&&d.q===value;}catch{return false;}});await page.locator(selector).fill(value);await response;await page.waitForTimeout(200);await page.locator('.loading').waitFor({state:'detached'});}
try{
 await page.goto(ready.url);await page.locator('.sidebar').waitFor();
 const response=page.waitForResponse(r=>{try{const d=r.request().postDataJSON();return d?.action==='files'&&d.q==='CCUS';}catch{return false;}});await page.locator('#global-search').fill('CCUS');await page.locator('#global-search').press('Enter');await response;await page.locator('#file-q').waitFor();await page.locator('[data-search-excludes-md]').waitFor();
 let names=await page.locator('tr[data-file] .name').allTextContents();check('Global project/file search returns only non-Markdown files',names.length===3&&names.every(n=>!/\.(md|markdown)$/i.test(n)));
 check('Search shows the Markdown exclusion clearly',await page.locator('[data-search-excludes-md]').isVisible());
 await query('#file-q','MarkdownOnlyXYZ','files');check('Markdown-only filenames produce no file matches',await page.locator('tr[data-file]').count()===0);
 await query('#file-q','','files');names=await page.locator('tr[data-file] .name').allTextContents();check('Clearing search restores ordinary Markdown browsing',names.some(n=>/\.(md|markdown)$/i.test(n)));
 await page.locator('#file-ext').selectOption('md');await page.waitForTimeout(200);await page.locator('.loading').waitFor({state:'detached'});await query('#file-q','CCUS','files');check('A previous MD format filter resets when keyword search begins',await page.locator('#file-ext').inputValue()===''&&await page.locator('tr[data-file]').count()===3);
 await nav('projects');await page.locator('#project-search').fill('OnlyNotes');check('Projects are still searchable by title without returning note files',await page.locator('.projectcard').count()===1);
 await nav('deliverables');await query('#final-q','CCUS','deliverables');check('Final-output keyword search also excludes Markdown',await page.locator('.deliverable-card').count()===3&&!(await page.locator('.deliverable-filename>a').allTextContents()).some(n=>/\.(md|markdown)$/i.test(n)));
 await query('#final-q','MarkdownOnlyXYZ','deliverables');check('A note filename does not create a matching final-project group',await page.locator('[data-final-group]').count()===0);
 await query('#final-q','OnlyNotes','deliverables');check('A matched project title remains accessible with zero non-Markdown final matches',await page.locator('[data-final-group]').count()===1&&await page.locator('.deliverable-card').count()===0);
 await query('#final-q','','deliverables');await page.locator('#final-project').selectOption(fixture.b);await page.waitForTimeout(200);await page.locator('.loading').waitFor({state:'detached'});check('Cleared final-output search still displays both stored Markdown versions',await page.locator('.deliverable-card').count()===2);
 check('No JavaScript errors or external requests',errors.length===0&&external.length===0);
 console.log(JSON.stringify({passed:checks.length,checks,errors,external_requests:external}));
}catch(e){console.log(JSON.stringify({checks,errors,failure:String(e)}));throw e;}finally{await browser.close();}
