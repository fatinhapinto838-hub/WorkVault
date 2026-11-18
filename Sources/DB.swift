import Foundation
import CSQLite

enum VaultError: Error, LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return "未知错误" }
}
func fail(_ text: String) -> VaultError { .message(text) }
func now() -> String { ISO8601DateFormatter().string(from: Date()) }
func uuid() -> String { UUID().uuidString.lowercased() }
func jsonString(_ value: Any) -> String { (try? String(data: JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed,.sortedKeys]), encoding:.utf8)) ?? "null" }
func jsonValue(_ string: String) -> Any? { try? JSONSerialization.jsonObject(with: Data(string.utf8), options:.fragmentsAllowed) }
let sqlTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class DB {
    private var handle: OpaquePointer?
    private let mutex = NSRecursiveLock()
    private var transactionDepth=0
    init(_ url: URL, readOnly:Bool = false) throws {
        let walSize=(try? FileManager.default.attributesOfItem(atPath:url.path+"-wal")[.size] as? NSNumber)?.int64Value ?? 0
        // A checkpointed WAL database can be opened without creating sidecars.
        // Never ignore a nonempty WAL: it may contain committed transactions.
        let immutable=readOnly && walSize==0
        let filename=immutable ? url.absoluteString+"?immutable=1" : url.path
        let flags=(readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_CREATE|SQLITE_OPEN_READWRITE)|SQLITE_OPEN_FULLMUTEX|(immutable ? SQLITE_OPEN_URI : 0)
        if sqlite3_open_v2(filename,&handle,flags,nil) != SQLITE_OK { sqlite3_close(handle); handle=nil; throw fail("无法打开 SQLite 数据库") }
        sqlite3_busy_timeout(handle, 5000)
        try exec("PRAGMA foreign_keys=ON")
        if !readOnly { try exec("PRAGMA journal_mode=WAL"); try exec("PRAGMA synchronous=FULL") }
    }
    deinit { sqlite3_close(handle) }
    func close() throws {
        mutex.lock(); defer { mutex.unlock() }
        guard let pointer=handle else { return }
        guard sqlite3_close(pointer)==SQLITE_OK else { throw fail("数据库仍有未完成操作，无法关闭") }
        handle=nil
    }
    func makePortableAndClose() throws {
        try exec("PRAGMA wal_checkpoint(TRUNCATE)")
        try exec("PRAGMA journal_mode=DELETE")
        try close()
    }
    func exec(_ sql: String, _ args:[Any?] = []) throws { _ = try query(sql,args) }
    func query(_ sql:String,_ args:[Any?] = []) throws -> [[String:Any]] {
        mutex.lock(); defer { mutex.unlock() }
        guard handle != nil else { throw fail("数据库连接已关闭") }
        var stmt:OpaquePointer?
        guard sqlite3_prepare_v2(handle,sql,-1,&stmt,nil) == SQLITE_OK else { throw fail("数据库语句错误：\(String(cString:sqlite3_errmsg(handle)))") }
        defer { sqlite3_finalize(stmt) }
        for (i,value) in args.enumerated() {
            let idx = Int32(i+1)
            switch value {
            case nil, is NSNull: sqlite3_bind_null(stmt,idx)
            case let x as String: sqlite3_bind_text(stmt,idx,x,-1,sqlTransient)
            case let x as Bool: sqlite3_bind_int64(stmt,idx,x ? 1 : 0)
            case let x as Int: sqlite3_bind_int64(stmt,idx,Int64(x))
            case let x as Int64: sqlite3_bind_int64(stmt,idx,x)
            case let x as Double: sqlite3_bind_double(stmt,idx,x)
            case let x as Data: _ = x.withUnsafeBytes { sqlite3_bind_blob(stmt,idx,$0.baseAddress,Int32(x.count),sqlTransient) }
            default: sqlite3_bind_text(stmt,idx,String(describing:value!),-1,sqlTransient)
            }
        }
        var rows:[[String:Any]]=[]
        while true {
            let code=sqlite3_step(stmt)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw fail("数据库操作失败（\(sql.prefix(100))）：\(String(cString:sqlite3_errmsg(handle)))") }
            var row:[String:Any]=[:]
            for i in 0..<sqlite3_column_count(stmt) {
                let key=String(cString:sqlite3_column_name(stmt,i))
                switch sqlite3_column_type(stmt,i) {
                case SQLITE_INTEGER: row[key]=Int(sqlite3_column_int64(stmt,i))
                case SQLITE_FLOAT: row[key]=sqlite3_column_double(stmt,i)
                case SQLITE_TEXT: row[key]=String(cString:sqlite3_column_text(stmt,i))
                case SQLITE_BLOB:
                    let count=Int(sqlite3_column_bytes(stmt,i)); if let p=sqlite3_column_blob(stmt,i) { row[key]=Data(bytes:p,count:count) } else { row[key]=Data() }
                default: row[key]=NSNull()
                }
            }
            rows.append(row)
        }
        return rows
    }
    func transaction<T>(_ body:() throws -> T) throws -> T {
        mutex.lock(); defer { mutex.unlock() }
        let depth=transactionDepth; let savepoint="workvault_\(depth)"
        try exec(depth == 0 ? "BEGIN IMMEDIATE" : "SAVEPOINT \(savepoint)")
        transactionDepth += 1
        defer { transactionDepth -= 1 }
        do { let result=try body(); try exec(depth == 0 ? "COMMIT" : "RELEASE SAVEPOINT \(savepoint)"); return result }
        catch { if depth == 0 { try? exec("ROLLBACK") } else { try? exec("ROLLBACK TO SAVEPOINT \(savepoint)"); try? exec("RELEASE SAVEPOINT \(savepoint)") }; throw error }
    }
    func backup(to url: URL) throws {
        mutex.lock(); defer { mutex.unlock() }
        var dest:OpaquePointer?
        guard sqlite3_open(url.path,&dest) == SQLITE_OK else { throw fail("备份数据库无法创建") }
        defer { sqlite3_close(dest) }
        guard let backup=sqlite3_backup_init(dest,"main",handle,"main") else { throw fail("无法创建 SQLite 快照") }
        let result=sqlite3_backup_step(backup,-1); let finish=sqlite3_backup_finish(backup)
        guard result == SQLITE_DONE && finish == SQLITE_OK else { throw fail("数据库快照失败") }
        guard sqlite3_exec(dest,"PRAGMA journal_mode=DELETE",nil,nil,nil)==SQLITE_OK else { throw fail("数据库快照无法转为独立存储格式") }
    }
}
