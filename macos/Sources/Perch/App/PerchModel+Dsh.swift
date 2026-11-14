import AppKit
import PerchCore

extension PerchModel {
    func checkedDshConfiguration(_ configuration: DshConfiguration, home: String) throws -> DshConfiguration {
        guard configuration.mode != .external else { return configuration }
        let data = home.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? store.root.path
            : try DshInstallation.normalize(home, home: store.home)
        let probe = Account(id: "configuration-check", name: "dsh", app: .deepseek,
                            profilePath: data, sessionRoot: data, createdAt: Date(), lastLaunchedAt: nil,
                            dshWeb: configuration)
        let launch = try DshInstallation.resolve(account: probe)
        var result = configuration
        // Source builds contain an npm CLI package. Keep the source root, never reclassify its entry as npm.
        result.installationPath = launch.workingDirectory
        result.nodePath = launch.node
        result.profile = launch.profile
        return result
    }

    func isCurrentDsh(_ account: Account) -> Bool {
        accounts.contains { $0.id == account.id && $0.app == .deepseek && $0.profilePath == account.profilePath && $0.dshWeb == account.dshWeb }
    }

    func scanDshInstallations() {
        guard !dshScanning else { return }
        dshScanning = true
        let home = store.home
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = DshInstallation.discover(home: home)
            DispatchQueue.main.async { self?.dshInstallations = found; self?.dshScanning = false }
        }
    }

    /// Saving a Web capability never changes a native launch configuration or starts an existing service.
    @MainActor
    func saveDsh(name: String, home: String, configuration: DshConfiguration, accountID: String?) async throws -> Account {
        let requestedHome = home.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && configuration.mode == .external
            ? configuration.balanceHome : home
        let normalized = requestedHome.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil
            : try DshInstallation.normalize(requestedHome, home: store.home)
        let existing = accounts.first {
            if let accountID { return $0.id == accountID }
            guard $0.app == .deepseek, let normalized else { return false }
            return (try? DshInstallation.normalize($0.profilePath, home: store.home)) == normalized
        }
        if let existing, let previous = existing.dshWeb,
           previous.mode != configuration.mode || previous.installationPath != configuration.installationPath
            || previous.nodePath != configuration.nodePath || previous.profile != configuration.profile {
            if await dshService.isManagedRunning(account: existing) {
                throw DshError.invalid("请先在账号菜单停止受管服务，再修改连接方式、安装、Node 或 Web profile。")
            }
        }
        let account = try store.configureDsh(name: name, home: home, configuration: configuration, accountID: accountID)
        accounts = store.accounts
        resetDshState(account.id)
        scanLocalProviders()
        return account
    }

    func pollDsh() {
        for account in accounts where account.dshWeb != nil && !dshReading.contains(account.id) && !dshBusy.contains(account.id) {
            dshReading.insert(account.id)
            let epoch = dshEpochs[account.id, default: 0]
            Task { @MainActor [weak self] in
                guard let self else { return }
                let snapshot = await self.dshService.read(account: account)
                self.dshReading.remove(account.id)
                guard self.dshEpochs[account.id, default: 0] == epoch else { return }
                self.applyDsh(snapshot, for: account)
            }
        }
    }

    func launchDsh(_ account: Account, then: ((LaunchOutcome) -> Void)? = nil) {
        guard !dshBusy.contains(account.id) else { then?(.failed("dsh 正在连接，请稍后重试")); return }
        dshBusy.insert(account.id)
        dshEpochs[account.id, default: 0] += 1
        dshErrors[account.id] = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let url = try await self.dshService.ensure(account: account)
                guard self.isCurrentDsh(account) else { self.dshBusy.remove(account.id); then?(.failed("账号配置已变化，请重试")); return }
                try self.store.markLaunched(id: account.id, at: Date())
                self.accounts = self.store.accounts
                NSWorkspace.shared.open(url)
                then?(.launched)
                self.refreshDshBalances(account, manual: false)
            } catch {
                if self.isCurrentDsh(account) { self.dshErrors[account.id] = error.localizedDescription }
                then?(.failed(error.localizedDescription))
            }
            self.dshBusy.remove(account.id)
            self.pollDsh()
        }
    }

    func connectDsh(_ account: Account, url: String, completion: @escaping (Bool) -> Void) {
        guard !dshBusy.contains(account.id) else { completion(false); return }
        dshBusy.insert(account.id)
        dshEpochs[account.id, default: 0] += 1
        dshErrors[account.id] = nil
        dshBalances[account.id] = nil
        Task { @MainActor [weak self] in
            guard let self else { completion(false); return }
            do {
                try await self.dshService.connect(account: account, url: url)
                guard self.isCurrentDsh(account) else { self.dshBusy.remove(account.id); completion(false); return }
                self.dshBusy.remove(account.id)
                self.pollDsh()
                completion(true)
            } catch {
                if self.isCurrentDsh(account) { self.dshErrors[account.id] = error.localizedDescription }
                self.dshBusy.remove(account.id)
                completion(false)
            }
        }
    }

    func stopDsh(_ account: Account) {
        guard !dshBusy.contains(account.id) else { return }
        dshBusy.insert(account.id)
        dshEpochs[account.id, default: 0] += 1
        dshErrors[account.id] = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.dshService.stop(account: account)
                if self.isCurrentDsh(account) {
                    var snapshot = self.dshSnapshots[account.id] ?? DshSnapshot()
                    snapshot.running = false
                    snapshot.cached = !snapshot.sessions.isEmpty
                    snapshot.sessions = snapshot.sessions.map { $0.changingStatus(.unknown, label: "缓存") }
                    snapshot.detail = account.dshWeb?.mode == .external ? "已断开；在配置中粘贴授权 URL 重新连接。" : "服务已停止；点击打开网页可重新启动。"
                    self.applyDsh(snapshot, for: account)
                }
            } catch {
                if self.isCurrentDsh(account) { self.dshErrors[account.id] = error.localizedDescription }
            }
            self.dshBusy.remove(account.id)
        }
    }

    func refreshDshBalances(_ account: Account, manual: Bool) {
        guard !refreshingQuotas.contains(account.id), isCurrentDsh(account) else { return }
        refreshingQuotas.insert(account.id)
        let epoch = dshEpochs[account.id, default: 0]
        Task { @MainActor [weak self] in
            guard let self else { return }
            let balances = await self.dshService.balances(account: account, manual: manual)
            self.refreshingQuotas.remove(account.id)
            guard self.isCurrentDsh(account), self.dshEpochs[account.id, default: 0] == epoch else { return }
            self.dshBalances[account.id] = balances
        }
    }

    func openDshOriginalClient(_ account: Account) {
        guard account.localProvider != nil else { return }
        var native = account
        native.dshWeb = nil
        launch(native)
    }
}
