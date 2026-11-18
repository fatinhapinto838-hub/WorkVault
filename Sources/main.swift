import Foundation
import AppKit
import WebKit
import Darwin

let arguments=CommandLine.arguments
func argument(_ name:String)->String?{guard let i=arguments.firstIndex(of:name),i+1<arguments.count else{return nil};return arguments[i+1]}
let headless=arguments.contains("--headless")
let defaults=UserDefaults.standard
let rootPath=argument("--root") ?? defaults.string(forKey:"storage_root") ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/WorkVault").path
let webPath=argument("--web") ?? Bundle.main.resourceURL?.appendingPathComponent("Web").path ?? "Web"
let rootURL=URL(fileURLWithPath:rootPath,isDirectory:true)
let app=NSApplication.shared
if !headless { app.setActivationPolicy(.regular) } else { app.setActivationPolicy(.prohibited) }

final class AppDelegate:NSObject,NSApplicationDelegate,WKNavigationDelegate,WKUIDelegate {
    var window:NSWindow?,web:WKWebView?,server:HTTPServer?,store:Store?,ai:AIEngine?
    var timer:DispatchSourceTimer?,signals:[DispatchSourceSignal]=[]
    var rootFD:Int32 = -1
    let worker=DispatchQueue(label:"WorkVault.Monitor",qos:.utility)
    func applicationDidFinishLaunching(_ n:Notification){
        do{
            try FileManager.default.createDirectory(at:rootURL,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            rootFD=Darwin.open(rootURL.appendingPathComponent(".workvault.lock").path,O_CREAT|O_RDWR,0o600)
            guard rootFD>=0,flock(rootFD,LOCK_EX|LOCK_NB)==0 else{throw HTTPFailure(message:"文件库已被另一个 WorkVault 实例使用，请先退出另一实例。")}
            let s=try Store(root:rootURL); try s.recoverInterruptedImports();store=s
            let engine=try AIEngine(store:s);ai=engine
            s.externalRPC = { [weak self] p in
                if let self=self,let out=try self.native(p){return out}
                return try engine.rpc(p)
            }
            let srv=HTTPServer(store:s,webRoot:URL(fileURLWithPath:webPath));server=srv
            srv.dispatch = { [weak self] p in
                guard let self=self else{throw HTTPFailure(message:"应用已退出")}
                let action=p["action"] as? String ?? ""
                let changing=["migrate","setup","switch_library"].contains(action)
                if changing { s.lock.lock() }
                defer { if changing { s.lock.unlock() } }
                if changing, engine.hasActiveJobs { throw HTTPFailure(message:"请先取消或等待 AI 任务结束，再切换文件库") }
                let candidate = action == "migrate" ? p["destination"] as? String : action == "setup" ? p["root"] as? String : action == "switch_library" ? p["path"] as? String : nil
                var newFD:Int32 = -1
                var committed=false
                defer { if newFD>=0 && !committed { flock(newFD,LOCK_UN);Darwin.close(newFD) } }
                if let candidate=candidate,URL(fileURLWithPath:candidate).standardizedFileURL.path != s.root.path {
                    let target=URL(fileURLWithPath:candidate).standardizedFileURL
                    if action != "switch_library" { try FileManager.default.createDirectory(at:target,withIntermediateDirectories:true) }
                    newFD=Darwin.open(target.appendingPathComponent(".workvault.lock").path,O_CREAT|O_RDWR,0o600)
                    guard newFD>=0,flock(newFD,LOCK_EX|LOCK_NB)==0 else { throw HTTPFailure(message:"目标文件库正被另一个实例使用或不可写") }
                }
                let result=try s.rpc(p)
                if action == "settings_save" { self.rescheduleMonitor() }
                if newFD>=0 {
                    flock(self.rootFD,LOCK_UN);Darwin.close(self.rootFD);self.rootFD=newFD;committed=true
                }
                if !headless, argument("--root")==nil { defaults.set(s.root.path,forKey:"storage_root") }
                return result
            }
            srv.onReady = { [weak self] url in
                if let ready=argument("--ready-file") {
                    let data=try? JSONSerialization.data(withJSONObject:["url":url.absoluteString,"pid":ProcessInfo.processInfo.processIdentifier],options:[.sortedKeys])
                    FileManager.default.createFile(atPath:ready,contents:data,attributes:[.posixPermissions:0o600])
                }
                DispatchQueue.main.async { self?.launchWindow(url) }
            }
            try srv.start(port:UInt16(argument("--port") ?? "0") ?? 0)
            timer=DispatchSource.makeTimerSource(queue:worker)
            rescheduleMonitor()
            timer?.setEventHandler { [weak self] in guard let self=self,let s=self.store else{return}; _=try? s.rpc(["action":"scan"]) }
            timer?.resume()
            for sig in [SIGINT,SIGTERM]{signal(sig,SIG_IGN);let source=DispatchSource.makeSignalSource(signal:sig,queue:.main);source.setEventHandler{NSApp.terminate(nil)};source.resume();signals.append(source)}
        }catch{
            fputs("WorkVault: \(error.localizedDescription)\n",stderr)
            if !headless{let alert=NSAlert();alert.messageText="WorkVault 无法启动";alert.informativeText=error.localizedDescription;alert.runModal()}
            NSApp.terminate(nil)
        }
    }
    func launchWindow(_ url:URL){
        guard !headless else{return}
        let config=WKWebViewConfiguration();config.websiteDataStore = .nonPersistent()
        let w=WKWebView(frame:.zero,configuration:config);w.navigationDelegate=self;w.uiDelegate=self
        w.allowsBackForwardNavigationGestures=true
        let win=NSWindow(contentRect:NSRect(x:0,y:0,width:1280,height:840),styleMask:[.titled,.closable,.miniaturizable,.resizable,.fullSizeContentView],backing:.buffered,defer:false)
        win.title="WorkVault";win.minSize=NSSize(width:960,height:650);win.contentView=w;win.center();win.isReleasedWhenClosed=false
        window=win;web=w
        let menu=NSMenu(),mainItem=NSMenuItem();menu.addItem(mainItem);let sub=NSMenu();mainItem.submenu=sub
        sub.addItem(withTitle:"关于 WorkVault",action:#selector(about),keyEquivalent:"")
        sub.addItem(withTitle:"在浏览器中打开",action:#selector(openBrowser),keyEquivalent:"b")
        sub.addItem(NSMenuItem.separator());sub.addItem(withTitle:"退出 WorkVault 并停止服务",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        let editItem=NSMenuItem();menu.addItem(editItem);let edit=NSMenu(title:"编辑");editItem.submenu=edit
        edit.addItem(withTitle:"撤销",action:Selector(("undo:")),keyEquivalent:"z");edit.addItem(withTitle:"剪切",action:#selector(NSText.cut(_:)),keyEquivalent:"x");edit.addItem(withTitle:"复制",action:#selector(NSText.copy(_:)),keyEquivalent:"c");edit.addItem(withTitle:"粘贴",action:#selector(NSText.paste(_:)),keyEquivalent:"v");edit.addItem(withTitle:"全选",action:#selector(NSText.selectAll(_:)),keyEquivalent:"a")
        NSApp.mainMenu=menu
        w.load(URLRequest(url:url));win.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
    }
    func rescheduleMonitor(){
        let raw=(store?.setting("watch_interval",15) as? NSNumber)?.doubleValue ?? 15
        let seconds=max(5,min(3600,raw.isFinite ? raw:15))
        timer?.schedule(deadline:.now()+seconds,repeating:seconds,leeway:.seconds(2))
    }
    @objc func about(){let alert=NSAlert();alert.messageText="WorkVault 1.2.2";alert.informativeText="本地成果管理中心 · Apple Silicon\n原始文件与数据库保存在本机。AI 仅主动触发。\n此构建为本机 ad-hoc 签名，未经 Apple 公证。";alert.runModal()}
    @objc func openBrowser(){if let url=server?.entryURL{NSWorkspace.shared.open(url)}}
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool{true}
    func applicationWillTerminate(_ n:Notification){timer?.cancel();ai?.stop();server?.stop();if rootFD>=0{flock(rootFD,LOCK_UN);Darwin.close(rootFD)};if let ready=argument("--ready-file"){try? FileManager.default.removeItem(atPath:ready)}}
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows flag:Bool)->Bool{window?.makeKeyAndOrderFront(nil);return true}
    func onMain<T>(_ work:()->T)->T{if Thread.isMainThread{return work()};return DispatchQueue.main.sync(execute:work)}
    func native(_ p:[String:Any])throws->[String:Any]?{
        guard let action=p["action"] as? String else{return nil}
        switch action{
        case "choose_directory","choose_files":
            if headless{return ["cancelled":true]}
            return onMain {
                let panel=NSOpenPanel();panel.canChooseDirectories=action=="choose_directory" || p["directory"] as? Bool == true;panel.canChooseFiles=action=="choose_files" && p["directory"] as? Bool != true;panel.allowsMultipleSelection=p["multiple"] as? Bool ?? (action=="choose_files");panel.canCreateDirectories=action=="choose_directory";panel.prompt="选择";panel.message=action=="choose_directory" ? "仅访问您明确选择的文件夹":"选择导入文件或目录；原文件会保留"
                NSApp.activate(ignoringOtherApps:true)
                guard panel.runModal() == .OK else{return ["cancelled":true]}
                if action=="choose_directory"{return ["path":panel.url!.path]}
                return ["paths":panel.urls.map{$0.path}]
            }
        case "open_browser":DispatchQueue.main.async{self.openBrowser()};return ["ok":true]
        case "shutdown","quit":DispatchQueue.main.asyncAfter(deadline:.now()+0.3){NSApp.terminate(nil)};return ["ok":true]
        case "resources":
            var usage=rusage();getrusage(RUSAGE_SELF,&usage)
            return ["pid":ProcessInfo.processInfo.processIdentifier,"peak_memory_bytes":usage.ru_maxrss,"cpu_user_seconds":Double(usage.ru_utime.tv_sec)+Double(usage.ru_utime.tv_usec)/1e6,"cpu_system_seconds":Double(usage.ru_stime.tv_sec)+Double(usage.ru_stime.tv_usec)/1e6,"active_processors":ProcessInfo.processInfo.activeProcessorCount,"physical_memory":ProcessInfo.processInfo.physicalMemory,"uptime":ProcessInfo.processInfo.systemUptime,"ai_managed_processes":0]
        case "startup_status":return ["enabled":FileManager.default.fileExists(atPath:startupURL.path)]
        case "startup_set":
            guard !headless else{throw HTTPFailure(message:"无界面测试实例不可修改登录启动")}
            let enabled=p["enabled"] as? Bool ?? false
            if enabled {
                guard Bundle.main.bundleURL.pathExtension=="app" else{throw HTTPFailure(message:"请从已安装的 WorkVault.app 设置登录启动")}
                try FileManager.default.createDirectory(at:startupURL.deletingLastPathComponent(),withIntermediateDirectories:true)
                let plist:[String:Any]=["Label":"local.WorkVault.login","ProgramArguments":["/usr/bin/open",Bundle.main.bundleURL.path],"RunAtLoad":true,"LimitLoadToSessionType":"Aqua"]
                try PropertyListSerialization.data(fromPropertyList:plist,format:.xml,options:0).write(to:startupURL,options:.atomic)
            }else if FileManager.default.fileExists(atPath:startupURL.path){try FileManager.default.removeItem(at:startupURL)}
            return ["enabled":enabled,"note":"下次登录生效；退出应用会停止本地服务"]
        default:return nil
        }
    }
    var startupURL:URL{FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/local.WorkVault.login.plist")}
    func webView(_ webView:WKWebView,decidePolicyFor navigationAction:WKNavigationAction,decisionHandler:@escaping(WKNavigationActionPolicy)->Void){
        guard let u=navigationAction.request.url else{decisionHandler(.cancel);return}
        if u.host=="127.0.0.1",u.port==Int(server?.port ?? 0){decisionHandler(.allow);return}
        if navigationAction.navigationType == .linkActivated,["https","http"].contains(u.scheme ?? ""){NSWorkspace.shared.open(u)}
        decisionHandler(.cancel)
    }
    func webView(_ webView:WKWebView,runJavaScriptAlertPanelWithMessage message:String,initiatedByFrame frame:WKFrameInfo,completionHandler:@escaping()->Void){let a=NSAlert();a.messageText="WorkVault";a.informativeText=message;a.runModal();completionHandler()}
    func webView(_ webView:WKWebView,runJavaScriptConfirmPanelWithMessage message:String,initiatedByFrame frame:WKFrameInfo,completionHandler:@escaping(Bool)->Void){let a=NSAlert();a.messageText="确认操作";a.informativeText=message;a.addButton(withTitle:"确认");a.addButton(withTitle:"取消");completionHandler(a.runModal() == .alertFirstButtonReturn)}
    func webView(_ webView:WKWebView,runJavaScriptTextInputPanelWithPrompt prompt:String,defaultText:String?,initiatedByFrame frame:WKFrameInfo,completionHandler:@escaping(String?)->Void){let a=NSAlert();a.messageText=prompt;let input=NSTextField(frame:NSRect(x:0,y:0,width:360,height:26));input.stringValue=defaultText ?? "";a.accessoryView=input;a.addButton(withTitle:"确定");a.addButton(withTitle:"取消");completionHandler(a.runModal() == .alertFirstButtonReturn ? input.stringValue:nil)}
}
let delegate=AppDelegate();app.delegate=delegate;app.run()
