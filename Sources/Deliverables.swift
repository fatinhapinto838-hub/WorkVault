import Foundation

// Filtering happens before counts/pagination. A pinned delivery may retain a
// Markdown name even after its shared file record has been renamed to .txt.
let nonMarkdownFileSearchSQL="lower(f.ext) NOT IN ('md','markdown')"
let nonMarkdownDeliverySearchSQL=nonMarkdownFileSearchSQL+" AND lower(d.display_name) NOT LIKE '%.md' AND lower(d.display_name) NOT LIKE '%.markdown'"

extension Store {
    // A delivery pins an immutable version in a particular project. It never copies
    // a blob or silently follows a later working version of the same file.
    func refreshFinalMarkers(fileID:String) throws {
        try db.exec("UPDATE files SET final=EXISTS(SELECT 1 FROM project_deliverables WHERE file_id=files.id) WHERE id=?",[fileID])
        try db.exec("UPDATE versions SET is_final=EXISTS(SELECT 1 FROM project_deliverables d WHERE d.version_id=versions.id AND d.file_id=versions.file_id) WHERE file_id=?",[fileID])
    }

    func deliverableRows(projectID:String?=nil,fileID:String?=nil,q:String="",limit:Int=500,offset:Int=0) throws -> [[String:Any]] {
        var conditions=["f.status='managed'"]; var args:[Any?]=[]
        if let id=projectID { conditions.append("d.project_id=?"); args.append(id) }
        if let id=fileID { conditions.append("d.file_id=?"); args.append(id) }
        if !q.isEmpty { conditions.append(nonMarkdownDeliverySearchSQL);conditions.append("(instr(lower(d.display_name),lower(?))>0 OR instr(lower(f.name),lower(?))>0 OR instr(lower(p.title),lower(?))>0)"); args += [q,q,q] }
        let rows=try db.query("SELECT d.*,coalesce(d.delivered_at,d.selected_at) effective_at,p.title project_title,v.hash version_hash,v.size version_size,v.created_at version_created_at,CASE WHEN f.current_version=d.version_id THEN 1 ELSE 0 END version_is_current FROM project_deliverables d JOIN projects p ON p.id=d.project_id JOIN files f ON f.id=d.file_id JOIN versions v ON v.id=d.version_id AND v.file_id=d.file_id WHERE \(conditions.joined(separator:" AND ")) ORDER BY coalesce(d.delivered_at,d.selected_at) DESC,d.selected_at DESC,d.file_id,d.version_id LIMIT ? OFFSET ?",args+[max(1,min(500,limit)),max(0,offset)])
        return try rows.map { row in
            var result=try file(row["file_id"] as! String)
            result.merge(row){_,new in new}
            result["final"]=1
            return result
        }
    }

    private func latestDelivery(_ projectID:String,q:String="") throws -> [String:Any] {
        let filter=q.isEmpty ? "" : " AND \(nonMarkdownDeliverySearchSQL) AND (instr(lower(d.display_name),lower(?))>0 OR instr(lower(f.name),lower(?))>0 OR instr(lower(p.title),lower(?))>0)"
        return try db.query("SELECT coalesce(d.delivered_at,d.selected_at) latest_at,CASE WHEN d.delivered_at IS NULL THEN 'collection' ELSE d.time_source END latest_time_source FROM project_deliverables d JOIN files f ON f.id=d.file_id JOIN projects p ON p.id=d.project_id WHERE d.project_id=? AND f.status='managed'"+filter+" ORDER BY coalesce(d.delivered_at,d.selected_at) DESC,d.selected_at DESC,d.file_id,d.version_id LIMIT 1",[projectID]+(q.isEmpty ? [] : [q,q,q])).first ?? [:]
    }

    func listDeliverables(_ p:[String:Any]) throws -> [String:Any] {
        let q=String((p["q"] as? String ?? "").trimmingCharacters(in:.whitespacesAndNewlines).prefix(1000))
        let projectID=(p["project_id"] as? String).flatMap{$0.isEmpty ? nil : $0}
        let limit=max(1,min(projectID == nil ? 50 : 200,p["limit"] as? Int ?? (projectID == nil ? 12 : 40)))
        let offset=max(0,p["offset"] as? Int ?? 0)
        let match="(instr(lower(d.display_name),lower(?))>0 OR instr(lower(f.name),lower(?))>0 OR instr(lower(p.title),lower(?))>0)"
        let eligible=q.isEmpty ? "" : " AND \(nonMarkdownDeliverySearchSQL)"
        let countSQL="SELECT count(*) n FROM project_deliverables d JOIN files f ON f.id=d.file_id JOIN projects p ON p.id=d.project_id WHERE f.status='managed'"+eligible
        let countArgs:[Any?]=q.isEmpty ? [] : [q,q,q]
        let total=try db.query(countSQL+(projectID == nil ? "" : " AND d.project_id=?")+(q.isEmpty ? "" : " AND \(match)"),(projectID == nil ? [] : [projectID])+countArgs).first?["n"] as? Int ?? 0
        if let id=projectID {
            let project=try self.project(id)
            var group:[String:Any]=["project":project,"items":try deliverableRows(projectID:id,q:q,limit:limit,offset:offset),"total":total]
            group.merge(try latestDelivery(id,q:q)){_,new in new}
            return ["groups":[group],"total_projects":1,"total":total,"limit":limit,"offset":offset,"search_excludes_markdown":!q.isEmpty]
        }
        // Page projects independently of their file counts, so a large project
        // cannot hide smaller projects. Empty projects remain easy to discover.
        let filter=q.isEmpty ? "" : " WHERE instr(lower(p.title),lower(?))>0 OR EXISTS(SELECT 1 FROM project_deliverables d JOIN files f ON f.id=d.file_id WHERE d.project_id=p.id AND f.status='managed'\(eligible) AND (instr(lower(d.display_name),lower(?))>0 OR instr(lower(f.name),lower(?))>0))"
        let projectArgs:[Any?]=q.isEmpty ? [] : [q,q,q]
        let totalProjects=try db.query("SELECT count(*) n FROM projects p"+filter,projectArgs).first?["n"] as? Int ?? 0
        let dateFilter=q.isEmpty ? "" : eligible+" AND \(match)"
        let projects=try db.query("SELECT p.id FROM projects p"+filter+" ORDER BY (SELECT max(coalesce(d.delivered_at,d.selected_at)) FROM project_deliverables d JOIN files f ON f.id=d.file_id WHERE d.project_id=p.id AND f.status='managed'\(dateFilter)) DESC,p.updated_at DESC,p.id LIMIT ? OFFSET ?",projectArgs+countArgs+[limit,offset])
        let groups=try projects.map { row -> [String:Any] in
            let id=row["id"] as! String
            let count=try db.query(countSQL+" AND d.project_id=?"+(q.isEmpty ? "" : " AND \(match)"),[id]+countArgs).first?["n"] as? Int ?? 0
            var group:[String:Any]=["project":try self.project(id),"items":try deliverableRows(projectID:id,q:q,limit:4),"total":count]
            group.merge(try latestDelivery(id,q:q)){_,new in new};return group
        }
        return ["groups":groups,"total_projects":totalProjects,"total":total,"limit":limit,"offset":offset,"search_excludes_markdown":!q.isEmpty]
    }

