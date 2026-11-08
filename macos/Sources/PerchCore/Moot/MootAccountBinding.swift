import Foundation
public struct MootBindingCandidate: Identifiable {
    public var id: String { connection.id }
    public var connection: MootConnection
    public var note: String
}
public enum MootAccountBinding {
    /// Accounts the「添加接入」menu offers, leaving out those a connection in `existing` is already bound to.
    public static func candidates(accounts: [Account], existing: [MootConnection]) -> [MootBindingCandidate] {
        let bound = Set(existing.compactMap(\.perchAccountID))
        return accounts.compactMap { account in
            guard !bound.contains(account.id) else { return nil }
            // Perch estimates a Claude Code CLI directory's spend against Console organization credit, so it becomes a
            // console connection; a subscription login there fails the connection check. Scanned accounts are already
            // named「Claude Code · <directory>」.
            if account.app == .claudeCode {
                guard let executable = account.localProvider?.target else { return nil }
                var c = MootConnection(); c.name = account.name
                c.perchAccountID = account.id; c.adapter = "claude"; c.authMode = "console"; c.executable = executable
                c.accountRoot = account.profilePath; c.defaultModel = ""
                return MootBindingCandidate(connection: c, note: "需实际调用验证")
            }
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
