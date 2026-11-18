import Foundation

@main
struct AITests {
    static func main() throws {
        let base = URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("work/workvault-ai-tests-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:base,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:base) }
        let store = try Store(root:base.appendingPathComponent("vault")), ai = try AIEngine(store:store)
        store.externalRPC = { try ai.rpc($0) }
        var results: [[String:Any]] = []
        func test(_ title: String,_ work: () throws -> Void) rethrows { try work(); results.append(["test":title,"status":"passed"]) }
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws { if !condition() { throw NSError(domain:"AITest",code:1,userInfo:[NSLocalizedDescriptionKey:message]) } }
        func mustFail(_ body: () throws -> Void) throws { do { try body() } catch { return }; throw NSError(domain:"AITest",code:2,userInfo:[NSLocalizedDescriptionKey:"Expected failure"]) }
        try test("missing paid API usage preserves conservative budget reservation") {
            let missing = AIEngine.accountedCost(usage:[:],inputPrice:2,outputPrice:3,reserved:0.42)
            let invalid = AIEngine.accountedCost(usage:["prompt_tokens":100,"completion_tokens":0],inputPrice:2,outputPrice:3,reserved:0.42)
            try expect(!missing.complete && missing.cost == 0.42,"Missing usage released budget")
            try expect(!invalid.complete && invalid.cost == 0.42,"Invalid usage released budget")
            let valid = AIEngine.accountedCost(usage:["prompt_tokens":1000,"completion_tokens":500],inputPrice:2,outputPrice:3,reserved:0.42)
            try expect(valid.complete && abs(valid.cost-0.0035)<0.0000001,"Valid usage not accounted")
        }
        try test("AI status returns metadata without requesting secret access") {
            let started=Date()
            let status=try ai.rpc(["action":"ai_status"])!
            try expect(status["key_access_deferred"] is Bool,"Missing deferred-access state")
            try expect(Date().timeIntervalSince(started)<10,"Status blocked on credential interaction")
            try expect((status["requests"] as? [[String:Any]] ?? []).isEmpty,"Status invoked paid AI")
        }
        let p = try store.rpc(["action":"project_save","title":"AI 隔离测试"])["project"] as! [String:Any], project = p["id"] as! String
        let path = base.appendingPathComponent("资料.md")
        try "# CCUS 研究\n碳封存需要评价储层孔隙度和渗透率。资料明确记录二氧化碳驱油实验。\n本文件仅用于隔离自动化测试。".write(to:path,atomically:true,encoding:.utf8)
        let imported = try store.importFile(path:path.path,name:nil,projectID:project,source:"manual",confirmed:true)
        let listed = try store.rpc(["action":"files","project_id":project])
        let file = (listed["items"] as! [[String:Any]]).first!["id"] as! String
        _ = imported
        try test("import does not create AI chunks or requests") {
            let n = try store.db.query("SELECT COUNT(*) AS n FROM ai_chunks")[0]["n"] as! Int
            let req = try store.db.query("SELECT COUNT(*) AS n FROM ai_requests")[0]["n"] as! Int
            try expect(n == 0 && req == 0,"Automatic AI activity detected")
        }
        try test("DeepSeek denies project before any network send") {
            try mustFail { _ = try ai.rpc(["action":"ai_prepare","file_ids":[file],"provider":"deepseek"]) }
            let count = try store.db.query("SELECT COUNT(*) AS n FROM ai_requests")[0]["n"] as! Int
            try expect(count == 0,"Unexpected request record")
        }
        try test("cloud authorization is project-scoped and revocable") {
            _ = try ai.rpc(["action":"ai_authorize","project_id":project,"allowed":true])
            let allowed = try store.db.query("SELECT deepseek_allowed FROM projects WHERE id=?",[project])[0]["deepseek_allowed"] as? Int
            try expect(allowed == 1,"Authorization not saved")
            _ = try ai.rpc(["action":"ai_authorize","project_id":project,"allowed":false])
            let revoked = try store.db.query("SELECT deepseek_allowed FROM projects WHERE id=?",[project])[0]["deepseek_allowed"] as? Int
            try expect(revoked == 0,"Revocation not saved")
        }
        var jobID = ""
        try test("manual local text indexing requires no model") {
            let result = try ai.rpc(["action":"ai_index","file_ids":[file],"embeddings":false])!
            jobID = result["job_id"] as! String
            var state: [String:Any] = [:]
            for _ in 0..<100 { state = try ai.rpc(["action":"ai_job","job_id":jobID])!; if ["completed","failed","cancelled"].contains(state["status"] as? String ?? "") { break }; Thread.sleep(forTimeInterval:0.03) }
            try expect(state["status"] as? String == "completed","Index job failed: \(state)")
            let count = try store.db.query("SELECT COUNT(*) AS n FROM ai_chunks")[0]["n"] as! Int
            try expect(count > 0,"No chunks")
        }
        try test("Chinese full-text search returns real file citation") {
            let result = try ai.rpc(["action":"ai_search","q":"二氧化碳驱油","semantic":false])!
            let items = result["items"] as! [[String:Any]]
            try expect(items.first?["file_id"] as? String == file,"Citation missing")
            try expect((items.first?["locator"] as? String ?? "").contains("字符"),"Missing truthful locator")
        }
        try test("natural Chinese question retrieves indexed evidence") {
            let result = try ai.rpc(["action":"ai_search","q":"请问资料中二氧化碳驱油实验有什么内容？","file_ids":[file],"semantic":false])!
            try expect(!(result["items"] as! [[String:Any]]).isEmpty,"Natural-language lexical retrieval failed")
        }
        try test("QA preview uses real indexed chunks without invoking a model") {
            _ = try store.rpc(["action":"settings_save","values":["ollama_model":"unit-test-not-a-real-model"]])
            let result = try ai.rpc(["action":"ai_prepare","file_ids":[file],"provider":"ollama","mode":"qa","prompt":"二氧化碳驱油实验研究什么？"] )!
            let citations = result["files"] as! [[String:Any]]
            try expect((result["excerpt"] as? String ?? "").contains("二氧化碳驱油"),"Retrieval context missing")
            try expect((citations.first?["locator"] as? String ?? "").contains("字符"),"Preview cites file prefix rather than indexed locator")
            let requests = try store.db.query("SELECT COUNT(*) AS n FROM ai_requests")[0]["n"] as! Int
            try expect(requests == 0,"Preview unexpectedly invoked model")
        }
        try test("stale file versions are excluded from index search") {
            try "全新版本内容，没有原实验结论。".write(to:path,atomically:true,encoding:.utf8)
            _ = try store.rpc(["action":"version_add","id":file,"path":path.path])
            let result = try ai.rpc(["action":"ai_search","q":"二氧化碳驱油"] )!
            try expect((result["items"] as! [[String:Any]]).isEmpty,"Stale citation exposed")
        }
        try test("manual index deletion removes chunks and FTS entries") {
            _ = try ai.rpc(["action":"ai_delete_index","file_ids":[file]])
            let chunks = try store.db.query("SELECT COUNT(*) AS n FROM ai_chunks")[0]["n"] as! Int
            let fts = try store.db.query("SELECT COUNT(*) AS n FROM ai_fts")[0]["n"] as! Int
            try expect(chunks == 0 && fts == 0,"Index delete incomplete")
        }
        try test("QA refuses missing index without automatic extraction") {
            try mustFail { _ = try ai.rpc(["action":"ai_prepare","file_ids":[file],"provider":"ollama","mode":"qa","prompt":"驱油资料说明了什么？"]) }
            let count = try store.db.query("SELECT COUNT(*) AS n FROM ai_chunks")[0]["n"] as! Int
            try expect(count == 0,"QA silently rebuilt index")
        }
        try test("invalid remote Ollama endpoint is blocked") {
            _ = try store.rpc(["action":"settings_save","values":["ollama_url":"https://example.com"]])
            try mustFail { _ = try ai.rpc(["action":"ai_prepare","file_ids":[file],"provider":"ollama"]) }
        }
        ai.stop()
        let data = try JSONSerialization.data(withJSONObject:["results":results,"live_ollama_tested":false,"live_deepseek_tested":false],options:[.prettyPrinted,.sortedKeys])
        print(String(data:data,encoding:.utf8)!)
    }
}
