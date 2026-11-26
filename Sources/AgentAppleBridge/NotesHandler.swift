import Foundation

final class NotesHandler {
    private let osascript = "/usr/bin/osascript"

    func handle(mode: String, params: [String: Any]) throws -> Any {
        let action = (params["action"] as? String ?? "").lowercased()
        let readActions = ["accounts", "folders", "list", "search", "get", "capabilities"]
        let writeActions = ["create", "update", "move", "delete", "capabilities"]
        guard (mode == "read" ? readActions : writeActions).contains(action) else {
            throw BridgeError("unsupported_action", "unsupported Notes \(mode) action")
        }
        if action == "capabilities" {
            return [
                "read": Array(readActions.dropLast()),
                "write": Array(writeActions.dropLast()),
                "fullBody": true,
                "attachments": "metadata",
                "passwordProtectedNotes": "locked",
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: params)
        guard data.count <= 8 * 1024 * 1024 else {
            throw BridgeError("request_too_large", "Notes request exceeded 8 MiB")
        }
        let requestFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-bridge-notes-\(UUID().uuidString).json")
        guard FileManager.default.createFile(atPath: requestFile.path, contents: data,
                                            attributes: [.posixPermissions: 0o600]) else {
            throw BridgeError("request_file_failed", "could not create private Notes request file")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: requestFile.path)
        defer { try? FileManager.default.removeItem(at: requestFile) }
        return try ProcessRunner.json(
            osascript,
            ["-l", "JavaScript", "-e", Self.script, "--", requestFile.path],
            timeout: 90
        )
    }

    static let script = #"""
ObjC.import("Foundation");
function unwrap(v) { try { return ObjC.unwrap(v); } catch (_) { return v; } }
function iso(v) { try { return new Date(v).toISOString(); } catch (_) { return null; } }
function noteRow(n, includeBody) {
  var row = {
    id: String(n.id()),
    name: String(n.name()),
    creationDate: iso(n.creationDate()),
    modificationDate: iso(n.modificationDate()),
    passwordProtected: Boolean(n.passwordProtected()),
    shared: Boolean(n.shared()),
    container: String(n.container().name())
  };
  if (includeBody) {
    try { row.body = String(n.body()); } catch (_) { row.body = null; row.locked = true; }
    try { row.plaintext = String(n.plaintext()); } catch (_) { row.plaintext = null; }
  }
  try { row.attachments = n.attachments().map(function(a) { return {name: String(a.name()), id: String(a.id())}; }); }
  catch (_) { row.attachments = []; }
  return row;
}
function locateAccount(app, target) {
  var accounts = app.accounts();
  if (target && target.accountId) return accounts.filter(function(a) { return String(a.id()) === String(target.accountId); })[0];
  if (target && target.account) return accounts.filter(function(a) { return String(a.name()) === String(target.account); })[0];
  return accounts[0];
}
function locateFolder(app, target) {
  var account = locateAccount(app, target || {});
  if (!account) throw new Error("Notes account not found");
  var folders = account.folders();
  if (target && target.folderId) return folders.filter(function(f) { return String(f.id()) === String(target.folderId); })[0];
  if (target && target.folder) return folders.filter(function(f) { return String(f.name()) === String(target.folder); })[0];
  return folders[0];
}
function allNotes(app) {
  var out = [];
  app.accounts().forEach(function(a) { a.folders().forEach(function(f) { out = out.concat(f.notes()); }); });
  return out;
}
function findNote(app, id) {
  return allNotes(app).filter(function(n) { return String(n.id()) === String(id); })[0];
}
function run(argv) {
  var raw = $.NSString.stringWithContentsOfFileEncodingError(
    argv[0], $.NSUTF8StringEncoding, null
  ).js;
  var p = JSON.parse(raw), app = Application("Notes"), action = String(p.action || "").toLowerCase();
  app.includeStandardAdditions = true;
  if (action === "accounts") return {items: app.accounts().map(function(a) { return {id:String(a.id()), name:String(a.name())}; }), nextCursor:null};
  if (action === "folders") {
    var rows = [];
    app.accounts().forEach(function(a) { a.folders().forEach(function(f) { rows.push({id:String(f.id()), name:String(f.name()), account:{id:String(a.id()),name:String(a.name())}}); }); });
    return {items:rows, nextCursor:null};
  }
  if (action === "list" || action === "search" || action === "get") {
    var query = String(p.query || "").toLowerCase(), rows = allNotes(app);
    if (p.id) rows = rows.filter(function(n) { return String(n.id()) === String(p.id); });
    if (query) rows = rows.filter(function(n) { return String(n.name()).toLowerCase().indexOf(query) >= 0 || String(n.plaintext()).toLowerCase().indexOf(query) >= 0; });
    var offset = Math.max(parseInt(p.cursor || "0", 10) || 0, 0), limit = Math.min(Math.max(parseInt(p.limit || 50,10),1),200);
    var page = rows.slice(offset, offset + limit).map(function(n) { return noteRow(n, p.includeBody !== false); });
    return {items:page, nextCursor: offset + page.length < rows.length ? String(offset + page.length) : null, total:rows.length};
  }
  if (action === "create") {
    var content = p.content || {}, folder = locateFolder(app, p.target || {});
    if (!content.name && !content.title) throw new Error("note name is required");
    if (p.dryRun) return {dryRun:true, preview:{action:"create", name:String(content.name || content.title)}};
    var created = app.Note({name:String(content.name || content.title), body:String(content.body || "")});
    folder.notes.push(created);
    return {item:noteRow(created, true)};
  }
  var note = findNote(app, p.id);
  if (!note) throw new Error("note not found");
  if (p.dryRun) return {dryRun:true, preview:{action:action, id:String(note.id()), name:String(note.name())}};
  if (action === "update") {
    var patch = p.patch || {};
    if (patch.name !== undefined || patch.title !== undefined) note.name = String(patch.name || patch.title);
    if (patch.body !== undefined) note.body = String(patch.body);
    return {item:noteRow(note, true)};
  }
  if (action === "move") {
    var destination = locateFolder(app, p.target || {});
    app.move(note, {to:destination});
    return {item:noteRow(note, true)};
  }
  if (action === "delete") { app.delete(note); return {deleted:true, id:String(p.id)}; }
  throw new Error("unsupported Notes action");
}
"""#
}
