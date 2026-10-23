import Foundation
public enum MootLegacyRunReader {
    /// Only the user-selected runs root is read. Missing legacy fields remain unknown.
    public static func read(root: URL) throws -> [MootRunSnapshot] {
        let fm = FileManager.default
        return try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]).compactMap { dir in
            let modern = dir.appendingPathComponent("run.json"), legacy = dir.appendingPathComponent("meeting.json")
            let file = fm.fileExists(atPath: modern.path) ? modern : legacy
            guard let data = try? Data(contentsOf: file), var json = try? JSONDecoder().decode(MootJSON.self, from: data) else { return nil }
            if json["format"].text == "perch-moot", !json["task"]["parentID"].text.isEmpty { return nil }
            if json["format"].text != "perch-moot" {
                guard json["version"].integer > 0, !json["id"].text.isEmpty else { return nil }
                json = .object(["id": json["id"], "brief": json["title"], "state": .string("legacy"), "createdAt": json["startedAt"], "output": .string("旧格式原始记录（未提供的轮次、角色和验收状态保持未知）\n" + json.pretty), "rounds": .array([]), "events": .array([]), "artifacts": .array([]), "issues": .array([])])
            }
            if case .object(var fields) = json { fields["readOnlyHistory"] = .bool(true); fields["sourceDirectory"] = .string(dir.path); json = .object(fields) }
            return MootRunSnapshot(record: json)
        }.sorted { $0.record["createdAt"].text > $1.record["createdAt"].text }
    }
}
