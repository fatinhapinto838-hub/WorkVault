import Foundation
import AppKit
import CryptoKit
import PDFKit
import Darwin

final class Store {
    private static let supportedSchemaVersion = 6
    var root: URL
    var db: DB
    let lock=NSRecursiveLock()
    var externalRPC: (([String:Any]) throws -> [String:Any]?)?
    private let fm=FileManager.default
    private var cancellations=Set<String>()
    private var importing=false
    init(root:URL) throws {
        self.root=root.standardizedFileURL
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories:true)
        let databaseURL=self.root.appendingPathComponent("workvault.sqlite")
        if FileManager.default.fileExists(atPath:databaseURL.path) {
            let prior=try DB(databaseURL,readOnly:true)
            let userVersion=try prior.query("PRAGMA user_version").first?["user_version"] as? Int ?? 0
            guard userVersion<=Self.supportedSchemaVersion else { throw fail("文件库来自更新版本，当前应用不能打开") }
            if !(try prior.query("SELECT name FROM sqlite_master WHERE name='schema_migrations'")).isEmpty {
                let version=try prior.query("SELECT max(version) version FROM schema_migrations").first?["version"] as? Int ?? 0
                guard version<=Self.supportedSchemaVersion else { throw fail("文件库结构较新，当前应用不会修改该数据库") }
            }
            try prior.close()
        }
        db=try DB(databaseURL)
        try folders()
        try schema()
    }
    func folders() throws {
        for p in ["blobs","working","tmp","previews","indexes","logs","backups"] { try fm.createDirectory(at:root.appendingPathComponent(p),withIntermediateDirectories:true) }
        try? fm.setAttributes([.posixPermissions:0o700],ofItemAtPath:root.path)
    }
    private func schema() throws {
        let statements=[
        "CREATE TABLE IF NOT EXISTS schema_migrations(version INTEGER PRIMARY KEY,applied_at TEXT NOT NULL)",
        "CREATE TABLE IF NOT EXISTS projects(id TEXT PRIMARY KEY,title TEXT NOT NULL,original_title TEXT NOT NULL,title_source TEXT NOT NULL,title_obtained_at TEXT NOT NULL,conversation_id TEXT,source_url TEXT,category TEXT NOT NULL DEFAULT '未分类',description TEXT NOT NULL DEFAULT '',status TEXT NOT NULL DEFAULT '进行中',tags TEXT NOT NULL DEFAULT '[]',created_at TEXT NOT NULL,updated_at TEXT NOT NULL,deepseek_allowed INTEGER NOT NULL DEFAULT 0,source_confirmed INTEGER NOT NULL DEFAULT 1)",
        "CREATE UNIQUE INDEX IF NOT EXISTS project_conversation ON projects(conversation_id) WHERE conversation_id IS NOT NULL AND conversation_id<>''",
        "CREATE TABLE IF NOT EXISTS blobs(hash TEXT PRIMARY KEY,size INTEGER NOT NULL CHECK(size>=0),path TEXT NOT NULL UNIQUE)",
        "CREATE TABLE IF NOT EXISTS files(id TEXT PRIMARY KEY,name TEXT NOT NULL,ext TEXT NOT NULL,status TEXT NOT NULL CHECK(status IN ('managed','pending','trash')),favorite INTEGER NOT NULL DEFAULT 0,final INTEGER NOT NULL DEFAULT 0,tags TEXT NOT NULL DEFAULT '[]',current_version TEXT,created_at TEXT NOT NULL,updated_at TEXT NOT NULL)",
        "CREATE TABLE IF NOT EXISTS versions(id TEXT PRIMARY KEY,file_id TEXT NOT NULL REFERENCES files(id) ON DELETE CASCADE,hash TEXT NOT NULL REFERENCES blobs(hash),size INTEGER NOT NULL,created_at TEXT NOT NULL,source TEXT NOT NULL,note TEXT NOT NULL DEFAULT '',is_final INTEGER NOT NULL DEFAULT 0)",
        "CREATE TABLE IF NOT EXISTS file_projects(file_id TEXT NOT NULL REFERENCES files(id) ON DELETE CASCADE,project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,PRIMARY KEY(file_id,project_id))",
        "CREATE TABLE IF NOT EXISTS project_deliverables(project_id TEXT NOT NULL,file_id TEXT NOT NULL,version_id TEXT NOT NULL REFERENCES versions(id) ON DELETE CASCADE,display_name TEXT NOT NULL,evidence_source TEXT NOT NULL,evidence_note TEXT NOT NULL DEFAULT '',source_path TEXT,selected_at TEXT NOT NULL,delivered_at TEXT,time_source TEXT NOT NULL DEFAULT 'collection',PRIMARY KEY(project_id,file_id,version_id),FOREIGN KEY(file_id,project_id) REFERENCES file_projects(file_id,project_id) ON DELETE CASCADE)",
        "CREATE INDEX IF NOT EXISTS deliverables_project ON project_deliverables(project_id,selected_at DESC)",
        "CREATE INDEX IF NOT EXISTS deliverables_file ON project_deliverables(file_id,version_id)",
        "CREATE INDEX IF NOT EXISTS versions_hash ON versions(hash)",
        "CREATE INDEX IF NOT EXISTS files_current_version ON files(current_version)",
        "CREATE TABLE IF NOT EXISTS provenance(id TEXT PRIMARY KEY,file_id TEXT REFERENCES files(id),source TEXT NOT NULL,source_path TEXT,original_name TEXT,confidence TEXT NOT NULL,imported_at TEXT NOT NULL,task_title TEXT,status TEXT NOT NULL,error TEXT)",
        "CREATE TABLE IF NOT EXISTS categories(id TEXT PRIMARY KEY,name TEXT NOT NULL UNIQUE,position INTEGER NOT NULL)",
        "CREATE TABLE IF NOT EXISTS sources(id TEXT PRIMARY KEY,path TEXT NOT NULL UNIQUE,kind TEXT NOT NULL,enabled INTEGER NOT NULL DEFAULT 1,last_scan TEXT,error TEXT)",
        "CREATE TABLE IF NOT EXISTS source_seen(source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,path TEXT NOT NULL,fingerprint TEXT NOT NULL,stable INTEGER NOT NULL DEFAULT 0,hash TEXT,file_id TEXT,PRIMARY KEY(source_id,path))",
        "CREATE TABLE IF NOT EXISTS import_jobs(id TEXT PRIMARY KEY,status TEXT NOT NULL,created_at TEXT NOT NULL,updated_at TEXT NOT NULL,total INTEGER NOT NULL,processed INTEGER NOT NULL DEFAULT 0,error TEXT,request TEXT NOT NULL)",
        "CREATE TABLE IF NOT EXISTS events(id TEXT PRIMARY KEY,project_id TEXT,file_id TEXT,kind TEXT NOT NULL,message TEXT NOT NULL,created_at TEXT NOT NULL)",
        "CREATE TABLE IF NOT EXISTS sync_logs(id TEXT PRIMARY KEY,source_id TEXT,status TEXT NOT NULL,message TEXT NOT NULL,created_at TEXT NOT NULL)",
        "CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY,value TEXT NOT NULL)",
        "CREATE TABLE IF NOT EXISTS project_sources(id TEXT PRIMARY KEY,project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,conversation_id TEXT,title TEXT NOT NULL,title_source TEXT NOT NULL,source_url TEXT,obtained_at TEXT NOT NULL,confidence TEXT NOT NULL)",
        "CREATE UNIQUE INDEX IF NOT EXISTS source_conversation ON project_sources(conversation_id) WHERE conversation_id IS NOT NULL AND conversation_id<>''",
        "CREATE TABLE IF NOT EXISTS missing_attachments(id TEXT PRIMARY KEY,project_id TEXT REFERENCES projects(id),conversation_id TEXT,name TEXT,metadata TEXT NOT NULL,status TEXT NOT NULL DEFAULT '需要补充原文件')",
        "CREATE TABLE IF NOT EXISTS backups(id TEXT PRIMARY KEY,path TEXT NOT NULL,created_at TEXT NOT NULL,files INTEGER NOT NULL)",
        "CREATE VIRTUAL TABLE IF NOT EXISTS metadata_fts USING fts5(file_id UNINDEXED,name,tags,tokenize='unicode61')",
        "CREATE INDEX IF NOT EXISTS files_status_date ON files(status,updated_at)",
        "CREATE INDEX IF NOT EXISTS versions_file ON versions(file_id,created_at)",
        "CREATE INDEX IF NOT EXISTS provenance_file ON provenance(file_id,imported_at)",
        "CREATE INDEX IF NOT EXISTS relations_project ON file_projects(project_id,file_id)",
        "CREATE INDEX IF NOT EXISTS events_project ON events(project_id,created_at)",
        "CREATE INDEX IF NOT EXISTS files_ext ON files(ext,status)"
        ]
        try db.transaction { for s in statements { try db.exec(s) }; try db.exec("INSERT OR IGNORE INTO schema_migrations VALUES(1,?)",[now()]) }
        if !(try db.query("PRAGMA table_info(projects)")).contains(where: { $0["name"] as? String == "source_confirmed" }) { try db.exec("ALTER TABLE projects ADD COLUMN source_confirmed INTEGER NOT NULL DEFAULT 1") }; try db.exec("INSERT OR IGNORE INTO schema_migrations VALUES(2,?)",[now()]); try db.exec("INSERT OR IGNORE INTO schema_migrations VALUES(3,?)",[now()])
        try db.exec("INSERT OR IGNORE INTO project_sources(id,project_id,conversation_id,title,title_source,source_url,obtained_at,confidence) SELECT id,id,conversation_id,original_title,title_source,source_url,title_obtained_at,CASE WHEN source_confirmed=1 THEN '用户确认' ELSE '待确认' END FROM projects p WHERE NOT EXISTS(SELECT 1 FROM project_sources ps WHERE ps.project_id=p.id)")
        if try db.query("SELECT version FROM schema_migrations WHERE version=4").isEmpty {
            try db.transaction {
                // Preserve explicit legacy final markers; never infer a final from its filename.
                try db.exec("INSERT OR IGNORE INTO project_deliverables(project_id,file_id,version_id,display_name,evidence_source,evidence_note,selected_at) SELECT r.project_id,f.id,coalesce((SELECT v.id FROM versions v WHERE v.file_id=f.id AND v.is_final=1 ORDER BY v.created_at DESC,v.rowid DESC LIMIT 1),f.current_version),f.name,'legacy_final','迁移已有最终成果标记',? FROM files f JOIN file_projects r ON r.file_id=f.id WHERE f.status='managed' AND f.final=1",[now()])
                try db.exec("INSERT INTO schema_migrations VALUES(4,?)",[now()])
            }
        }
        try db.transaction {
            let columns=try db.query("PRAGMA table_info(project_deliverables)").compactMap{$0["name"] as? String}
            if !columns.contains("delivered_at") { try db.exec("ALTER TABLE project_deliverables ADD COLUMN delivered_at TEXT") }
            if !columns.contains("time_source") { try db.exec("ALTER TABLE project_deliverables ADD COLUMN time_source TEXT NOT NULL DEFAULT 'collection'") }
            try db.exec("CREATE INDEX IF NOT EXISTS deliverables_time ON project_deliverables(project_id,coalesce(delivered_at,selected_at) DESC,selected_at DESC)")
            try db.exec("INSERT OR IGNORE INTO schema_migrations VALUES(5,?)",[now()])
            let codexSourceSchema = try db.query("SELECT version FROM schema_migrations WHERE version=6")
            try db.exec(codexSourceSchema.isEmpty ? "PRAGMA user_version=5" : "PRAGMA user_version=6")
        }
        if try db.query("SELECT id FROM categories LIMIT 1").isEmpty {
            for (i,n) in ["石油工程","CCUS 与碳封存","科研文献","考研学习","职业规划","行业研究","AI 与软件开发","其他项目","未分类"].enumerated() { try db.exec("INSERT INTO categories VALUES(?,?,?)",[uuid(),n,i]) }
        }
    }
    func setting(_ key:String,_ fallback:Any? = nil) -> Any? {
        guard let value=try? db.query("SELECT value FROM settings WHERE key=?",[key]).first?["value"] as? String else { return fallback }
        return jsonValue(value) ?? fallback
    }
    func setSetting(_ key:String,_ value:Any) throws { try db.exec("INSERT INTO settings(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",[key,jsonString(value)]) }
    private static let fileSearchExclusionKey = "file_search_excluded_extensions"
    private static let defaultFileSearchExclusions = ["md","markdown","ts","js","json","tsx","jsx","css"]

    private func normalizeFileSearchExclusions(_ value:Any) throws -> [String] {
        guard let entries=value as? [String],entries.count<=100 else {
            throw fail("最多可设置 100 个搜索排除后缀。")
        }
        var seen=Set<String>()
        var result:[String]=[]
        for entry in entries {
            let trimmed=entry.trimmingCharacters(in:.whitespacesAndNewlines).lowercased()
            let suffix=trimmed.hasPrefix(".") ? String(trimmed.dropFirst()) : trimmed
            guard suffix.range(of:"^[a-z0-9][a-z0-9_+-]{0,31}$",options:.regularExpression) != nil else {
                throw fail("请输入单个文件后缀，例如 .log。后缀只接受 1–32 个英文字母、数字、下划线、连字符或加号，且须以字母或数字开头。")
            }
            if seen.insert(suffix).inserted { result.append(suffix) }
        }
        return result
    }

    private func fileSearchExclusions() -> [String] {
        guard let value=setting(Self.fileSearchExclusionKey),
              let suffixes=try? normalizeFileSearchExclusions(value) else {
            return Self.defaultFileSearchExclusions
        }
        return suffixes
    }
    func event(_ kind:String,_ message:String,project:String?=nil,file:String?=nil) throws { try db.exec("INSERT INTO events VALUES(?,?,?,?,?,?)",[uuid(),project,file,kind,message,now()]) }
    func log(_ status:String,_ message:String,source:String?=nil) throws { try db.exec("INSERT INTO sync_logs VALUES(?,?,?,?,?)",[uuid(),source,status,message,now()]) }
    private func required(_ p:[String:Any],_ k:String) throws -> String { guard let s=p[k] as? String,!s.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw fail("缺少参数：\(k)") }; return s }
    private func checkStorage() throws { guard fm.fileExists(atPath:root.appendingPathComponent("workvault.sqlite").path),fm.fileExists(atPath:root.appendingPathComponent("blobs").path) else { throw fail("文件库存储不可用，请重新连接磁盘；记录未被删除") } }
    func file(_ id:String) throws -> [String:Any] {
        guard var row=try db.query("SELECT f.*,v.hash,v.size FROM files f LEFT JOIN versions v ON v.id=f.current_version WHERE f.id=?",[id]).first else { throw fail("文件不存在") }
        row["tags"]=jsonValue(row["tags"] as? String ?? "[]") ?? []
        row["project_ids"]=try db.query("SELECT project_id FROM file_projects WHERE file_id=? ORDER BY project_id",[id]).compactMap{$0["project_id"] as? String}
        if let provenance=try db.query("SELECT source,source_path,confidence FROM provenance WHERE file_id=? ORDER BY imported_at LIMIT 1",[id]).first { row.merge(provenance){_,new in new} }
        return row
    }
    func project(_ id:String) throws -> [String:Any] {
        guard var row=try db.query("SELECT p.*,(SELECT count(*) FROM file_projects r JOIN files f ON f.id=r.file_id WHERE r.project_id=p.id AND f.status<>'trash') file_count,(SELECT count(*) FROM project_deliverables d JOIN files f ON f.id=d.file_id WHERE d.project_id=p.id AND f.status='managed') deliverable_count FROM projects p WHERE id=?",[id]).first else { throw fail("项目不存在") }
        row["tags"]=jsonValue(row["tags"] as? String ?? "[]") ?? []
        return row
    }
    func blobURL(fileID:String,versionID:String?=nil) throws -> URL {
        try checkStorage()
        let f=try file(fileID)
        let version=versionID ?? f["current_version"] as? String ?? ""
        guard let row=try db.query("SELECT b.path,b.hash FROM versions v JOIN blobs b ON b.hash=v.hash WHERE v.id=? AND v.file_id=?",[version,fileID]).first, let relative=row["path"] as? String else { throw fail("版本文件不存在") }
        guard validRelative(relative),relative.hasPrefix("blobs/") else { throw fail("文件实体路径无效") }
        let path=root.appendingPathComponent(relative).standardizedFileURL
        guard path.path.hasPrefix(root.path+"/blobs/"),fm.fileExists(atPath:path.path) else { throw fail("文件实体不可用，请检查存储磁盘") }
        _ = try regularFile(path)
        return path
    }
    static func hashFile(_ path:URL) throws -> String {
        let input=try FileHandle(forReadingFrom:path); defer { try? input.close() }
        var sha=SHA256()
        while let chunk=try input.read(upToCount:1024*1024),!chunk.isEmpty { sha.update(data:chunk) }
        return sha.finalize().map{String(format:"%02x",$0)}.joined()
    }
    private func regularFile(_ path:URL) throws -> Int64 {
        let values=try path.resourceValues(forKeys:[.isSymbolicLinkKey,.isRegularFileKey,.fileSizeKey])
        guard values.isSymbolicLink != true,values.isRegularFile == true else { throw fail("仅接受普通文件，不导入符号链接") }
        // Reject symlink ancestors as well; do not follow aliases into unrelated folders.
        var ancestor=path.deletingLastPathComponent()
        while ancestor.path != "/" {
            if (try? ancestor.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink) == true { throw fail("不接受包含符号链接的路径") }
            ancestor.deleteLastPathComponent()
        }
        guard fm.isReadableFile(atPath:path.path) else { throw fail("源文件不可读") }
        return Int64(values.fileSize ?? 0)
    }
    private func stage(_ path:URL) throws -> (hash:String,size:Int64,relative:String,created:Bool) {
        try checkStorage(); let size=try regularFile(path)
        let free=(try? fm.attributesOfFileSystem(forPath:root.path)[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        guard free>size+32*1024*1024 else { throw fail("磁盘剩余空间不足，源文件保持不变") }
        let temp=root.appendingPathComponent("tmp/\(uuid()).partial")
        defer { try? fm.removeItem(at:temp) }
        guard fm.createFile(atPath:temp.path,contents:nil,attributes:[.posixPermissions:0o600]) else { throw fail("无法创建导入临时文件") }
        let input=try FileHandle(forReadingFrom:path); let output=try FileHandle(forWritingTo:temp)
        defer { try? input.close(); try? output.close() }
        var sha=SHA256(); var written:Int64=0
        while let data=try input.read(upToCount:1024*1024),!data.isEmpty { if let job=Thread.current.threadDictionary["workvaultImportJob"] as? String,isCancelled(job) { throw fail("导入已取消；源文件保持不变") }; sha.update(data:data); try output.write(contentsOf:data); written += Int64(data.count) }
        try output.synchronize(); try output.close()
        guard written == size else { throw fail("源文件在复制过程中发生变化，请重试") }
        let hash=sha.finalize().map{String(format:"%02x",$0)}.joined()
        guard try Store.hashFile(temp) == hash,try Store.hashFile(path) == hash else { throw fail("复制校验失败，源文件可能仍在写入") }
        let relative="blobs/\(hash.prefix(2))/\(hash)"; let final=root.appendingPathComponent(relative)
        try fm.createDirectory(at:final.deletingLastPathComponent(),withIntermediateDirectories:true)
        var created=false
        if fm.fileExists(atPath:final.path) { guard try Store.hashFile(final) == hash else { throw fail("已有文件实体校验不一致，请运行完整性检查") } }
        else { try fm.moveItem(at:temp,to:final); try? fm.setAttributes([.posixPermissions:0o400],ofItemAtPath:final.path); created=true }
        return (hash,written,relative,created)
    }
    func importFile(path:String,name:String?=nil,projectID:String?=nil,source:String="manual",confirmed:Bool=false,sourcePath:String?=nil) throws -> [String:Any] {
        lock.lock(); defer { lock.unlock() }
        let url=URL(fileURLWithPath:path).standardizedFileURL
        let display=safeName(name ?? url.lastPathComponent)
        let provenancePath:String? = ["upload","manual_upload"].contains(source) ? nil : (sourcePath ?? url.path)
        if let p=projectID { _ = try project(p) }
        let staged=try stage(url)
        do {
            return try db.transaction {
                try db.exec("INSERT OR IGNORE INTO blobs(hash,size,path) VALUES(?,?,?)",[staged.hash,staged.size,staged.relative])
                let existing=try db.query("SELECT f.id FROM files f JOIN versions v ON v.id=f.current_version WHERE v.hash=? AND f.status<>'trash' ORDER BY f.created_at LIMIT 1",[staged.hash]).first?["id"] as? String
                let id=existing ?? uuid(); let time=now(); let confidence=confirmed ? "用户确认" : "待确认"; let status=confirmed ? "managed" : "pending"
                if existing == nil {
                    let version=uuid()
                    try db.exec("INSERT INTO files(id,name,ext,status,current_version,created_at,updated_at) VALUES(?,?,?,?,?,?,?)",[id,display,URL(fileURLWithPath:display).pathExtension.lowercased(),status,version,time,time])
                    try db.exec("INSERT INTO versions(id,file_id,hash,size,created_at,source,note) VALUES(?,?,?,?,?,?,?)",[version,id,staged.hash,staged.size,time,source,"初次导入"])
                    try db.exec("INSERT INTO metadata_fts(file_id,name,tags) VALUES(?,?,?)",[id,display,""])
                } else if confirmed { try db.exec("UPDATE files SET status='managed',updated_at=? WHERE id=? AND status='pending'",[time,id]) }
                if let p=projectID { try db.exec("INSERT OR IGNORE INTO file_projects VALUES(?,?)",[id,p]); try db.exec("UPDATE projects SET updated_at=? WHERE id=?",[time,p]) }
                let already=try db.query("SELECT id FROM provenance WHERE file_id=? AND source=? AND source_path IS ? LIMIT 1",[id,source,provenancePath])
                if already.isEmpty { try db.exec("INSERT INTO provenance VALUES(?,?,?,?,?,?,?,?,?,?)",[uuid(),id,source,provenancePath,display,confidence,time,projectID.flatMap{try? project($0)["original_title"] as? String},status,nil]) }
                try event(existing == nil ? "import" : "duplicate",existing == nil ? "导入 \(display)" : "重复内容已复用：\(display)",project:projectID,file:id)
                return ["id":id,"duplicate":existing != nil,"file":try file(id)]
            }
        } catch {
            if staged.created,(try? db.query("SELECT hash FROM blobs WHERE hash=?",[staged.hash]).isEmpty) == true { try? fm.removeItem(at:root.appendingPathComponent(staged.relative)) }
            throw error
        }
    }
    private func safeName(_ name:String) -> String {
        let value=URL(fileURLWithPath:name).lastPathComponent.replacingOccurrences(of:"\0",with:"").trimmingCharacters(in:.whitespacesAndNewlines)
        return value.isEmpty ? "未命名文件" : String(value.prefix(240))
    }
    private func listFiles(_ p:[String:Any]) throws -> [String:Any] {
        var whereSQL=["f.status=?"]; var args:[Any?]=[(p["status"] as? String) ?? "managed"]
        let q=String((p["q"] as? String ?? "").trimmingCharacters(in:.whitespacesAndNewlines).prefix(1000))
        let fileCenterSearch=p["search_context"] as? String == "file_center"
        let exclusions=q.isEmpty ? [] : fileCenterSearch ? fileSearchExclusions() : ["md","markdown"]
        if !q.isEmpty {
            if !exclusions.isEmpty {
                let placeholders=Array(repeating:"?",count:exclusions.count).joined(separator:",")
                whereSQL.append("lower(f.ext) NOT IN (\(placeholders))")
                args += exclusions.map { $0 as Any? }
            }
            whereSQL.append("(f.name LIKE ? ESCAPE '\\' OR f.tags LIKE ? ESCAPE '\\' OR EXISTS(SELECT 1 FROM file_projects r JOIN projects p ON p.id=r.project_id WHERE r.file_id=f.id AND (p.title LIKE ? ESCAPE '\\' OR p.original_title LIKE ? ESCAPE '\\'))) ")
            let escaped=q.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"%",with:"\\%").replacingOccurrences(of:"_",with:"\\_"); let pattern="%\(escaped)%"; args += [pattern,pattern,pattern,pattern]
        }
        if let id=p["project_id"] as? String,!id.isEmpty { whereSQL.append("EXISTS(SELECT 1 FROM file_projects r WHERE r.file_id=f.id AND r.project_id=?)"); args.append(id) }
        if let ext=p["ext"] as? String,!ext.isEmpty { whereSQL.append("f.ext=?"); args.append(ext.lowercased()) }
        if (p["favorite"] as? Bool) == true { whereSQL.append("f.favorite=1") }
        if (p["final"] as? Bool) == true {
            if let projectID=p["project_id"] as? String,!projectID.isEmpty { whereSQL.append("EXISTS(SELECT 1 FROM project_deliverables d WHERE d.file_id=f.id AND d.project_id=?)"); args.append(projectID) }
            else { whereSQL.append("EXISTS(SELECT 1 FROM project_deliverables d WHERE d.file_id=f.id)") }
        }
        if let tag=p["tag"] as? String,!tag.isEmpty { whereSQL.append("EXISTS(SELECT 1 FROM json_each(f.tags) WHERE value=?)"); args.append(tag) }
        let whereText=whereSQL.joined(separator:" AND ")
        let count=try db.query("SELECT count(*) n FROM files f WHERE \(whereText)",args).first?["n"] ?? 0
        let sort=["name":"f.name COLLATE NOCASE","newest":"f.updated_at DESC,f.id","oldest":"f.created_at,f.id","size":"v.size DESC,f.id"][p["sort"] as? String ?? "newest"] ?? "f.updated_at DESC,f.id"
        let limit=max(1,min(500,p["limit"] as? Int ?? 100)); let offset=max(0,p["offset"] as? Int ?? 0)
        let ids=try db.query("SELECT f.id FROM files f LEFT JOIN versions v ON v.id=f.current_version WHERE \(whereText) ORDER BY \(sort) LIMIT ? OFFSET ?",args+[limit,offset])
        return ["items":try ids.map{ row -> [String:Any] in
            var f=try file(row["id"] as! String)
            if let projectID=p["project_id"] as? String,!projectID.isEmpty { f["final"]=try db.query("SELECT 1 FROM project_deliverables WHERE file_id=? AND project_id=? LIMIT 1",[f["id"],projectID]).isEmpty ? 0 : 1 }
            return f
        },"total":count,"search_excluded_extensions":exclusions,"search_excludes_markdown":exclusions.contains("md") || exclusions.contains("markdown")]
    }
    private func saveProject(_ p:[String:Any]) throws -> [String:Any] { try db.transaction { try saveProjectImpl(p) } }
    private func saveProjectImpl(_ p:[String:Any]) throws -> [String:Any] {
        let title=try required(p,"title"); guard title.count<=1000 else { throw fail("项目标题过长") }
        let time=now()
        if p["id"] == nil,let conversation=p["conversation_id"] as? String,!conversation.isEmpty,let known=try db.query("SELECT project_id FROM project_sources WHERE conversation_id=?",[conversation]).first?["project_id"] as? String {
            let original=p["original_title"] as? String ?? title
            let origin=p["title_source"] as? String ?? "用户提供标题"
            try db.exec("UPDATE project_sources SET title=?,title_source=?,source_url=coalesce(?,source_url),obtained_at=? WHERE conversation_id=?",[original,origin,p["source_url"] as? String,time,conversation])
            try db.exec("UPDATE projects SET original_title=?,title_source=?,title_obtained_at=?,updated_at=? WHERE id=?",[original,origin,time,time,known])
            try event("title","按会话标识更新原始标题；保留用户显示标题",project:known)
            return ["project":try project(known),"matched_conversation":true]
        }
        let id=p["id"] as? String ?? uuid(); let existing=try db.query("SELECT * FROM projects WHERE id=?",[id]).first
        let status=p["status"] as? String ?? existing?["status"] as? String ?? "进行中"
        guard ["进行中","已完成","已归档"].contains(status) else { throw fail("无效项目状态") }
        let sourceURL=p["source_url"] as? String ?? existing?["source_url"] as? String ?? ""
        if !sourceURL.isEmpty { guard let url=URL(string:sourceURL),["https","http"].contains(url.scheme ?? "") else { throw fail("来源链接必须为 http/https URL") } }
        let original=p["original_title"] as? String ?? existing?["original_title"] as? String ?? title
        let category=p["category"] as? String ?? existing?["category"] as? String ?? suggestedCategory(title)
        if existing == nil {
            let conversation=p["conversation_id"] as? String
            try db.exec("INSERT INTO projects(id,title,original_title,title_source,title_obtained_at,conversation_id,source_url,category,description,status,tags,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)",[id,title,original,p["title_source"] as? String ?? "用户输入",time,conversation?.isEmpty == false ? conversation : nil,sourceURL,category,p["description"] as? String ?? "",status,jsonString(p["tags"] as? [String] ?? []),time,time])
        } else {
            try db.exec("UPDATE projects SET title=?,original_title=?,source_url=?,category=?,description=?,status=?,tags=?,updated_at=? WHERE id=?",[title,original,sourceURL,category,p["description"] as? String ?? existing?["description"] as? String ?? "",status,jsonString(p["tags"] as? [String] ?? jsonValue(existing?["tags"] as? String ?? "[]") as? [String] ?? []),time,id])
        }
        if existing == nil { try db.exec("INSERT INTO project_sources(id,project_id,conversation_id,title,title_source,source_url,obtained_at,confidence) VALUES(?,?,?,?,?,?,?,?)",[uuid(),id,p["conversation_id"] as? String,original,p["title_source"] as? String ?? "用户输入",sourceURL,time,(p["source_confirmed"] as? Bool) == false ? "待确认" : "用户确认"]) }
        if let confirmed=p["source_confirmed"] as? Bool { try db.exec("UPDATE projects SET source_confirmed=? WHERE id=?",[confirmed,id]) }
        try event("project",existing == nil ? "创建项目" : "修改项目",project:id)
        return ["project":try project(id)]
    }
    private func suggestedCategory(_ title:String) -> String {
        let text=title.lowercased()
        for (words,category) in [(["ccus","碳封存","二氧化碳"],"CCUS 与碳封存"),(["石油","油田","采收率","油藏"],"石油工程"),(["考研","词汇","数学"],"考研学习"),(["职业","招聘","就业"],"职业规划"),(["文献","论文"],"科研文献"),(["软件","代码","ai","开发"],"AI 与软件开发")] { if words.contains(where:{text.contains($0)}) { return category } }
        return "未分类"
    }
    func rpc(_ p:[String:Any]) throws -> [String:Any] {
        let action=try required(p,"action")
        if action == "import_cancel" { let job=try required(p,"job_id"); cancelMutex.lock(); cancellations.insert(job); cancelMutex.unlock(); return ["cancelled":true] }
        if action == "import" { return try importPaths(p) }
        if action == "import_jobs" { return ["items":try db.query("SELECT * FROM import_jobs ORDER BY created_at DESC LIMIT 100")] }
        if action.hasPrefix("ai_") { if let result=try externalRPC?(p) { return result }; throw fail("AI 模块不可用") }
        lock.lock(); defer { lock.unlock() }
        switch action {
        case "status": return try status()
        case "setup":
            if let destination=p["root"] as? String,URL(fileURLWithPath:destination).standardizedFileURL.path != root.path { _ = try migrate(to:destination) }
            if let path=p["inbox_path"] as? String,!path.isEmpty { _ = try saveSource(["path":path,"kind":"dedicated","enabled":true]) }
            if let path=p["downloads_path"] as? String,!path.isEmpty { _ = try saveSource(["path":path,"kind":"downloads","enabled":true]) }
            try setSetting("setup_complete",true); return try status()
        case "projects": return ["items":try db.query("SELECT id FROM projects ORDER BY updated_at DESC,id").map{try project($0["id"] as! String)}]
        case "project_save": return try saveProject(p)
        case "project_confirm": let id=try required(p,"id"); _ = try project(id); try db.exec("UPDATE projects SET source_confirmed=1,title_source=title_source || ' · 用户确认' WHERE id=? AND source_confirmed=0",[id]); try db.exec("UPDATE project_sources SET confidence='用户确认' WHERE project_id=?",[id]); return ["project":try project(id)]
        case "project_detail":
            let id=try required(p,"id"); let files=try listFiles(["project_id":id,"limit":500]); return ["project":try project(id),"files":files["items"] ?? [],"events":try db.query("SELECT * FROM events WHERE project_id=? ORDER BY created_at DESC LIMIT 200",[id]),"sources":try db.query("SELECT * FROM project_sources WHERE project_id=? ORDER BY obtained_at",[id]),"missing_attachments":try db.query("SELECT * FROM missing_attachments WHERE project_id=?",[id])]
        case "project_merge":
            let from=try required(p,"from_id"),to=try required(p,"to_id"); guard from != to else { throw fail("不能合并同一项目") }; _ = try project(from); _ = try project(to)
            try db.transaction { try db.exec("INSERT OR IGNORE INTO file_projects SELECT file_id,? FROM file_projects WHERE project_id=?",[to,from]); try db.exec("INSERT OR IGNORE INTO project_deliverables SELECT ?,file_id,version_id,display_name,evidence_source,evidence_note,source_path,selected_at,delivered_at,time_source FROM project_deliverables WHERE project_id=?",[to,from]); try db.exec("UPDATE events SET project_id=? WHERE project_id=?",[to,from]); try db.exec("UPDATE missing_attachments SET project_id=? WHERE project_id=?",[to,from]); try db.exec("UPDATE project_sources SET project_id=? WHERE project_id=?",[to,from]); try db.exec("DELETE FROM projects WHERE id=?",[from]); try event("merge","手动合并项目 \(from)",project:to) }; return ["project":try project(to)]
        case "project_split":
            let from=try required(p,"id"),title=try required(p,"title"); _ = try project(from); let ids=p["file_ids"] as? [String] ?? []
            return try db.transaction { let result=try saveProject(["title":title,"title_source":"用户拆分"]); let target=(result["project"] as! [String:Any])["id"] as! String
                for id in ids { guard !(try db.query("SELECT * FROM file_projects WHERE file_id=? AND project_id=?",[id,from])).isEmpty else { throw fail("所选文件不属于原项目") }; try db.exec("INSERT INTO file_projects VALUES(?,?)",[id,target]); try db.exec("INSERT INTO project_deliverables SELECT ?,file_id,version_id,display_name,evidence_source,evidence_note,source_path,selected_at,delivered_at,time_source FROM project_deliverables WHERE file_id=? AND project_id=?",[target,id,from]); try db.exec("DELETE FROM file_projects WHERE file_id=? AND project_id=?",[id,from]) }; try event("split","从项目 \(from) 拆分",project:target); return result }
        case "project_delete":
            let id=try required(p,"id"); guard try db.query("SELECT file_id FROM file_projects WHERE project_id=? LIMIT 1",[id]).isEmpty else { throw fail("请先移出项目文件，再删除空项目") }; try db.transaction { try db.exec("DELETE FROM missing_attachments WHERE project_id=?",[id]); try db.exec("DELETE FROM project_sources WHERE project_id=?",[id]); try db.exec("DELETE FROM projects WHERE id=?",[id]) }; return ["ok":true]
        case "deliverables": return try listDeliverables(p)
        case "deliverable_set": return try selectDeliverables(p)
        case "deliverable_remove": return try removeDeliverable(p)
        case "deliverable_projects": return ["items":try deliverableRows(fileID:try required(p,"file_id"))]
        case "files": return try listFiles(p)
        case "file_detail":
            let id=try required(p,"id"); let f=try file(id); let versions=try db.query("SELECT *,CASE WHEN id=? THEN 1 ELSE 0 END is_current FROM versions WHERE file_id=? ORDER BY created_at DESC,rowid DESC",[f["current_version"],id]).map { row -> [String:Any] in var v=row; v["final_projects"]=try db.query("SELECT p.id,p.title FROM project_deliverables d JOIN projects p ON p.id=d.project_id WHERE d.file_id=? AND d.version_id=?",[id,row["id"]]); return v }; return ["file":f,"versions":versions,"provenance":try db.query("SELECT * FROM provenance WHERE file_id=? ORDER BY imported_at DESC",[id]),"projects":try (f["project_ids"] as? [String] ?? []).map{try project($0)}]
        case "file_update": return try updateFiles(p)
        case "import": return try importPaths(p)
        case "import_jobs": return ["items":try db.query("SELECT * FROM import_jobs ORDER BY created_at DESC LIMIT 100")]
        case "import_retry":
            let id=try required(p,"id"); guard let request=try db.query("SELECT request FROM import_jobs WHERE id=?",[id]).first?["request"] as? String,var values=jsonValue(request) as? [String:Any] else { throw fail("导入任务不存在") }; values.removeValue(forKey:"job_id"); return try importPaths(values)
        case "import_export": return try importExport(path:try required(p,"path"))
        case "preview": return try preview(fileID:try required(p,"id"),versionID:p["version_id"] as? String)
        case "open_file": return try openFile(id:try required(p,"id"),version:p["version_id"] as? String)
        case "reveal_file":
            let id=try required(p,"id"),version=p["version_id"] as? String
            let url=try version.map { try readOnlyVersionCopy(fileID:id,versionID:$0,name:p["name"] as? String) } ?? blobURL(fileID:id)
            DispatchQueue.main.async { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            let resolvedVersion=try version ?? (file(id)["current_version"] as? String ?? "")
            return ["ok":true,"path":url.path,"read_only":true,"version_id":resolvedVersion]
        case "export_file": return try exportFile(p)
        case "check_edits": return try checkEdits()
        case "commit_edit":
            let id=try required(p,"id"); let path=try workingPath(id); return try addVersion(id:id,path:path.path,source:"external_edit",note:p["note"] as? String ?? "外部编辑")
        case "discard_edit":
            let id=try required(p,"id"); let path=try workingPath(id); if fm.fileExists(atPath:path.path) { try fm.removeItem(at:path) }; return ["ok":true]
        case "version_add": return try addVersion(id:try required(p,"id"),path:try required(p,"path"),source:"manual_version",note:p["note"] as? String ?? "手动新版本")
        case "version_restore":
            let id=try required(p,"id"),version=try required(p,"version_id"); let url=try blobURL(fileID:id,versionID:version); return try addVersion(id:id,path:url.path,source:"restore",note:"恢复历史版本 \(version)",force:true)
        case "version_final":
            let id=try required(p,"id"),version=try required(p,"version_id"); guard !(try db.query("SELECT id FROM versions WHERE file_id=? AND id=?",[id,version])).isEmpty else { throw fail("版本不存在") }; try db.transaction { try db.exec("UPDATE versions SET is_final=0 WHERE file_id=?",[id]); try db.exec("UPDATE versions SET is_final=1 WHERE id=?",[version]); try db.exec("UPDATE files SET final=1 WHERE id=?",[id]); for relation in try db.query("SELECT project_id FROM file_projects WHERE file_id=?",[id]) { _ = try selectDeliverables(["project_id":relation["project_id"]!,"file_ids":[id],"version_id":version]) } }; return ["ok":true]
        case "sources": return ["items":try db.query("SELECT * FROM sources ORDER BY rowid"),"logs":try db.query("SELECT * FROM sync_logs ORDER BY created_at DESC,rowid DESC LIMIT 100")]
        case "source_save": return try saveSource(p)
        case "source_delete": try db.exec("DELETE FROM sources WHERE id=?",[try required(p,"id")]); return ["ok":true]
        case "scan": return try scan()
        case "categories": return ["items":try db.query("SELECT * FROM categories ORDER BY position,name")]
        case "category_save":
            let id=p["id"] as? String ?? uuid(),name=try required(p,"name"); let previous=try db.query("SELECT name FROM categories WHERE id=?",[id]).first?["name"] as? String; try db.transaction { try db.exec("INSERT INTO categories(id,name,position) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET name=excluded.name,position=excluded.position",[id,name,p["position"] as? Int ?? 999]); if let previous=previous { try db.exec("UPDATE projects SET category=? WHERE category=?",[name,previous]) } }; return ["ok":true]
        case "category_delete":
            let id=try required(p,"id"); let name=try db.query("SELECT name FROM categories WHERE id=?",[id]).first?["name"] as? String ?? ""; try db.transaction { try db.exec("UPDATE projects SET category='未分类' WHERE category=?",[name]); try db.exec("DELETE FROM categories WHERE id=?",[id]) }; return ["ok":true]
        case "settings": var values:[String:Any]=[:]; for row in try db.query("SELECT * FROM settings") { values[row["key"] as! String]=jsonValue(row["value"] as! String) }; return ["settings":values,"root":root.path]
        case "settings_save":
            var values=p["values"] as? [String:Any] ?? [:]; guard values.count<=100 else { throw fail("设置数量过多") }
            if let exclusions=values[Self.fileSearchExclusionKey] {
                values[Self.fileSearchExclusionKey]=try normalizeFileSearchExclusions(exclusions)
            }
            for (key,value) in values { guard !key.lowercased().contains("key"),(!key.lowercased().contains("token") || key == "ai_max_tokens"),!key.lowercased().contains("secret"),key.count<100,jsonString(value).count<10000 else { throw fail("敏感密钥必须通过 Keychain 专用入口保存") }; try setSetting(key,value) }; return ["ok":true]
        case "logs": return ["items":try db.query("SELECT * FROM sync_logs ORDER BY created_at DESC,rowid DESC LIMIT 300")]
        case "integrity": return try integrity()
        case "resources": return resources()
        case "backup_create": return try backup(destination:try required(p,"destination"),includeIndex:p["include_index"] as? Bool ?? false)
        case "backup_inspect": return try inspectBackup(path:try required(p,"path"))
        case "backup_restore": guard p["confirmed"] as? Bool == true else { throw fail("恢复前必须确认") }; return try restoreBackup(path:try required(p,"path"),destination:try required(p,"destination"))
        case "migrate": return try migrate(to:try required(p,"destination"))
        case "switch_library": return try switchLibrary(path:try required(p,"path"))
        default: if let result=try externalRPC?(p) { return result }; throw fail("未知操作：\(action)")
        }
    }
    private func status() throws -> [String:Any] {
        let available=fm.fileExists(atPath:root.appendingPathComponent("workvault.sqlite").path) && fm.fileExists(atPath:root.appendingPathComponent("blobs").path)
        let free=(try? fm.attributesOfFileSystem(forPath:root.path)[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        return ["version":"1.3.0","root":root.path,"codex_output_root":fm.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Codex").path,"file_search_exclusions":fileSearchExclusions(),"file_search_default_exclusions":Self.defaultFileSearchExclusions,"setup_complete":setting("setup_complete",false) ?? false,"projects":try db.query("SELECT count(*) n FROM projects WHERE source_confirmed=1").first?["n"] ?? 0,"pending_projects":try db.query("SELECT count(*) n FROM projects WHERE source_confirmed=0").first?["n"] ?? 0,"files":try db.query("SELECT count(*) n FROM files WHERE status='managed'").first?["n"] ?? 0,"inbox":try db.query("SELECT count(*) n FROM files WHERE status='pending'").first?["n"] ?? 0,"bytes":try db.query("SELECT coalesce(sum(size),0) n FROM blobs").first?["n"] ?? 0,"free_bytes":free,"recent_files":try listFiles(["limit":8])["items"] ?? [],"formats":try db.query("SELECT ext,count(*) count FROM files WHERE status='managed' GROUP BY ext ORDER BY count DESC"),"logs":try db.query("SELECT * FROM sync_logs ORDER BY created_at DESC,rowid DESC LIMIT 8"),"storage_available":available]
    }
    private func updateFiles(_ p:[String:Any]) throws -> [String:Any] {
        let ids=p["ids"] as? [String] ?? []; guard !ids.isEmpty,ids.count<=1000 else { throw fail("请选择 1–1000 个文件") }
        if p["name"] != nil,ids.count != 1 { throw fail("批量操作不支持重命名") }
        return try db.transaction {
            for id in ids {
                _ = try file(id)
                for key in ["favorite"] { if let value=p[key] as? Bool { try db.exec("UPDATE files SET \(key)=?,updated_at=? WHERE id=?",[value,now(),id]) } }
                if let status=p["status"] as? String { guard ["managed","pending","trash"].contains(status) else { throw fail("无效文件状态") }; try db.exec("UPDATE files SET status=?,updated_at=? WHERE id=?",[status,now(),id]); try event(status == "trash" ? "trash" : "status","文件状态：\(status)",file:id) }
                if let name=p["name"] as? String { let safe=safeName(name); try db.exec("UPDATE files SET name=?,ext=?,updated_at=? WHERE id=?",[safe,URL(fileURLWithPath:safe).pathExtension.lowercased(),now(),id]); try db.exec("UPDATE metadata_fts SET name=? WHERE file_id=?",[safe,id]) }
                if let tags=p["tags"] as? [String] { guard tags.count<=100,tags.allSatisfy({$0.count<=200}) else { throw fail("标签过多或过长") }; try db.exec("UPDATE files SET tags=?,updated_at=? WHERE id=?",[jsonString(tags),now(),id]); try db.exec("UPDATE metadata_fts SET tags=? WHERE file_id=?",[tags.joined(separator:" "),id]) }
                if let projectID=p["project_id"] as? String {
                    if projectID.isEmpty {
                        if p["replace_projects"] as? Bool == true { try db.exec("DELETE FROM file_projects WHERE file_id=?",[id]); try event("dissociate","用户明确移除全部项目关联",file:id) }
                    } else {
                        _ = try project(projectID); if p["replace_projects"] as? Bool == true { try db.exec("DELETE FROM file_projects WHERE file_id=? AND project_id<>?",[id,projectID]) }; try db.exec("INSERT OR IGNORE INTO file_projects VALUES(?,?)",[id,projectID]); try db.exec("UPDATE projects SET updated_at=? WHERE id=?",[now(),projectID]); try event("associate","用户确认关联",project:projectID,file:id)
                    }
                }
                if let final=p["final"] as? Bool {
                    if final { for relation in try db.query("SELECT project_id FROM file_projects WHERE file_id=?",[id]) { _ = try selectDeliverables(["project_id":relation["project_id"]!,"file_ids":[id]]) } }
                    else { try db.exec("DELETE FROM project_deliverables WHERE file_id=?",[id]) }
                }
                try refreshFinalMarkers(fileID:id)
                if p["status"] as? String == "managed" { try db.exec("UPDATE provenance SET confidence='用户确认',status='managed' WHERE file_id=? AND confidence='待确认'",[id]) }
            }
            return ["updated":ids.count]
        }
    }
    func recoverInterruptedImports() throws {
        lock.lock(); defer { lock.unlock() }
        guard !importing else { return }
        let interrupted=try db.query("SELECT id FROM import_jobs WHERE status='running'").count
        try db.exec("UPDATE import_jobs SET status='interrupted',error='应用上次退出时导入尚未完成；已提交文件保持完整，可重试。',updated_at=? WHERE status='running'",[now()])
        var removed=0
        for url in try fm.contentsOfDirectory(at:root.appendingPathComponent("tmp"),includingPropertiesForKeys:nil) where url.lastPathComponent.hasSuffix(".partial") || url.lastPathComponent.hasPrefix("zip-") || url.lastPathComponent.hasPrefix("export-") { try fm.removeItem(at:url); removed += 1 }
        if interrupted>0 || removed>0 { try log("warning","启动恢复：标记 \(interrupted) 个中断任务，清理 \(removed) 个未提交临时项。源文件和已提交版本保留。") }
    }
    private func importPaths(_ p:[String:Any]) throws -> [String:Any] {
        lock.lock(); if importing { lock.unlock(); throw fail("已有导入任务正在运行，请等待或取消") }; importing=true; lock.unlock()
        defer { lock.lock(); importing=false; lock.unlock() }
        let paths=p["paths"] as? [String] ?? []; guard !paths.isEmpty,paths.count<=10000 else { throw fail("请选择文件或文件夹") }
        let job=p["job_id"] as? String ?? uuid(); let projectID=p["project_id"] as? String; let source=p["source"] as? String ?? "manual"; let confirmed=p["confirmed"] as? Bool ?? false
        var queue=try expand(paths)
        var unpacked:[URL]=[]; var originalPaths:[String:String]=[:]
        defer { for directory in unpacked { try? fm.removeItem(at:directory) } }
        if p["expand_zip"] as? Bool != false {
            for archive in queue where archive.pathExtension.lowercased() == "zip" {
                let directory=root.appendingPathComponent("tmp/zip-\(uuid())"); unpacked.append(directory); try extractZIP(archive,to:directory); let children=try expand([directory.path]); for child in children { originalPaths[child.path]=archive.path+"!/"+String(child.path.dropFirst(directory.path.count+1)) }; queue += children
            }
        }
        try db.exec("INSERT INTO import_jobs(id,status,created_at,updated_at,total,request) VALUES(?,?,?,?,?,?)",[job,"running",now(),now(),queue.count,jsonString(p)])
        Thread.current.threadDictionary["workvaultImportJob"]=job
        defer { Thread.current.threadDictionary.removeObject(forKey:"workvaultImportJob") }
        var imported=0,duplicates=0,failed=0; var results:[[String:Any]]=[]
        for path in queue {
            if isCancelled(job) { try db.exec("UPDATE import_jobs SET status='cancelled',updated_at=? WHERE id=?",[now(),job]); break }
            do {
                let result=try importFile(path:path.path,name:nil,projectID:projectID,source:source,confirmed:confirmed,sourcePath:originalPaths[path.path])
                if result["duplicate"] as? Bool == true { duplicates += 1 } else { imported += 1 }
                results.append(result)
            } catch {
                failed += 1; let message=error.localizedDescription
                results.append(["path":path.path,"error":message]); try log("error","导入失败：\(path.lastPathComponent)：\(message)")
                try db.exec("INSERT INTO provenance VALUES(?,?,?,?,?,?,?,?,?,?)",[uuid(),nil,source,path.path,path.lastPathComponent,"待确认",now(),nil,"failed",message])
            }
            try db.exec("UPDATE import_jobs SET processed=?,updated_at=? WHERE id=?",[imported+duplicates+failed,now(),job])
        }
        if !isCancelled(job) { try db.exec("UPDATE import_jobs SET status=?,error=?,updated_at=? WHERE id=?",[failed == 0 ? "completed" : "partial",failed == 0 ? nil : "\(failed) 个文件导入失败",now(),job]) }
        try log(failed == 0 ? "success" : "warning","导入完成：新增 \(imported)，复用 \(duplicates)，失败 \(failed)")
        return ["imported":imported,"duplicates":duplicates,"failed":failed,"results":results,"job_id":job]
    }
    private let cancelMutex=NSLock()
    private func isCancelled(_ id:String) -> Bool { cancelMutex.lock(); defer {cancelMutex.unlock()}; return cancellations.contains(id) }
    private func expand(_ paths:[String]) throws -> [URL] {
        var result:[URL]=[]
        for path in paths {
            let url=URL(fileURLWithPath:path).standardizedFileURL
            let values=try url.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw fail("不导入符号链接") }
            if values.isDirectory == true {
                guard let enumerator=fm.enumerator(at:url,includingPropertiesForKeys:[.isRegularFileKey,.isSymbolicLinkKey],options:[.skipsHiddenFiles,.skipsPackageDescendants]) else { throw fail("无法读取文件夹") }
                for case let item as URL in enumerator {
                    let v=try item.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey]); if v.isSymbolicLink == true { enumerator.skipDescendants(); continue }
                    if v.isRegularFile == true { result.append(item) }; guard result.count<=20000 else { throw fail("单次导入最多 20,000 个文件，请分批导入") }
                }
            } else { result.append(url) }
        }
        return result.sorted{$0.path<$1.path}
    }
    private func addVersion(id:String,path:String,source:String,note:String,force:Bool=false) throws -> [String:Any] {
        let current=try file(id); let staged=try stage(URL(fileURLWithPath:path).standardizedFileURL)
        if !force,current["hash"] as? String == staged.hash { return ["duplicate":true,"file":current] }
        do {
            return try db.transaction {
                try db.exec("INSERT OR IGNORE INTO blobs VALUES(?,?,?)",[staged.hash,staged.size,staged.relative]); let version=uuid()
                try db.exec("INSERT INTO versions(id,file_id,hash,size,created_at,source,note) VALUES(?,?,?,?,?,?,?)",[version,id,staged.hash,staged.size,now(),source,String(note.prefix(2000))])
                try db.exec("UPDATE files SET current_version=?,updated_at=? WHERE id=?",[version,now(),id]); try event("version","新增版本：\(note)",file:id)
                return ["version_id":version,"file":try file(id)]
            }
        } catch { if staged.created,(try? db.query("SELECT hash FROM blobs WHERE hash=?",[staged.hash]).isEmpty) == true { try? fm.removeItem(at:root.appendingPathComponent(staged.relative)) }; throw error }
    }
    private func workingPath(_ id:String,create:Bool=true) throws -> URL {
        let f=try file(id); let directory=root.appendingPathComponent("working/\(id)"); if create { try fm.createDirectory(at:directory,withIntermediateDirectories:true) }; if let existing=try? fm.contentsOfDirectory(at:directory,includingPropertiesForKeys:[.isRegularFileKey]).first(where:{ (try? $0.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile) == true }) { return existing }; return directory.appendingPathComponent(safeName(f["name"] as? String ?? "file"))
    }
    func readOnlyVersionCopy(fileID:String,versionID:String,name:String?=nil) throws -> URL {
        let source=try blobURL(fileID:fileID,versionID:versionID),f=try file(fileID)
        guard versionID.count<=128,!versionID.isEmpty,versionID.allSatisfy({$0.isLetter || $0.isNumber || $0 == "-"}) else { throw fail("版本标识无效") }
        guard let expected=try db.query("SELECT hash FROM versions WHERE id=? AND file_id=?",[versionID,fileID]).first?["hash"] as? String else { throw fail("版本不存在") }
        let parent=root.appendingPathComponent("previews"),directory=parent.appendingPathComponent(versionID)
        let parentInfo=try parent.resourceValues(forKeys:[.isSymbolicLinkKey,.isDirectoryKey])
        guard parentInfo.isSymbolicLink != true,parentInfo.isDirectory == true else { throw fail("预览缓存目录不可用") }
        if !fm.fileExists(atPath:directory.path) { try fm.createDirectory(at:directory,withIntermediateDirectories:false) }
        let directoryInfo=try directory.resourceValues(forKeys:[.isSymbolicLinkKey,.isDirectoryKey])
        guard directoryInfo.isSymbolicLink != true,directoryInfo.isDirectory == true else { throw fail("不接受符号链接预览目录") }
        let destination=directory.appendingPathComponent(safeName(name ?? f["name"] as? String ?? "file"))
        let info=try? destination.resourceValues(forKeys:[.isSymbolicLinkKey])
        guard info?.isSymbolicLink != true else { throw fail("不接受符号链接预览文件") }
        if fm.fileExists(atPath:destination.path) {
            _=try regularFile(destination)
            if try Store.hashFile(destination)==expected { try fm.setAttributes([.posixPermissions:0o400],ofItemAtPath:destination.path);return destination }
        }
        // This disposable, named copy is shared by pinned Open and Finder reveal.
        // Always verify it; a user-modified cache must never replace the archive.
        let temporary=directory.appendingPathComponent(".\(uuid()).partial")
        defer { try? fm.removeItem(at:temporary) }
        try fm.copyItem(at:source,to:temporary)
        guard try Store.hashFile(temporary)==expected else { throw fail("只读版本副本校验失败") }
        try fm.setAttributes([.posixPermissions:0o400],ofItemAtPath:temporary.path)
        guard Darwin.rename(temporary.path,destination.path)==0 else { throw fail("无法原子写入只读版本副本") }
        return destination
    }
    private func openFile(id:String,version:String?) throws -> [String:Any] {
        let original=try blobURL(fileID:id,versionID:version)
        let path:URL
        if let version=version { path=try readOnlyVersionCopy(fileID:id,versionID:version) }
        else { path=try workingPath(id); if !fm.fileExists(atPath:path.path) { try fm.copyItem(at:original,to:path); try? fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:path.path) } }
        DispatchQueue.main.async { NSWorkspace.shared.open(path) }
        return ["path":path.path,"editable":version == nil,"note":version == nil ? "已打开受管理工作副本。编辑完成后检查并登记新版本。" : "历史版本只读副本"]
    }
    private func checkEdits() throws -> [String:Any] {
        var items:[[String:Any]]=[]
        for row in try db.query("SELECT id FROM files WHERE status<>'trash'") {
            let id=row["id"] as! String; let f=try file(id); let path=try workingPath(id,create:false)
            if fm.fileExists(atPath:path.path),let hash=try? Store.hashFile(path) { items.append(["id":id,"path":path.path,"name":f["name"] ?? "","changed":hash != f["hash"] as? String]) }
        }
        return ["items":items]
    }
    private func exportFile(_ p:[String:Any]) throws -> [String:Any] {
        let id=try required(p,"id"); let f=try file(id); let source=try blobURL(fileID:id,versionID:p["version_id"] as? String)
        guard let destination=p["destination"] as? String,!destination.isEmpty else { throw fail("请选择导出目标目录") }
        let targetDirectory=URL(fileURLWithPath:destination).standardizedFileURL
        var isDir:ObjCBool=false; guard fm.fileExists(atPath:targetDirectory.path,isDirectory:&isDir),isDir.boolValue else { throw fail("导出目标必须是已存在的目录") }
        let target=targetDirectory.appendingPathComponent(safeName(p["name"] as? String ?? f["name"] as? String ?? "file")); guard !fm.fileExists(atPath:target.path) else { throw fail("目标文件已存在，请选择其他目录或先重命名") }
        try fm.copyItem(at:source,to:target); try? fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:target.path); guard try Store.hashFile(source) == Store.hashFile(target) else { try? fm.removeItem(at:target); throw fail("导出校验失败") }
        return ["path":target.path]
    }
    private func preview(fileID:String,versionID:String?) throws -> [String:Any] {
        let f=try file(fileID); let url=try blobURL(fileID:fileID,versionID:versionID); let ext=f["ext"] as? String ?? ""
        let content="/content/\(fileID)"+(versionID.map{"?version=\($0)"} ?? "")
        if ["png","jpg","jpeg","webp","gif","heic","bmp"].contains(ext) { return ["kind":"image","url":content,"note":"原始图片预览"] }
        if ext == "pdf" { return ["kind":"pdf","url":content,"note":"PDF 原始页面预览（浏览器原生支持情况可能不同）"] }
        if ["docx","xlsx","pptx"].contains(ext) { return ["kind":"office","text":try officeText(url,ext:ext),"note":"简化内容预览，非完整保真。请使用默认应用查看原始排版。"] }
        let texts=["txt","md","markdown","csv","tsv","json","py","js","ts","tsx","jsx","html","css","scss","c","h","cpp","swift","rs","java","sh","zsh","yaml","yml","xml","toml","ini","r","sql","log"]
        if texts.contains(ext) {
            let handle=try FileHandle(forReadingFrom:url); defer{try? handle.close()}; let bytes=try handle.read(upToCount:2*1024*1024) ?? Data()
            guard let text=String(data:bytes,encoding:.utf8) ?? String(data:bytes,encoding:.utf16) else { return ["kind":"unsupported","note":"无法按 UTF-8 / UTF-16 解码，请使用外部应用打开"] }
            return ["kind":"text","text":text,"note":(f["size"] as? Int ?? 0)>bytes.count ? "预览仅显示前 2 MiB；原始文件完整保留。" : "本地文本预览"]
        }
        return ["kind":"unsupported","note":"此格式暂不支持内部预览，可使用默认应用打开或导出。"]
    }
    func extractText(fileID:String) throws -> String {
        let f=try file(fileID); let ext=f["ext"] as? String ?? ""; let url=try blobURL(fileID:fileID)
        if ext == "pdf" {
            guard let doc=PDFDocument(url:url),!doc.isLocked else { throw fail("PDF 无法读取或已加密") }
            var output=""; for page in 0..<min(doc.pageCount,1000) { output += "\n[页 \(page+1)]\n"+(doc.page(at:page)?.string ?? ""); if output.utf8.count>4*1024*1024 { break } }
            guard !output.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw fail("PDF 没有可提取文本，可能需要手动 OCR") }; return output
        }
        if ["docx","xlsx","pptx"].contains(ext) { return try officeText(url,ext:ext) }
        let result=try preview(fileID:fileID,versionID:nil); guard let text=result["text"] as? String else { throw fail("该格式不支持文本提取") }; return text
    }
    private func officeText(_ url:URL,ext:String) throws -> String {
        let entries=try zipEntries(url,maxBytes:128*1024*1024)
        var names=entries.map{$0.name}.filter { path in
            if ext == "docx" { return path == "word/document.xml" || path.hasPrefix("word/header") || path.hasPrefix("word/footer") }
            if ext == "xlsx" { return path == "xl/sharedStrings.xml" || path == "xl/workbook.xml" || (path.hasPrefix("xl/worksheets/sheet") && path.hasSuffix(".xml")) }
            return path.hasPrefix("ppt/slides/slide") && path.hasSuffix(".xml")
        }.sorted{$0.localizedStandardCompare($1) == .orderedAscending}
        guard !names.isEmpty else { throw fail("Office 文件缺少可识别的 XML 内容") }; if names.count>100 { names=Array(names.prefix(100)) }
        var text=""
        for name in names { let data=try runTool("/usr/bin/unzip",["-p",url.path,zipPattern(name)],maxOutput:8*1024*1024); let parser=XMLText(); parser.parse(data); text += "\n[\(name)]\n"+parser.output+"\n"; if text.utf8.count>2*1024*1024 { text += "\n[简化预览已截断]"; break } }
        return text
    }
    private func saveSource(_ p:[String:Any]) throws -> [String:Any] {
        let path=URL(fileURLWithPath:try required(p,"path")).standardizedFileURL; let kind=p["kind"] as? String ?? "dedicated"
        guard ["dedicated","downloads","codex_outputs"].contains(kind) else { throw fail("未知文件来源类型") }
        guard path.path != "/",path.path != root.path,!path.path.hasPrefix(root.path+"/"),!root.path.hasPrefix(path.path+"/") else { throw fail("监控目录不能包含或位于文件库存储目录内") }
        if !fm.fileExists(atPath:path.path),kind == "dedicated" { try fm.createDirectory(at:path,withIntermediateDirectories:true) }
        let values=try path.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey]); guard values.isDirectory == true,values.isSymbolicLink != true else { throw fail("监控来源必须是实际目录") }
        if kind == "codex_outputs" {
            return try saveCodexSource(path,p)
        }
        let existing=try db.query("SELECT id FROM sources WHERE path=?",[path.path]).first?["id"] as? String
        let id=p["id"] as? String ?? existing ?? uuid(); let enabled=p["enabled"] as? Bool ?? true
        try db.exec("INSERT INTO sources(id,path,kind,enabled) VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET path=excluded.path,kind=excluded.kind,enabled=excluded.enabled,error=NULL",[id,path.path,kind,enabled])
        if existing == nil,kind == "downloads" {
            for url in try expand([path.path]) { let attrs=try? url.resourceValues(forKeys:[.fileSizeKey,.contentModificationDateKey]); let fingerprint="\(attrs?.fileSize ?? 0):\(attrs?.contentModificationDate?.timeIntervalSince1970 ?? 0)"; try db.exec("INSERT OR IGNORE INTO source_seen(source_id,path,fingerprint,stable) VALUES(?,?,?,-1)",[id,url.path,fingerprint]) }
        }
        try log("success",enabled ? "已授权监控：\(path.path)" : "已暂停监控：\(path.path)",source:id)
        return ["source":try db.query("SELECT * FROM sources WHERE id=?",[id]).first ?? [:]]
    }

    // Codex creates one outputs directory per task. Enumerate only this
    // structure, without recursing into work folders, caches, or app bundles.
    private func codexOutputFiles(_ root:URL) throws -> [(URL,String)] {
        let directoryKeys:[URLResourceKey]=[.isDirectoryKey,.isSymbolicLinkKey]
        let fileKeys:Set<URLResourceKey>=[.isDirectoryKey,.isSymbolicLinkKey,.isRegularFileKey,.fileSizeKey,.contentModificationDateKey]
        guard root.resolvingSymlinksInPath().path==root.path else { throw fail("Codex 接收目录不能包含符号链接") }
        let cacheDirectories:Set<String>=["node_modules","__pycache__","venv"]
        var files:[(URL,String)]=[]
        let dates=try fm.contentsOfDirectory(at:root,includingPropertiesForKeys:directoryKeys,options:.skipsHiddenFiles)
        for date in dates where date.lastPathComponent.range(of:"^[0-9]{4}-[0-9]{2}-[0-9]{2}$",options:.regularExpression) != nil {
            let info=try date.resourceValues(forKeys:Set(directoryKeys))
            guard info.isDirectory == true,info.isSymbolicLink != true else { continue }
            let tasks=try fm.contentsOfDirectory(at:date,includingPropertiesForKeys:directoryKeys,options:.skipsHiddenFiles)
            for task in tasks {
                let taskInfo=try task.resourceValues(forKeys:Set(directoryKeys))
                guard taskInfo.isDirectory == true,taskInfo.isSymbolicLink != true else { continue }
                let output=task.appendingPathComponent("outputs",isDirectory:true)
                guard let outputInfo=try? output.resourceValues(forKeys:Set(directoryKeys)),
                      outputInfo.isDirectory == true,outputInfo.isSymbolicLink != true else { continue }
                var enumerationError:Error?
                guard let enumerator=fm.enumerator(at:output,includingPropertiesForKeys:Array(fileKeys),
                    options:[.skipsHiddenFiles,.skipsPackageDescendants],errorHandler:{_,error in
                        enumerationError=error
                        return false
                    }) else { throw fail("无法读取 Codex 成果目录") }
                for case let file as URL in enumerator {
                    // Outputs can disappear while another task is rebuilding.
                    guard let info=try? file.resourceValues(forKeys:fileKeys) else { continue }
                    let name=file.lastPathComponent.lowercased()
                    if info.isSymbolicLink == true || (info.isDirectory == true && cacheDirectories.contains(name)) {
                        enumerator.skipDescendants()
                        continue
                    }
                    guard info.isRegularFile == true,
                          ![".download",".crdownload",".part",".partial",".tmp"].contains(where:{name.hasSuffix($0)}) else { continue }
                    let fingerprint="\(info.fileSize ?? 0):\(info.contentModificationDate?.timeIntervalSince1970 ?? 0)"
                    files.append((file,fingerprint))
                }
                if let error=enumerationError { throw error }
            }
        }
        return files
    }

    private func saveCodexSource(_ path:URL,_ p:[String:Any]) throws -> [String:Any] {
        let existing=try db.query("SELECT id,kind FROM sources WHERE path=?",[path.path]).first
        guard existing == nil || existing?["kind"] as? String == "codex_outputs" else {
            throw fail("此目录已有其他接收规则。请先移除旧规则，再添加 Codex 成果接收。")
        }
        let id=existing?["id"] as? String ?? uuid()
        let enabled=p["enabled"] as? Bool ?? true
        let baseline=existing == nil ? try codexOutputFiles(path) : []
        try db.transaction {
            // Older releases treat unfamiliar source kinds as generic folders.
            // Mark compatibility before storing this narrower authorization.
            try db.exec("INSERT OR IGNORE INTO schema_migrations VALUES(6,?)",[now()])
            try db.exec("PRAGMA user_version=6")
            try db.exec("INSERT INTO sources(id,path,kind,enabled) VALUES(?,?,'codex_outputs',?) ON CONFLICT(id) DO UPDATE SET enabled=excluded.enabled,error=NULL",[id,path.path,enabled])
            for (file,fingerprint) in baseline {
                try db.exec("INSERT INTO source_seen(source_id,path,fingerprint,stable) VALUES(?,?,?,-1)",[id,file.path,fingerprint])
            }
            if existing == nil { try log("success","Codex 接收已登记 \(baseline.count) 个现存文件作为基线",source:id) }
            try log("success",enabled ? "已启用 Codex 成果接收：\(path.path)" : "已暂停 Codex 成果接收",source:id)
        }
        return ["source":try db.query("SELECT * FROM sources WHERE id=?",[id]).first ?? [:],"baseline_count":baseline.count]
    }

    private func scanCodexOutputs(_ path:URL,sourceID:String) throws -> Int {
        let candidates=try codexOutputFiles(path)
        let rows=try db.query("SELECT path,fingerprint,stable,file_id FROM source_seen WHERE source_id=?",[sourceID])
        let previous=Dictionary(uniqueKeysWithValues:rows.map{($0["path"] as! String,$0)})
        var ready:[URL]=[]
        try db.transaction {
            for (file,fingerprint) in candidates {
                guard let prior=previous[file.path] else {
                    try db.exec("INSERT INTO source_seen(source_id,path,fingerprint,stable) VALUES(?,?,?,0)",[sourceID,file.path,fingerprint])
                    continue
                }
                if prior["fingerprint"] as? String != fingerprint {
                    try db.exec("UPDATE source_seen SET fingerprint=?,stable=0,hash=NULL,file_id=NULL WHERE source_id=? AND path=?",[fingerprint,sourceID,file.path])
                    continue
                }
                let stable=prior["stable"] as? Int ?? 0
                guard stable>=0,prior["file_id"] as? String == nil else { continue }
                if stable<2 { try db.exec("UPDATE source_seen SET stable=? WHERE source_id=? AND path=?",[stable+1,sourceID,file.path]) }
                if stable>=1 { ready.append(file) }
            }
        }
        var discovered=0
        var failures:[String]=[]
        for file in ready.prefix(100) {
            do {
                let result=try importFile(path:file.path,source:"codex_outputs",confirmed:false)
                let hash=(result["file"] as? [String:Any])?["hash"] as? String
                try db.exec("UPDATE source_seen SET file_id=?,hash=? WHERE source_id=? AND path=?",[result["id"],hash,sourceID,file.path])
                if result["duplicate"] as? Bool != true { discovered+=1 }
            } catch {
                try db.exec("UPDATE source_seen SET stable=0 WHERE source_id=? AND path=?",[sourceID,file.path])
                failures.append("\(file.lastPathComponent)：\(error.localizedDescription)")
            }
        }
        if !failures.isEmpty { throw fail(failures.prefix(3).joined(separator:"；")) }
        return discovered
    }

    func scan() throws -> [String:Any] {
        lock.lock(); defer { lock.unlock() }
        var discovered=0; var errors:[String]=[]
        guard (setting("watch_paused",false) as? Bool) != true else { return ["discovered":0,"errors":[],"paused":true] }
        for source in try db.query("SELECT * FROM sources WHERE enabled=1") {
            let id=source["id"] as! String,path=source["path"] as! String,kind=source["kind"] as! String
            do {
                if kind == "codex_outputs" {
                    discovered += try scanCodexOutputs(URL(fileURLWithPath:path,isDirectory:true),sourceID:id)
                    try db.exec("UPDATE sources SET last_scan=?,error=NULL WHERE id=?",[now(),id])
                    continue
                }
                let urls=try expand([path]); var pendingManifests:[URL]=[]
                for url in urls {
                    let name=url.lastPathComponent.lowercased(); if name.hasPrefix(".") || [".download",".crdownload",".part",".partial",".tmp"].contains(where:{name.hasSuffix($0)}) { continue }
                    let attrs=try url.resourceValues(forKeys:[.fileSizeKey,.contentModificationDateKey]); let fingerprint="\(attrs.fileSize ?? 0):\(attrs.contentModificationDate?.timeIntervalSince1970 ?? 0)"
                    let old=try db.query("SELECT * FROM source_seen WHERE source_id=? AND path=?",[id,url.path]).first
                    if old == nil { try db.exec("INSERT INTO source_seen(source_id,path,fingerprint,stable) VALUES(?,?,?,0)",[id,url.path,fingerprint]); continue }
                    if old?["fingerprint"] as? String != fingerprint { try db.exec("UPDATE source_seen SET fingerprint=?,stable=0,hash=NULL,file_id=NULL WHERE source_id=? AND path=?",[fingerprint,id,url.path]); continue }
                    if (old?["stable"] as? Int ?? 0) < 0 || old?["file_id"] as? String != nil { continue }
                    let stable=(old?["stable"] as? Int ?? 0)+1
                    try db.exec("UPDATE source_seen SET stable=? WHERE source_id=? AND path=?",[stable,id,url.path])
                    if stable<2 { continue }
                    if name.hasSuffix(".workvault.json"),kind == "dedicated" { pendingManifests.append(url); continue }
                    let result=try importFile(path:url.path,name:nil,projectID:nil,source:kind,confirmed:false)
                    let fileID=result["id"] as! String; let hash=(result["file"] as? [String:Any])?["hash"] as? String
                    try db.exec("UPDATE source_seen SET file_id=?,hash=? WHERE source_id=? AND path=?",[fileID,hash,id,url.path]); discovered += result["duplicate"] as? Bool == true ? 0 : 1
                }
                for url in pendingManifests { let count=try importManifest(url); discovered += count; try db.exec("UPDATE source_seen SET file_id='manifest' WHERE source_id=? AND path=?",[id,url.path]) }
                try db.exec("UPDATE sources SET last_scan=?,error=NULL WHERE id=?",[now(),id])
            } catch { let message=error.localizedDescription; errors.append(message); try db.exec("UPDATE sources SET last_scan=?,error=? WHERE id=?",[now(),message,id]); try log("error",message,source:id) }
        }
        if discovered>0 { try log("success","扫描发现 \(discovered) 个新文件，未确认来源保留在收件箱") }
        return ["discovered":discovered,"errors":errors]
    }
    private func importManifest(_ url:URL) throws -> Int {
        guard try regularFile(url)<1024*1024 else { throw fail("任务清单过大") }
        guard let doc=try JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [String:Any],doc["workvault"] as? Int == 1,let title=doc["title"] as? String,let paths=doc["files"] as? [String],!paths.isEmpty,paths.count<=1000 else { throw fail("无法识别 WorkVault 任务清单") }
        let conversation=doc["conversation_id"] as? String; let existing: String?
        if let conversation=conversation,!conversation.isEmpty { existing=try db.query("SELECT project_id id FROM project_sources WHERE conversation_id=?",[conversation]).first?["id"] as? String } else { existing=nil }
        let projectID:String
        if let existing=existing { projectID=existing }
        else { var p:[String:Any]=["title":title,"original_title":title,"title_source":"用户提供任务清单","source_url":doc["source_url"] as? String ?? ""]; if let c=conversation { p["conversation_id"]=c }; projectID=(try saveProject(p)["project"] as! [String:Any])["id"] as! String }
        let parent=url.deletingLastPathComponent(); var count=0
        for path in paths { guard validRelative(path) else { throw fail("任务清单包含不安全路径") }; let target=parent.appendingPathComponent(path).standardizedFileURL; guard target.path.hasPrefix(parent.path+"/") else { throw fail("任务清单文件超出授权目录") }; _ = try importFile(path:target.path,name:nil,projectID:projectID,source:"manifest",confirmed:true); count += 1 }
        return count
    }
    private func importExport(path:String) throws -> [String:Any] {
        let url=URL(fileURLWithPath:path).standardizedFileURL
        var files:[URL]=[]; var temp:URL?
        defer { if let temp=temp { try? fm.removeItem(at:temp) } }
        var directory:ObjCBool=false
        if fm.fileExists(atPath:url.path,isDirectory:&directory),directory.boolValue { files=try expand([url.path]).filter{$0.pathExtension.lowercased() == "json"} }
        else if url.pathExtension.lowercased() == "zip" { let destination=root.appendingPathComponent("tmp/export-\(uuid())"); temp=destination; try extractZIP(url,to:destination); files=try expand([destination.path]).filter{$0.pathExtension.lowercased() == "json"} }
        else { files=[url] }
        var conversations:[[String:Any]]=[]; var warnings:[String]=[]
        for file in files {
            let lower=file.lastPathComponent.lowercased(); if files.count>1,!lower.contains("conversation"),!lower.contains("chat") { continue }
            guard try regularFile(file)<=128*1024*1024 else { warnings.append("跳过过大 JSON：\(file.lastPathComponent)"); continue }
            let object=try JSONSerialization.jsonObject(with:Data(contentsOf:file))
            if let array=object as? [[String:Any]] { conversations += array.filter{$0["title"] is String && ($0["id"] is String || $0["conversation_id"] is String)} }
            else if let dict=object as? [String:Any] { for key in ["conversations","chats","items"] { if let array=dict[key] as? [[String:Any]] { conversations += array.filter{$0["title"] is String} } }; if dict["title"] is String { conversations.append(dict) } }
        }
        guard !conversations.isEmpty else { throw fail("未检测到受支持的会话 JSON 结构；未修改文件库。请提供 conversations JSON 或包含该文件的官方导出包。") }
        var created=0,missing=0
        for conversation in conversations {
            guard let title=conversation["title"] as? String else { continue }
            let cid=conversation["id"] as? String ?? conversation["conversation_id"] as? String
            let existing: String? = try cid.flatMap{try db.query("SELECT project_id id FROM project_sources WHERE conversation_id=?",[$0]).first?["id"] as? String}
            let projectID:String
            if let existing=existing { projectID=existing }
            else {
                let explicitWork=(conversation["type"] as? String)?.lowercased() == "work" || (conversation["mode"] as? String)?.lowercased() == "work"
                var params:[String:Any]=["title":title,"original_title":title,"source_confirmed":explicitWork,"title_source":explicitWork ? "官方导出（Work 标记）" : "官方导出（类型待确认）","description":explicitWork ? "来自用户提供的官方导出文件。" : "导出中无法可靠区分 Work 与普通 Chat；请手动确认。","source_url":conversation["url"] as? String ?? cid.map{"https://chatgpt.com/c/\($0)"} ?? ""]
                if let cid=cid { params["conversation_id"]=cid }
                projectID=(try saveProject(params)["project"] as! [String:Any])["id"] as! String; created += 1
            }
            var attachments:[[String:Any]]=[]
            func walk(_ value:Any,_ depth:Int=0) {
                guard depth<30,attachments.count<10000 else { return }
                if let d=value as? [String:Any] {
                    if d["file_id"] is String || (d["name"] is String && (d["download_url"] != nil || d["mime_type"] != nil)) { attachments.append(d) }
                    for (key,v) in d where !["content","parts","text"].contains(key) || v is [String:Any] || v is [Any] { walk(v,depth+1) }
                } else if let list=value as? [Any] { for item in list.prefix(100000) { walk(item,depth+1) } }
                else if let text=value as? String,text.contains("sandbox:/mnt/data/") {
                    if let regex=try? NSRegularExpression(pattern:"sandbox:/mnt/data/([^\\s\\)\\]\"<>]+)") {
                        let range=NSRange(text.startIndex...,in:text)
                        for match in regex.matches(in:text,range:range) { if let r=Range(match.range(at:1),in:text) { let name=String(text[r]).removingPercentEncoding ?? String(text[r]); attachments.append(["name":URL(fileURLWithPath:name).lastPathComponent,"reference":"sandbox:/mnt/data/"+String(text[r])]) } }
                    }
                }
            }
            walk(conversation)
            for attachment in attachments {
                let metadata=jsonString(attachment)
                if try db.query("SELECT id FROM missing_attachments WHERE project_id=? AND metadata=? LIMIT 1",[projectID,metadata]).isEmpty { try db.exec("INSERT INTO missing_attachments(id,project_id,conversation_id,name,metadata) VALUES(?,?,?,?,?)",[uuid(),projectID,cid,attachment["name"] as? String ?? attachment["file_name"] as? String ?? attachment["file_id"] as? String ?? "未知附件",metadata]); missing += 1 }
            }
            try event("history","解析导出会话标题；附件需补充原文件",project:projectID)
        }
        warnings.append("会话标题已导入；除明确 Work 标记外，任务类型均待确认。不会按标题合并任务。附件仅保留可识别元数据，不自动下载或伪造原文件。")
        try log("success","历史导入新增 \(created) 个项目，\(missing) 条缺失附件索引")
        return ["projects":created,"missing_files":missing,"warnings":warnings]
    }
    private func integrity() throws -> [String:Any] {
        try checkStorage(); var errors:[String]=[]; var checked=0
        for row in try db.query("SELECT * FROM blobs") { let relative=row["path"] as? String ?? ""; let url=root.appendingPathComponent(relative); do { guard validRelative(relative),relative.hasPrefix("blobs/") else { throw fail("文件实体路径无效") }; _ = try regularFile(url); guard try Store.hashFile(url) == row["hash"] as? String else { throw fail("哈希不一致") }; checked += 1 } catch { errors.append("\(row["hash"] ?? "")：\(error.localizedDescription)") } }
        for row in try db.query("SELECT f.id FROM files f LEFT JOIN versions v ON v.id=f.current_version WHERE v.id IS NULL OR v.file_id<>f.id") { errors.append("当前版本引用无效：\(row)") }
        for row in try db.query("SELECT d.project_id,d.file_id,d.version_id FROM project_deliverables d JOIN versions v ON v.id=d.version_id WHERE v.file_id<>d.file_id") { errors.append("最终成果版本引用无效：\(row)") }
        for row in try db.query("PRAGMA foreign_key_check") { errors.append("外键异常：\(row)") }
        for row in try db.query("PRAGMA integrity_check") { if row["integrity_check"] as? String != "ok" { errors.append(String(describing:row)) } }
        return ["checked":checked,"errors":errors]
    }
    private func resources() -> [String:Any] {
        var usage=rusage(); getrusage(RUSAGE_SELF,&usage)
        let taskMemory=usage.ru_maxrss
        return ["pid":Int(getpid()),"peak_memory_bytes":taskMemory,"cpu_user_seconds":Double(usage.ru_utime.tv_sec)+Double(usage.ru_utime.tv_usec)/1e6,"cpu_system_seconds":Double(usage.ru_stime.tv_sec)+Double(usage.ru_stime.tv_usec)/1e6,"physical_memory_bytes":ProcessInfo.processInfo.physicalMemory,"active_processors":ProcessInfo.processInfo.activeProcessorCount,"ai_autostart":false]
    }
    private func backup(destination:String,includeIndex:Bool) throws -> [String:Any] {
        try checkStorage()
        let parent=URL(fileURLWithPath:destination).standardizedFileURL
        var dir:ObjCBool=false; guard fm.fileExists(atPath:parent.path,isDirectory:&dir),dir.boolValue,fm.isWritableFile(atPath:parent.path) else { throw fail("备份目录不存在或不可写") }
        guard parent.path != root.path,!parent.path.hasPrefix(root.path+"/blobs/"),!parent.path.hasPrefix(root.path+"/tmp/") else { throw fail("请使用文件库备份目录或独立目录") }
        let target=parent.appendingPathComponent("WorkVault-\(Int(Date().timeIntervalSince1970))-\(uuid().prefix(6)).wvbackup")
        let temp=parent.appendingPathComponent(".workvault-backup-\(uuid()).partial")
        do {
            try fm.createDirectory(at:temp,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
            try db.backup(to:temp.appendingPathComponent("workvault.sqlite"))
            if !includeIndex {
                let snapshot=try DB(temp.appendingPathComponent("workvault.sqlite"))
                for table in ["ai_fts","ai_chunks","ai_vectors","ai_index","ai_indexes"] {
                    if !(try snapshot.query("SELECT name FROM sqlite_master WHERE name=?",[table])).isEmpty { try snapshot.exec("DELETE FROM \(table)") }
                }
                try snapshot.exec("VACUUM")
                try snapshot.makePortableAndClose()
            }
            let rows=try db.query("SELECT path,size FROM blobs"); let required=rows.reduce(Int64(0)){$0+Int64($1["size"] as? Int ?? 0)}
            let free=(try? fm.attributesOfFileSystem(forPath:parent.path)[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
            guard free>required+32*1024*1024 else { throw fail("备份目标磁盘空间不足") }
            for row in rows { let relative=row["path"] as! String; guard validRelative(relative),relative.hasPrefix("blobs/") else { throw fail("数据库包含不安全路径") }; let dest=temp.appendingPathComponent(relative); try fm.createDirectory(at:dest.deletingLastPathComponent(),withIntermediateDirectories:true); try fm.copyItem(at:root.appendingPathComponent(relative),to:dest) }
            if includeIndex { let index=root.appendingPathComponent("indexes"); if fm.fileExists(atPath:index.path) { try fm.copyItem(at:index,to:temp.appendingPathComponent("indexes")) } }
            var manifest:[[String:Any]]=[]
            for url in try expand([temp.path]) where !url.lastPathComponent.hasSuffix("-wal") && !url.lastPathComponent.hasSuffix("-shm") {
                let relative=String(url.path.dropFirst(temp.path.count+1)); manifest.append(["path":relative,"sha256":try Store.hashFile(url),"size":try regularFile(url)])
            }
            let doc:[String:Any]=["format":"workvault-backup","version":1,"schema":try db.query("PRAGMA user_version").first?["user_version"] ?? 5,"app_version":"1.3.0","created_at":now(),"include_index":includeIndex,"projects":try db.query("SELECT count(*) n FROM projects").first?["n"] ?? 0,"files":try db.query("SELECT count(*) n FROM files").first?["n"] ?? 0,"manifest":manifest]
            try JSONSerialization.data(withJSONObject:doc,options:[.prettyPrinted,.sortedKeys]).write(to:temp.appendingPathComponent("manifest.json"),options:.atomic)
            let check=try inspectBackup(path:temp.path); guard check["valid"] as? Bool == true else { throw fail("备份校验失败：\(check["errors"] ?? "")") }
            try fm.moveItem(at:temp,to:target); try db.exec("INSERT INTO backups VALUES(?,?,?,?)",[uuid(),target.path,now(),manifest.count]); try log("success","手动备份已完成并校验：\(target.lastPathComponent)")
            return ["path":target.path,"files":manifest.count]
        } catch { try? fm.removeItem(at:temp); throw error }
    }
    private func inspectBackup(path:String) throws -> [String:Any] {
        let target=URL(fileURLWithPath:path).standardizedFileURL; let manifestPath=target.appendingPathComponent("manifest.json")
        guard fm.fileExists(atPath:manifestPath.path),try regularFile(manifestPath)<16*1024*1024 else { throw fail("备份清单不存在或过大") }
        guard let doc=try JSONSerialization.jsonObject(with:Data(contentsOf:manifestPath)) as? [String:Any],doc["format"] as? String == "workvault-backup",doc["version"] as? Int == 1,(doc["schema"] as? Int ?? 999)<=Self.supportedSchemaVersion,let manifest=doc["manifest"] as? [[String:Any]],manifest.count<=100000 else { throw fail("备份版本不兼容或格式无效") }
        var errors:[String]=[]; var seen=Set<String>()
        for row in manifest {
            guard let relative=row["path"] as? String,validRelative(relative),let expected=row["sha256"] as? String,expected.count==64,!seen.contains(relative) else { errors.append("清单路径或哈希无效"); continue }
            seen.insert(relative); let url=target.appendingPathComponent(relative)
            do { let size=try regularFile(url); guard size == (row["size"] as? NSNumber)?.int64Value,try Store.hashFile(url) == expected else { throw fail("大小或哈希不一致") } } catch { errors.append("\(relative)：\(error.localizedDescription)") }
        }
        if !seen.contains("workvault.sqlite") { errors.append("备份缺少数据库") }
        return ["valid":errors.isEmpty,"summary":["version":doc["app_version"] ?? "","created_at":doc["created_at"] ?? "","projects":doc["projects"] ?? 0,"files":doc["files"] ?? 0,"entities":manifest.count,"include_index":doc["include_index"] ?? false],"errors":errors]
    }
    private func restoreBackup(path:String,destination:String) throws -> [String:Any] {
        let check=try inspectBackup(path:path); guard check["valid"] as? Bool == true else { throw fail("备份完整性校验失败，未恢复：\(check["errors"] ?? "")") }
        let target=URL(fileURLWithPath:destination).standardizedFileURL
        guard !fm.fileExists(atPath:target.path),!target.path.hasPrefix(root.path+"/"),!root.path.hasPrefix(target.path+"/") else { throw fail("恢复目标必须是文件库之外尚不存在的新目录，防止覆盖当前数据") }
        let parent=target.deletingLastPathComponent(); guard fm.isWritableFile(atPath:parent.path) else { throw fail("恢复目标父目录不可写") }
        let source=URL(fileURLWithPath:path).standardizedFileURL; let temp=parent.appendingPathComponent(".workvault-restore-\(uuid()).partial")
        do {
            try fm.createDirectory(at:temp,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
            let doc=try JSONSerialization.jsonObject(with:Data(contentsOf:source.appendingPathComponent("manifest.json"))) as! [String:Any]
            for row in doc["manifest"] as! [[String:Any]] { let relative=row["path"] as! String; let dest=temp.appendingPathComponent(relative); try fm.createDirectory(at:dest.deletingLastPathComponent(),withIntermediateDirectories:true); try fm.copyItem(at:source.appendingPathComponent(relative),to:dest) }
            let result=try verifyLibrary(at:temp); guard (result["errors"] as? [String] ?? []).isEmpty else { throw fail("恢复后完整性检查失败") }
            try fm.moveItem(at:temp,to:target); try log("success","备份已恢复到独立目录：\(target.path)")
            return ["path":target.path,"checked":result["checked"] ?? 0,"activated":false,"note":"已恢复到独立新目录；当前文件库保持不变。退出后使用选择已有文件库入口打开恢复目录。"]
        } catch { try? fm.removeItem(at:temp); throw error }
    }
    private func switchLibrary(path:String) throws -> [String:Any] {
        guard !importing else { throw fail("请等待文件导入完成或取消后切换文件库") }
        let target=URL(fileURLWithPath:path).standardizedFileURL
        if target.path == root.path { return ["root":root.path,"unchanged":true] }
        guard fm.fileExists(atPath:target.appendingPathComponent("workvault.sqlite").path),fm.fileExists(atPath:target.appendingPathComponent("blobs").path) else { throw fail("该目录不是现有 WorkVault 文件库") }
        do {
            let validation=try DB(target.appendingPathComponent("workvault.sqlite"),readOnly:true)
            guard (try validation.query("PRAGMA user_version").first?["user_version"] as? Int ?? 0)<=Self.supportedSchemaVersion else { throw fail("文件库来自更新版本") }
            guard let version=try validation.query("SELECT max(version) n FROM schema_migrations").first?["n"] as? Int,version<=Self.supportedSchemaVersion else { throw fail("文件库结构版本较新或不兼容") }
            guard try validation.query("PRAGMA integrity_check").first?["integrity_check"] as? String == "ok",try validation.query("PRAGMA foreign_key_check").isEmpty else { throw fail("目标数据库完整性校验失败") }
            for row in try validation.query("SELECT * FROM blobs") { guard let relative=row["path"] as? String,validRelative(relative),relative.hasPrefix("blobs/"),try Store.hashFile(target.appendingPathComponent(relative)) == row["hash"] as? String else { throw fail("目标文件实体校验失败") } }
        }
        let replacement=try DB(target.appendingPathComponent("workvault.sqlite"))
        let old=root.path; db=replacement; root=target; try folders(); try schema(); try log("success","已切换文件库；原文件库保留于：\(old)")
        return ["root":root.path,"old_root":old]
    }
    private func verifyLibrary(at url:URL) throws -> [String:Any] {
        let library=try Store(root:url); let check=try library.integrity(); try library.db.makePortableAndClose(); return check
    }
    private func migrate(to destination:String) throws -> [String:Any] {
        guard !importing else { throw fail("请等待文件导入完成或取消后迁移") }
        try checkStorage(); let target=URL(fileURLWithPath:destination).standardizedFileURL
        guard target.path != root.path,!target.path.hasPrefix(root.path+"/"),!root.path.hasPrefix(target.path+"/") else { throw fail("迁移目标必须独立于当前文件库") }
        if fm.fileExists(atPath:target.path) { guard try fm.contentsOfDirectory(atPath:target.path).filter({$0 != ".workvault.lock"}).isEmpty else { throw fail("迁移目标必须为空目录") } }
        else { try fm.createDirectory(at:target,withIntermediateDirectories:true) }
        guard fm.isWritableFile(atPath:target.path) else { throw fail("迁移目标不可写") }
        let rows=try db.query("SELECT path,size,hash FROM blobs"); let required=rows.reduce(Int64(0)){$0+Int64($1["size"] as? Int ?? 0)}
        let free=(try? fm.attributesOfFileSystem(forPath:target.path)[.systemFreeSize] as? NSNumber)?.int64Value ?? 0; guard free>required+64*1024*1024 else { throw fail("迁移目标磁盘空间不足") }
        let staging=target.appendingPathComponent(".workvault-migration-\(uuid()).partial")
        do {
            try fm.createDirectory(at:staging,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
            try db.backup(to:staging.appendingPathComponent("workvault.sqlite"))
            for row in rows { let relative=row["path"] as! String; guard validRelative(relative),relative.hasPrefix("blobs/") else { throw fail("数据库含不安全路径") }; let dest=staging.appendingPathComponent(relative); try fm.createDirectory(at:dest.deletingLastPathComponent(),withIntermediateDirectories:true); try fm.copyItem(at:root.appendingPathComponent(relative),to:dest); guard try Store.hashFile(dest) == row["hash"] as? String else { throw fail("迁移哈希校验失败") } }
            for folder in ["working","indexes"] { let url=root.appendingPathComponent(folder); if fm.fileExists(atPath:url.path) { try fm.copyItem(at:url,to:staging.appendingPathComponent(folder)) } }
            let check=try verifyLibrary(at:staging); guard (check["errors"] as? [String] ?? []).isEmpty else { throw fail("迁移后数据库或文件校验失败") }
            for url in try fm.contentsOfDirectory(at:staging,includingPropertiesForKeys:nil) { try fm.moveItem(at:url,to:target.appendingPathComponent(url.lastPathComponent)) }
            try fm.removeItem(at:staging)
            let replacement=try DB(target.appendingPathComponent("workvault.sqlite")); let old=root.path
            db=replacement; root=target; try folders(); try log("success","已迁移并校验。旧文件库保留于：\(old)")
            return ["root":root.path,"old_root":old,"checked":check["checked"] ?? 0]
        } catch { try? fm.removeItem(at:staging); throw error }
    }
    private func validRelative(_ path:String) -> Bool {
        guard !path.isEmpty,!path.hasPrefix("/"),!path.contains("\\"),!path.contains("\0"),!path.contains(":"),path.count<4096 else { return false }
        return !path.split(separator:"/",omittingEmptySubsequences:false).contains(where:{$0 == ".." || $0 == "." || $0.isEmpty})
    }
    private struct ZipEntry { let name:String; let compressed:Int64; let size:Int64 }
    private func zipEntries(_ url:URL,maxBytes:Int64=1024*1024*1024) throws -> [ZipEntry] {
        let size=try regularFile(url); guard size<=2*1024*1024*1024 else { throw fail("压缩包超过 2 GiB 上限") }
        let data=try Data(contentsOf:url,options:.mappedIfSafe)
        func u16(_ i:Int)->UInt16 { UInt16(data[i])|UInt16(data[i+1])<<8 }
        func u32(_ i:Int)->UInt32 { UInt32(data[i])|UInt32(data[i+1])<<8|UInt32(data[i+2])<<16|UInt32(data[i+3])<<24 }
        guard data.count>=22 else { throw fail("ZIP 文件损坏") }
        var end:Int?
        for i in stride(from:data.count-22,through:max(0,data.count-65557),by:-1) { if u32(i)==0x06054b50 { end=i; break } }
        guard let e=end,u16(e+4)==0,u16(e+6)==0,u16(e+8)==u16(e+10),u16(e+10)<10000,u32(e+16) != 0xffffffff else { throw fail("不支持多卷、ZIP64 或过多条目的压缩包") }
        let count=Int(u16(e+10)); var pos=Int(u32(e+16)); let centralSize=Int(u32(e+12)); guard pos>=0,centralSize>=0,pos+centralSize<=e else { throw fail("ZIP 中央目录损坏") }
        var result:[ZipEntry]=[]; var total:Int64=0
        for _ in 0..<count {
            guard pos+46<=data.count,u32(pos)==0x02014b50 else { throw fail("ZIP 条目损坏") }
            let flags=u16(pos+8),compressed=Int64(u32(pos+20)),expanded=Int64(u32(pos+24)); let nameLen=Int(u16(pos+28)),extraLen=Int(u16(pos+30)),commentLen=Int(u16(pos+32)); let attr=u32(pos+38)
            guard pos+46+nameLen+extraLen+commentLen<=data.count,flags&1==0 else { throw fail("不支持加密或损坏压缩包") }
            let bytes=data.subdata(in:pos+46..<pos+46+nameLen)
            guard let name=String(data:bytes,encoding:.utf8),!name.isEmpty else { throw fail("ZIP 文件名不是 UTF-8，无法安全导入") }
            let trimmed=name.hasSuffix("/") ? String(name.dropLast()) : name
            guard validRelative(trimmed),!trimmed.hasPrefix("-"),((attr>>16)&0xf000) != 0xa000 else { throw fail("压缩包包含路径穿越或符号链接") }
            guard expanded<=maxBytes,expanded<=max(1024*1024,compressed*200) else { throw fail("压缩包条目过大或压缩比异常") }
            total += expanded; guard total<=maxBytes else { throw fail("压缩包解压总体积超限") }
            result.append(ZipEntry(name:name,compressed:compressed,size:expanded)); pos += 46+nameLen+extraLen+commentLen
        }
        return result
    }
    private func zipPattern(_ name:String) -> String { name.map { "*?[]".contains($0) ? "\\"+String($0) : String($0) }.joined() }
    private func extractZIP(_ source:URL,to destination:URL) throws {
        let entries=try zipEntries(source)
        try fm.createDirectory(at:destination,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        var total:Int64=0
        for entry in entries {
            let name=entry.name.hasSuffix("/") ? String(entry.name.dropLast()) : entry.name
            let target=destination.appendingPathComponent(name).standardizedFileURL
            guard target.path.hasPrefix(destination.path+"/") else { throw fail("ZIP 路径超出解压目录") }
            if entry.name.hasSuffix("/") { try fm.createDirectory(at:target,withIntermediateDirectories:true); continue }
            try fm.createDirectory(at:target.deletingLastPathComponent(),withIntermediateDirectories:true)
            guard !fm.fileExists(atPath:target.path),fm.createFile(atPath:target.path,contents:nil,attributes:[.posixPermissions:0o600]) else { throw fail("ZIP 包含重复或冲突路径") }
            let output=try FileHandle(forWritingTo:target)
            let process=Process(); process.executableURL=URL(fileURLWithPath:"/usr/bin/unzip"); process.arguments=["-p",source.path,zipPattern(entry.name)]
            let pipe=Pipe(); process.standardOutput=pipe; process.standardError=FileHandle.nullDevice
            var written:Int64=0
            do {
                try process.run()
                while let chunk=try pipe.fileHandleForReading.read(upToCount:64*1024),!chunk.isEmpty {
                    written += Int64(chunk.count); total += Int64(chunk.count)
                    guard written<=entry.size,total<=1024*1024*1024 else { throw fail("ZIP 实际输出超过清单或安全上限，已中止解压") }
                    try output.write(contentsOf:chunk)
                }
                process.waitUntilExit(); try output.synchronize(); try output.close()
                guard process.terminationStatus==0,written==entry.size else { throw fail("ZIP 条目损坏或实际大小不符") }
            } catch {
                if process.isRunning { kill(process.processIdentifier,SIGKILL); process.waitUntilExit() }
                try? output.close(); try? fm.removeItem(at:target); throw error
            }
        }
    }
    private func runTool(_ executable:String,_ arguments:[String],maxOutput:Int) throws -> Data {
        let process=Process(); process.executableURL=URL(fileURLWithPath:executable); process.arguments=arguments
        let pipe=Pipe(); process.standardOutput=pipe; process.standardError=FileHandle.nullDevice
        try process.run(); var output=Data()
        while let chunk=try pipe.fileHandleForReading.read(upToCount:64*1024),!chunk.isEmpty { output.append(chunk); if output.count>maxOutput { process.terminate(); process.waitUntilExit(); throw fail("预览或解压输出超过安全上限") } }
        process.waitUntilExit(); guard process.terminationStatus == 0 else { throw fail("本地文件解析失败，文件可能损坏或不受支持") }; return output
    }
}
private final class XMLText:NSObject,XMLParserDelegate {
    var output=""; private var recording=false
    func parse(_ data:Data) { let parser=XMLParser(data:data); parser.shouldResolveExternalEntities=false; parser.delegate=self; parser.parse() }
    func parser(_ parser:XMLParser,didStartElement name:String,namespaceURI:String?,qualifiedName:String?,attributes:[String:String]) {
        let local=name.split(separator:":").last.map(String.init) ?? name
        recording=["t","v"].contains(local)
        if ["p","row","si"].contains(local) { output += "\n" }
        if local == "c",let r=attributes["r"] { output += "\(r): " }
        if local == "sheet",let n=attributes["name"] { output += "工作表：\(n)\n" }
    }
    func parser(_ parser:XMLParser,foundCharacters string:String) { if recording { output += string } }
    func parser(_ parser:XMLParser,didEndElement name:String,namespaceURI:String?,qualifiedName:String?) { if ["t","v"].contains(name.split(separator:":").last.map(String.init) ?? name) { recording=false; output += " " } }
}