    func selectDeliverables(_ p:[String:Any],evidenceSource:String="user",displayNames:[String:String]=[:],sourcePaths:[String:String]=[:],deliveredAt:String?=nil,timeSource:String="task_delivery") throws -> [String:Any] {
        guard let projectID=p["project_id"] as? String,!projectID.isEmpty else { throw fail("请选择成果所属项目") }
        _ = try project(projectID)
        guard let ids=p["file_ids"] as? [String],!ids.isEmpty,ids.count<=1000 else { throw fail("请选择 1–1000 个项目文件") }
        let version=p["version_id"] as? String
        guard version == nil || ids.count == 1 else { throw fail("指定版本时请选择单个文件") }
        let note=String((p["evidence_note"] as? String ?? "用户手动选择的最终成果").prefix(4000))
        if let value=deliveredAt { guard ISO8601DateFormatter().date(from:value) != nil,["task_delivery","local_release"].contains(timeSource) else { throw fail("交付时间格式或来源无效") } }
        return try db.transaction {
            for id in Set(ids) {
                let f=try file(id)
                guard f["status"] as? String == "managed",!(try db.query("SELECT 1 FROM file_projects WHERE file_id=? AND project_id=?",[id,projectID])).isEmpty else { throw fail("最终成果必须是该项目中已确认归档的文件") }
                let versionID=version ?? f["current_version"] as? String ?? ""
                guard !(try db.query("SELECT 1 FROM versions WHERE id=? AND file_id=?",[versionID,id])).isEmpty else { throw fail("所选版本不属于该文件") }
                let name=displayNames[id] ?? f["name"] as? String ?? "未命名文件"
                guard name.count<=1000,!name.contains("\0"),!name.contains("/") else { throw fail("成果显示名称无效") }
                // Reselecting the same version may update a note, but must not
                // discard a previously verified delivery date. New versions do
                // not inherit the old version's date or another project's date.
                let prior=try db.query("SELECT delivered_at,time_source FROM project_deliverables WHERE project_id=? AND file_id=? AND version_id=?",[projectID,id,versionID]).first
                let delivery=deliveredAt ?? prior?["delivered_at"] as? String
                let origin=deliveredAt != nil ? timeSource : (delivery != nil ? prior?["time_source"] as? String ?? "task_delivery" : "collection")
                // Deliberate selection replaces only this project's selection.
                // Selections belonging to another project are independent.
                try db.exec("DELETE FROM project_deliverables WHERE project_id=? AND file_id=?",[projectID,id])
                try db.exec("INSERT INTO project_deliverables(project_id,file_id,version_id,display_name,evidence_source,evidence_note,source_path,selected_at,delivered_at,time_source) VALUES(?,?,?,?,?,?,?,?,?,?)",[projectID,id,versionID,name,evidenceSource,note,sourcePaths[id],now(),delivery,origin])
                try refreshFinalMarkers(fileID:id)
                try event("deliverable","收录最终成果：\(name) · 固定版本 \(versionID)",project:projectID,file:id)
            }
            return ["added":Set(ids).count]
        }
    }

    func removeDeliverable(_ p:[String:Any]) throws -> [String:Any] {
        guard let projectID=p["project_id"] as? String,let fileID=p["file_id"] as? String else { throw fail("请选择项目和文件") }
        _ = try project(projectID); _ = try file(fileID)
        return try db.transaction {
            let versionID=p["version_id"] as? String
            try db.exec("DELETE FROM project_deliverables WHERE project_id=? AND file_id=?"+(versionID == nil ? "" : " AND version_id=?"),versionID == nil ? [projectID,fileID] : [projectID,fileID,versionID])
            try refreshFinalMarkers(fileID:fileID)
            try event("deliverable_remove","从最终成果栏目移出；文件与历史版本保留",project:projectID,file:fileID)
            return ["ok":true]
        }
    }
}
