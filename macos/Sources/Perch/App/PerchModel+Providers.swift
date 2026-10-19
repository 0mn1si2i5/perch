import AppKit
import PerchCore

extension PerchModel {
    func scanLocalProviders() {
        let found = LocalProviderDiscovery.scan(home: store.home)
        localCandidates = found.filter { candidate in
            !accounts.contains { $0.app == candidate.app && $0.profilePath == candidate.profilePath }
        }
        localLaunchUpdates = accounts.compactMap { account in
            found.lazy.compactMap { LocalProviderDiscovery.launchUpdate(for: account, candidate: $0) }.first
        }
    }

    @discardableResult
    func updateLocalLaunch(_ update: LocalLaunchUpdate) -> Bool {
        do {
            try store.updateLocalLaunch(id: update.account.id, configuration: update.configuration)
            accounts = store.accounts
            scanLocalProviders()
            message = "已更新 \(update.account.name) 的启动位置"
            return true
        } catch { message = "更新启动位置失败：\(error.localizedDescription)"; return false }
    }

    @discardableResult
    func importLocal(_ candidate: LocalProviderCandidate) -> Bool {
        do {
            let account = try store.importLocal(candidate)
            accounts = store.accounts
            scanLocalProviders()
            poll()
            refreshQuota(account, manual: false)
            return true
        } catch { message = error.localizedDescription; return false }
    }

    func localWebURL(_ account: Account) -> URL? {
        guard account.app == .deepseek, let args = account.localProvider?.arguments,
              let hostIndex = args.firstIndex(of: "--host"), args.indices.contains(hostIndex + 1),
              args[hostIndex + 1] == "127.0.0.1" else { return nil }
        var port = 3080
        if let index = args.firstIndex(of: "--port") {
            guard args.indices.contains(index + 1), let value = Int(args[index + 1]), (1...65535).contains(value) else { return nil }
            port = value
        }
        return URL(string: "http://127.0.0.1:\(port)")
    }

    func openLocalWeb(_ account: Account) {
        guard let url = localWebURL(account) else { return }
        NSWorkspace.shared.open(url)
    }
}

extension PerchModel {
    func supportsProviderUsage(_ account: Account) -> Bool {
        [.geminiApp, .antigravity, .deepseek].contains(account.app) && account.localProvider != nil
    }

    func refreshProviderUsage(_ account: Account) {
        refreshingQuotas.insert(account.id)
        Task { @MainActor [weak self] in
            let result: Result<ProviderUsage, Error>
            do {
                switch account.app {
                case .deepseek: result = .success(try await DeepSeekUsage.query(account))
                case .geminiApp: result = .success(try await NativeGeminiUsage.query(account))
                case .antigravity: result = .success(try await AntigravityCLIUsage.query(account))
                default: return
                }
            } catch { result = .failure(error) }
            guard let self else { return }
            self.refreshingQuotas.remove(account.id)
            guard self.accounts.contains(where: {
                $0.id == account.id && $0.app == account.app && $0.profilePath == account.profilePath &&
                $0.sessionRoot == account.sessionRoot && $0.localProvider == account.localProvider
            }) else { return }
            switch result {
            case .success(let usage):
                self.providerUsage[account.id] = usage
                self.providerUsageErrors[account.id] = nil
            case .failure(let error):
                // Retain a timestamped last success during outages; never replace it with zero.
                self.providerUsageErrors[account.id] = error.localizedDescription
                if case ProviderUsageError.signedOut = error { self.providerUsage[account.id] = nil }
            }
        }
    }
}
