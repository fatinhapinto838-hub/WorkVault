import Foundation
import Darwin

/// Synthetic metadata only. Never opens or modifies a user's file library.
@main
struct Benchmark {
    static func main() throws {
        let fm = FileManager.default
        let base = URL(fileURLWithPath:fm.currentDirectoryPath).appendingPathComponent("work/benchmark-"+UUID().uuidString)
        try fm.createDirectory(at:base,withIntermediateDirectories:true)
        defer { try? fm.removeItem(at:base) }
        var datasets: [[String:Any]] = []
        func milliseconds(_ body: () throws -> Void) rethrows -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            try body()
            return Double(DispatchTime.now().uptimeNanoseconds-start)/1_000_000
        }
        for count in [1000,5000,10000] {
            let store = try Store(root:base.appendingPathComponent("vault-\(count)"))
            var projects: [String] = []
            for i in 0..<50 {
                let value = try store.rpc(["action":"project_save","title":String(format:"基准项目_%02d_石油工程",i),"source_confirmed":true])
                projects.append((value["project"] as! [String:Any])["id"] as! String)
            }
            let source = base.appendingPathComponent("seed-\(count).txt")
            try "Synthetic benchmark fixture. No user content.\n".write(to:source,atomically:true,encoding:.utf8)
            _ = try store.importFile(path:source.path,name:"基准种子.txt",projectID:projects[0],source:"manual",confirmed:true)
            let seed = (try store.rpc(["action":"files","limit":1])["items"] as! [[String:Any]])[0]
            let hash = seed["hash"] as! String, size = seed["size"] as! Int, date = now()
            let seedMS = try milliseconds {
                try store.db.transaction {
                    for i in 1..<count {
                        let id = "benchmark-file-\(i)", version = "benchmark-version-\(i)", tagged = i%5 == 0
                        let name = String(format:"%@成果_%07d.txt",tagged ? "CCUS_":"石油工程_",i)
                        let tags = tagged ? "[\"CCUS\",\"benchmark\"]":"[\"石油工程\",\"benchmark\"]"
                        try store.db.exec("INSERT INTO files(id,name,ext,status,favorite,final,tags,current_version,created_at,updated_at) VALUES(?,?,'txt','managed',?,?,?,NULL,?,?)",[id,name,i%7 == 0 ? 1:0,i%11 == 0 ? 1:0,tags,date,date])
                        try store.db.exec("INSERT INTO versions(id,file_id,hash,size,created_at,source,note,is_final) VALUES(?,?,?,?,?,'benchmark','合成元数据基准测试',0)",[version,id,hash,size,date])
                        try store.db.exec("UPDATE files SET current_version=? WHERE id=?",[version,id])
                        try store.db.exec("INSERT INTO file_projects(file_id,project_id) VALUES(?,?)",[id,projects[i%50]])
                        try store.db.exec("INSERT INTO metadata_fts(file_id,name,tags) VALUES(?,?,?)",[id,name,tagged ? "CCUS benchmark":"石油工程 benchmark"])
                        try store.db.exec("INSERT INTO provenance(id,file_id,source,source_path,original_name,confidence,imported_at,status) VALUES(?,?,'benchmark',NULL,?,'synthetic',?,'managed')",["benchmark-origin-\(i)",id,name,date])
                    }
                }
            }
            let integrity = try store.rpc(["action":"integrity"])
            guard (integrity["errors"] as? [String] ?? []).isEmpty else { throw fail("基准库完整性失败") }
            let counted = try store.rpc(["action":"files","limit":1])["total"] as! Int
            guard counted == count else { throw fail("基准库数量不符") }
            let cases: [(String,[String:Any])] = [
                ("page_first_50",["action":"files","limit":50]),
                ("page_last_50",["action":"files","limit":50,"offset":count-50]),
                ("sort_name_50",["action":"files","limit":50,"sort":"name"]),
                ("filter_project_50",["action":"files","limit":50,"project_id":projects[17]]),
                ("filter_tag_50",["action":"files","limit":50,"tag":"CCUS"]),
                ("filter_combined_50",["action":"files","limit":50,"project_id":projects[20],"tag":"CCUS","ext":"txt","favorite":true]),
                ("search_filename",["action":"files","limit":50,"q":"成果_0000099"]),
                ("search_project_title",["action":"files","limit":50,"q":"基准项目_17"]),
                ("search_tag_text",["action":"files","limit":50,"q":"CCUS"]),
                ("dashboard_status",["action":"status"])
            ]
            var measurements: [[String:Any]] = []
            for (name,params) in cases {
                _ = try store.rpc(params) // warm up database caches, exclude from measured samples
                var samples: [Double] = [], last: [String:Any] = [:]
                for _ in 0..<31 { let ms = try milliseconds { last = try store.rpc(params) }; samples.append(ms) }
                let sorted = samples.sorted(), p95 = sorted[Int(ceil(Double(sorted.count)*0.95))-1]
                measurements.append(["operation":name,"samples":31,"median_ms":sorted[sorted.count/2],"p95_ms":p95,"min_ms":sorted.first!,"max_ms":sorted.last!,"returned_rows":(last["items"] as? [Any])?.count ?? (last["recent_files"] as? [Any])?.count ?? 0,"matching_total":last["total"] ?? last["files"] ?? 0,"raw_ms":samples])
            }
            var usage = rusage(); getrusage(RUSAGE_SELF,&usage)
            let dbBytes = (try fm.attributesOfItem(atPath:store.root.appendingPathComponent("workvault.sqlite").path)[.size] as? NSNumber)?.int64Value ?? 0
            let walURL = store.root.appendingPathComponent("workvault.sqlite-wal")
            let walBytes = ((try? fm.attributesOfItem(atPath:walURL.path)[.size]) as? NSNumber)?.int64Value ?? 0
            datasets.append(["metadata_files":count,"projects":50,"distinct_blobs":1,"blob_bytes":size,"seed_ms":seedMS,"database_bytes":dbBytes,"wal_bytes":walBytes,"cumulative_process_peak_rss_bytes":usage.ru_maxrss,"measurements":measurements])
        }
        let report: [String:Any] = ["date":now(),"platform":ProcessInfo.processInfo.operatingSystemVersionString,"architecture":"arm64","compiler":"Apple Swift 6.1.2, -O","measurement":"In-process Store.rpc including row hydration; excludes HTTP, JavaScript rendering, file import throughput and model inference","synthetic":true,"datasets":datasets]
        print(String(data:try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]),encoding:.utf8)!)
    }
}
