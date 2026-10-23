import Foundation
public struct MootBindingCandidate: Identifiable {
    public var id: String { connection.id }
    public var connection: MootConnection
    public var note: String
}
public enum MootAccountBinding {
    public static func candidates(accounts: [Account]) -> [MootBindingCandidate] {
        accounts.compactMap { account in
            guard account.app == .codex || account.app == .antigravity else { return nil }
            let adapter = account.app == .codex ? "codex" : "agy"
            guard let executable = LocalProviderDiscovery.executable(adapter) else { return nil }
            var c = MootConnection(); c.name = account.name + " · " + account.app.displayName
            c.perchAccountID = account.id; c.adapter = adapter; c.executable = executable
            c.accountRoot = account.app == .codex ? account.sessionRoot : account.profilePath
            c.defaultModel = ""
            if adapter == "agy" { c.tools = ["image"] }
            return MootBindingCandidate(connection: c, note: "需实际调用验证")
        }
    }
}
