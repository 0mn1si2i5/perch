import Foundation
import PerchCore

/// Explicit local import and metadata-only diagnostics for installation/acceptance.
enum ProviderDiagnostics {
    static func run(importLocal: Bool) throws {
        let store = AccountStore.standard()
        try store.load()
        let candidates = LocalProviderDiscovery.scan(home: store.home)
        if importLocal {
            let missing = candidates.filter { candidate in
                !store.accounts.contains { $0.app == candidate.app && $0.profilePath == candidate.profilePath }
            }
            if !missing.isEmpty {
                let backup = store.root.appendingPathComponent("accounts-before-providers-\(UUID().uuidString).json")
                try FileManager.default.copyItem(at: store.fileURL, to: backup)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
                for candidate in missing { try store.importLocal(candidate) }
                print("imported=\(missing.count) backup=\(backup.path)")
            } else { print("imported=0") }
        }
        print("discovered=\(candidates.count) accounts=\(store.accounts.count)")
        let processes = ProcessMatcher.snapshot() ?? []
        for account in store.accounts where account.localProvider != nil || account.apiProvider != nil {
            let sessions = LocalProviderSessions.recent(account)
            let running = LocalProviderLauncher.isRunning(account, processes: processes)
            let valid = Result { try account.localProvider?.validate(); try account.apiProvider?.validate() }
            let configured: Bool
            if case .success = valid { configured = true } else { configured = false }
            print("provider=\(account.app.rawValue) configuration=\(configured) sessions=\(sessions.count) localRunning=\(running)")
        }
    }
}
