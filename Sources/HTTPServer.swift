import Foundation
import Network

struct HTTPFailure: LocalizedError { let message: String; var errorDescription: String? { message } }
final class HTTPServer {
    let store: Store
    let webRoot: URL
    let token = UUID().uuidString + UUID().uuidString
    var listener: NWListener?
    var port: UInt16 = 0
    var dispatch: (([String:Any]) throws -> [String:Any])!
    var onReady: ((URL)->Void)?
    private let queue = DispatchQueue(label:"WorkVault.HTTP", attributes:.concurrent)
    private let countLock = NSLock()
    private var connections = 0
    init(store:Store,webRoot:URL) { self.store=store; self.webRoot=webRoot }
    var origin:String { "http://127.0.0.1:\(port)" }
    var entryURL:URL { URL(string:origin + "/?token=" + token)! }
    func start(port requested:UInt16 = 0) throws {
        let params=NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host:"127.0.0.1",port:NWEndpoint.Port(rawValue:requested)!)
        let l=try NWListener(using:params)
        listener=l
        l.stateUpdateHandler = { [weak self] state in
            guard let self=self else{return}
            switch state {
            case .ready: self.port=l.port!.rawValue; self.onReady?(self.entryURL)
            case .failed(let e): fputs("WorkVault HTTP: \(e.localizedDescription)\n",stderr)
            default:break
            }
        }
        l.newConnectionHandler = { [weak self] c in
            guard let self=self else {c.cancel();return}
            self.countLock.lock(); let allowed=self.connections < 24
            if allowed { self.connections += 1 }; self.countLock.unlock()
            guard allowed else { c.cancel();return }
            let request=HTTPConnection(connection:c,server:self)
            request.start()
        }
        l.start(queue:queue)
    }
    func released(){ countLock.lock();connections -= 1;countLock.unlock() }
    func stop(){listener?.cancel()}
}
final class HTTPConnection {
    let c:NWConnection
    unowned let server:HTTPServer
    let queue=DispatchQueue(label:"WorkVault.Connection")
    var buffer=Data(), body=Data()
    var parsed=false, responding=false, closed=false
    var method="", path="", query:[String:String]=[:], headers:[String:String]=[:]
    var length:Int64=0,received:Int64=0
    var uploadURL:URL?,upload:FileHandle?
    var timeout:DispatchWorkItem?
    init(connection:NWConnection,server:HTTPServer){self.c=connection;self.server=server}
    func start(){
        c.stateUpdateHandler={ [self] state in if case .failed = state { close() }; if case .cancelled = state { close() } }
        c.start(queue:queue)
        let work=DispatchWorkItem{ [self] in close() };timeout=work;queue.asyncAfter(deadline:.now()+300,execute:work)
        read()
    }
    func close(){
        guard !closed else{return};closed=true;timeout?.cancel();try? upload?.close();upload=nil
        if let u=uploadURL{try? FileManager.default.removeItem(at:u)}
        server.released();c.cancel();c.stateUpdateHandler=nil
    }
    func read(){
        guard !closed,!responding else{return}
        c.receive(minimumIncompleteLength:1,maximumLength:262144){ [self] data,_,complete,error in
            do {
                if let data=data,!data.isEmpty {
                    if !parsed {
                        buffer.append(data)
                        if let range=buffer.range(of:Data("\r\n\r\n".utf8)) {
                            guard range.lowerBound <= 16384 else{throw HTTPFailure(message:"请求头过大")}
                            let head=buffer.subdata(in:0..<range.lowerBound)
                            let rest=buffer.subdata(in:range.upperBound..<buffer.count);buffer.removeAll()
                            try parse(head);parsed=true
                            if responding{return}
                            try consume(rest)
                        } else if buffer.count>16384 {throw HTTPFailure(message:"请求头过大")}
                    } else {try consume(data)}
                }
                if parsed && received==length { try finish();return }
                if error != nil || complete {close();return}
                read()
            }catch{json(["error":error.localizedDescription],status:400)}
        }
    }
    func parse(_ data:Data)throws{
        guard let text=String(data:data,encoding:.utf8) else{throw HTTPFailure(message:"无效请求")}
        let lines=text.components(separatedBy:"\r\n"), first=lines[0].split(separator:" ")
        guard first.count==3,["GET","POST"].contains(String(first[0])) else{throw HTTPFailure(message:"不支持的方法")}
        method=String(first[0])
        guard let parts=URLComponents(string:"http://127.0.0.1"+String(first[1])), !String(first[1]).contains("\0") else{throw HTTPFailure(message:"无效路径")}
        path=parts.path
        for item in parts.queryItems ?? [] {query[item.name]=item.value ?? ""}
        for line in lines.dropFirst(){if let colon=line.firstIndex(of:":"){let key=line[..<colon].lowercased(); guard headers[key]==nil else{throw HTTPFailure(message:"重复请求头")};headers[key]=line[line.index(after:colon)...].trimmingCharacters(in:.whitespaces)}}
        guard headers["host"] == "127.0.0.1:\(server.port)" else{json(["error":"Host 校验失败"],status:403);return}
        if let origin=headers["origin"],origin != server.origin {json(["error":"Origin 校验失败"],status:403);return}
        guard headers["transfer-encoding"]==nil else{throw HTTPFailure(message:"需指定 Content-Length")}
        if let l=headers["content-length"] {guard let n=Int64(l), n>=0 else{throw HTTPFailure(message:"无效长度")};length=n}
        if method=="GET" && length != 0{throw HTTPFailure(message:"无效 GET")}
        if path=="/health",method=="GET"{json(["status":"ok","version":"1.3.0"]);return}
        if path=="/",method=="GET",query["token"]==server.token {
            send(status:303,headers:["Location":"/","Set-Cookie":"wv_session=\(server.token); HttpOnly; SameSite=Strict; Path=/"],data:Data());return
        }
        let cookies=(headers["cookie"] ?? "").components(separatedBy:";").map{$0.trimmingCharacters(in:.whitespaces)}
        guard cookies.contains("wv_session=\(server.token)") else{json(["error":"请从 WorkVault 应用打开已授权界面"],status:401);return}
        if method=="POST" {
            if path=="/api/upload" {
                guard length <= 2*1024*1024*1024 else{throw HTTPFailure(message:"网页上传上限 2 GiB；大文件请使用原生选择导入")}
                let u=server.store.root.appendingPathComponent("tmp/upload-"+UUID().uuidString+".partial")
                FileManager.default.createFile(atPath:u.path,contents:nil,attributes:[.posixPermissions:0o600]);uploadURL=u;upload=try FileHandle(forWritingTo:u)
            }else{
                guard path=="/api/rpc",headers["content-type"]?.lowercased().hasPrefix("application/json")==true,length<=2*1024*1024 else{throw HTTPFailure(message:"RPC 仅接受不超过 2 MiB 的 JSON")}
            }
        }
    }
    func consume(_ data:Data)throws{
        guard !responding else{return};received += Int64(data.count)
        guard received<=length else{throw HTTPFailure(message:"请求长度不匹配")}
        if let upload=upload{try upload.write(contentsOf:data)}else{body.append(data)}
    }
    func finish()throws{
        guard !responding else{return}
        if method=="POST" {
            if path=="/api/upload",let u=uploadURL {
                try upload?.synchronize();try upload?.close();upload=nil
                let raw=query["name"] ?? "upload.bin",name=URL(fileURLWithPath:raw).lastPathComponent
                guard !name.isEmpty,name != ".",name != "..",!name.contains("\0") else{throw HTTPFailure(message:"无效文件名")}
                let result=try server.store.importFile(path:u.path,name:name,projectID:query["project_id"].flatMap{$0.isEmpty ? nil:$0},source:"upload",confirmed:query["confirmed"]=="true")
                json(result)
            }else{
                guard let obj=try JSONSerialization.jsonObject(with:body) as? [String:Any],obj["action"] is String else{throw HTTPFailure(message:"缺少 action")}
                let result=try server.dispatch(obj);json(result)
            }
        }else if path.hasPrefix("/content/"){
            let id=String(path.dropFirst("/content/".count))
            let url=try server.store.blobURL(fileID:id,versionID:query["version"])
            let info=try server.store.rpc(["action":"file_detail","id":id])
            let file=info["file"] as? [String:Any] ?? [:]
            let name=file["name"] as? String ?? "file"
            let ext=(name as NSString).pathExtension.lowercased()
            let allowed=["pdf":"application/pdf","png":"image/png","jpg":"image/jpeg","jpeg":"image/jpeg","webp":"image/webp","gif":"image/gif","txt":"text/plain; charset=utf-8"]
            let type=allowed[ext] ?? "application/octet-stream"
            let attr=try FileManager.default.attributesOfItem(atPath:url.path),size=(attr[.size] as? NSNumber)?.int64Value ?? 0
            var start:Int64=0,end=size-1,status=200
            if let range=headers["range"],range.hasPrefix("bytes="),!range.contains(",") {
                let bits=range.dropFirst(6).split(separator:"-",omittingEmptySubsequences:false)
                if bits.count==2, let low=Int64(bits[0]),low>=0,low<size {start=low;if let high=Int64(bits[1]){end=min(high,end)};guard end>=start else{throw HTTPFailure(message:"无效范围")};status=206}
            }
            let safeName=name.replacingOccurrences(of:"\r",with:"").replacingOccurrences(of:"\n",with:"")
            var h=["Content-Type":type,"Content-Disposition":"inline; filename*=UTF-8''"+(safeName.addingPercentEncoding(withAllowedCharacters:.urlPathAllowed) ?? "file"),"Accept-Ranges":"bytes","Content-Length":"\(max(0,end-start+1))"]
            if status==206{h["Content-Range"]="bytes \(start)-\(end)/\(size)"}
            let handle=try FileHandle(forReadingFrom:url);try handle.seek(toOffset:UInt64(start))
            responding=true
            c.send(content:header(status:status,headers:h),completion:.contentProcessed{ [self] e in if e != nil {try? handle.close();close()}else{stream(handle,remaining:max(0,end-start+1))}})
        }else{
            let routes=["/":"index.html","/index.html":"index.html","/app.js":"app.js","/styles.css":"styles.css"]
            guard let name=routes[path] else{json(["error":"页面不存在"],status:404);return}
            let url=server.webRoot.appendingPathComponent(name),data=try Data(contentsOf:url)
            let type=name.hasSuffix(".js") ? "text/javascript; charset=utf-8" : name.hasSuffix(".css") ? "text/css; charset=utf-8":"text/html; charset=utf-8"
            send(status:200,headers:["Content-Type":type],data:data)
        }
    }
    func stream(_ f:FileHandle,remaining:Int64){
        if remaining==0{try? f.close();close();return}
        do{let data=try f.read(upToCount:Int(min(262144,remaining))) ?? Data();guard !data.isEmpty else{try? f.close();close();return};c.send(content:data,completion:.contentProcessed{ [self] e in if e != nil{try? f.close();close()}else{stream(f,remaining:remaining-Int64(data.count))}})}catch{try? f.close();close()}
    }
    func header(status:Int,headers:[String:String])->Data{
        let labels=[200:"OK",206:"Partial Content",303:"See Other",400:"Bad Request",401:"Unauthorized",403:"Forbidden",404:"Not Found"]
        var all=["Connection":"close","Cache-Control":"no-store","X-Content-Type-Options":"nosniff","Referrer-Policy":"no-referrer","X-Frame-Options":"SAMEORIGIN","Content-Security-Policy":"default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; frame-src 'self'; connect-src 'self'; object-src 'none'; base-uri 'none'; form-action 'self'; frame-ancestors 'self'"]
        for(k,v) in headers{all[k]=v}
        return Data(("HTTP/1.1 \(status) \(labels[status] ?? "Error")\r\n"+all.map{"\($0.key): \($0.value)\r\n"}.joined()+"\r\n").utf8)
    }
    func send(status:Int,headers:[String:String],data:Data){
        guard !responding else{return};responding=true;var h=headers;h["Content-Length"]="\(data.count)"
        c.send(content:header(status:status,headers:h)+data,completion:.contentProcessed{ [self] _ in close() })
    }
    func json(_ obj:[String:Any],status:Int=200){let d=(try? JSONSerialization.data(withJSONObject:obj,options:[.sortedKeys])) ?? Data("{\"error\":\"JSON 编码失败\"}".utf8);send(status:status,headers:["Content-Type":"application/json; charset=utf-8"],data:d)}
}
