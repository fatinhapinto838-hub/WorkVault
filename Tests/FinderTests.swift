import Foundation

@main struct FinderTests {
 static func main() throws {
  let base=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("work/finder-tests-\(uuid())")
  try FileManager.default.createDirectory(at:base,withIntermediateDirectories:true)
  defer { try? FileManager.default.removeItem(at:base) }
  let store=try Store(root:base.appendingPathComponent("library")),source=base.appendingPathComponent("original.md"),updated=base.appendingPathComponent("updated.md")
  try Data("original pinned bytes\n".utf8).write(to:source);try Data("later current bytes\n".utf8).write(to:updated)
  let p=try store.rpc(["action":"project_save","title":"Finder isolated test"])["project"] as! [String:Any],pid=p["id"] as! String
  let f=try store.importFile(path:source.path,projectID:pid,confirmed:true)["file"] as! [String:Any],id=f["id"] as! String,old=f["current_version"] as! String
  _=try store.rpc(["action":"deliverable_set","project_id":pid,"file_ids":[id]])
  _=try store.rpc(["action":"version_add","id":id,"path":updated.path])
  var checks:[[String:Any]]=[]
  func expect(_ name:String,_ condition:@autoclosure ()throws->Bool)throws { guard try condition() else { throw fail(name) };checks.append(["name":name,"passed":true]) }
  let copy=try store.readOnlyVersionCopy(fileID:id,versionID:old,name:"Delivered report.md")
  try expect("Finder target uses pinned historical bytes, not later working version",try Data(contentsOf:copy)==Data(contentsOf:source))
  try expect("Finder target has the delivered filename and stays under previews",copy.lastPathComponent=="Delivered report.md" && copy.path.hasPrefix(store.root.path+"/previews/"))
  let mode=(try FileManager.default.attributesOfItem(atPath:copy.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0
  try expect("Finder target is read only",mode & 0o222 == 0)
  let again=try store.readOnlyVersionCopy(fileID:id,versionID:old,name:"Delivered report.md")
  try expect("Repeated reveal reuses the same named version copy",again==copy)
  try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:copy.path);try Data("changed cache".utf8).write(to:copy)
  _=try store.readOnlyVersionCopy(fileID:id,versionID:old,name:"Delivered report.md")
  try expect("A changed preview cache is repaired from the immutable archive",try Store.hashFile(copy)==Store.hashFile(source))
  let foreignPath=base.appendingPathComponent("foreign.txt");try Data("foreign file".utf8).write(to:foreignPath)
  let foreign=try store.importFile(path:foreignPath.path,confirmed:true)["file"] as! [String:Any]
  var rejected=false
  do { _=try store.readOnlyVersionCopy(fileID:id,versionID:foreign["current_version"] as! String) } catch { rejected=true }
  try expect("Foreign versions cannot be revealed for another file",rejected)
  let linked=copy.deletingLastPathComponent().appendingPathComponent("linked.md")
  try FileManager.default.createSymbolicLink(at:linked,withDestinationURL:source)
  rejected=false;do { _=try store.readOnlyVersionCopy(fileID:id,versionID:old,name:"linked.md") } catch { rejected=true }
  try expect("A symlink cannot redirect the preview destination",rejected)
  let final=try store.rpc(["action":"file_detail","id":id])
  try expect("File versions and original source stay intact",(final["versions"] as! [[String:Any]]).count==2 && (try Data(contentsOf:source))==Data("original pinned bytes\n".utf8))
  print(jsonString(["passed":checks.count,"checks":checks,"native_finder_ui_tested":false,"note":"Pure target preparation test; native Finder opening is separately verified through the installed app."]))
 }
}
