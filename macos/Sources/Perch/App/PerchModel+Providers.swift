import AppKit
import PerchCore

extension PerchModel {
    func scanLocalProviders() {
        localCandidates = LocalProviderDiscovery.scan(home: store.home).filter { candidate in
            !accounts.contains { $0.app == candidate.app && $0.profilePath == candidate.profilePath }
        }
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

    @discardableResult
    func saveLocalProvider(existing: Account?, name: String, profilePath: String, configuration: LocalProviderConfiguration) -> Bool {
        do {
            try configuration.validate()
            if !profilePath.isEmpty {
                var directory: ObjCBool = false
                guard profilePath.hasPrefix("/"), FileManager.default.fileExists(atPath: profilePath, isDirectory: &directory), directory.boolValue else {
                    throw ProviderError.invalid("请选择已有的配置目录")
                }
            }
            if let existing, existing.app != .custom {
                guard existing.profilePath == profilePath, existing.localProvider?.kind == configuration.kind else {
                    throw ProviderError.invalid("本机供应商保留原有登录目录和启动方式")
                }
            }
            let account = Account(id: existing?.id ?? UUID().uuidString.lowercased(),
                                  name: name.trimmingCharacters(in: .whitespacesAndNewlines), app: existing?.app ?? .custom,
                                  profilePath: profilePath, sessionRoot: profilePath,
                                  createdAt: existing?.createdAt ?? Date(), lastLaunchedAt: existing?.lastLaunchedAt,
                                  localProvider: configuration)
            try store.saveProvider(account)
            accounts = store.accounts
            scanLocalProviders()
            poll()
            return true
        } catch { message = error.localizedDescription; return false }
    }

    @discardableResult
    func saveAPIProvider(existing: Account?, name: String, configuration: APIProviderConfiguration, key: String?, removeKey: Bool) -> Bool {
        let credentials = ProviderCredentialStore()
        let id = existing?.id ?? UUID().uuidString.lowercased()
        do {
            try configuration.validate()
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AccountError.emptyName }
            if let key, key.rangeOfCharacter(from: .controlCharacters) != nil { throw APIProviderError.invalidKey }
            let changingEndpoint = existing?.apiProvider.map { $0.baseURL != configuration.baseURL || $0.protocolKind != configuration.protocolKind } ?? false
            let changingKey = key != nil || removeKey
            let previousKey = (changingKey || changingEndpoint) ? try credentials.read(for: id) : nil
            if changingEndpoint, previousKey != nil, key == nil, !removeKey {
                throw ProviderError.invalid("更改 API 地址或协议时，请重新输入密钥，或勾选删除已存密钥")
            }
            let account = Account(id: id, name: name.trimmingCharacters(in: .whitespacesAndNewlines), app: .api,
                                  profilePath: "", sessionRoot: "", createdAt: existing?.createdAt ?? Date(),
                                  lastLaunchedAt: existing?.lastLaunchedAt, apiProvider: configuration)
            if removeKey { try credentials.delete(for: id) }
            else if let key { try credentials.set(key, for: id) }
            do { try store.saveProvider(account) }
            catch {
                if changingKey {
                    do {
                        if let previousKey { try credentials.set(previousKey, for: id) }
                        else { try credentials.delete(for: id) }
                    } catch { message = "账号保存失败，密钥恢复也失败；请重新配置密钥。"; return false }
                }
                throw error
            }
            accounts = store.accounts
            apiCheckTokens[id] = nil
            checkingAPI.remove(id)
            apiChecks[id] = nil
            apiModels[id] = nil
            return true
        } catch { message = error.localizedDescription; return false }
    }

    func checkAPI(_ account: Account) {
        guard let configuration = account.apiProvider, !checkingAPI.contains(account.id) else { return }
        let key: String?
        do { key = try ProviderCredentialStore().read(for: account.id) }
        catch { apiChecks[account.id] = error.localizedDescription; return }
        let token = UUID()
        apiCheckTokens[account.id] = token
        checkingAPI.insert(account.id)
        apiChecks[account.id] = "正在获取模型列表…"
        Task { @MainActor [weak self] in
            let result: Result<[String], Error>
            do {
                result = .success(try await APIProviderClient().check(configuration: configuration, key: key))
            } catch { result = .failure(error) }
            do {
                guard let self, self.apiCheckTokens[account.id] == token else { return }
                self.checkingAPI.remove(account.id)
                guard self.accounts.contains(where: { $0.id == account.id && $0.apiProvider == configuration }) else { return }
                switch result {
                case .success(let models):
                    self.apiModels[account.id] = models
                    self.apiChecks[account.id] = "已获取 \(models.count) 个模型；尚未验证推理或额度"
                case .failure(let error):
                    self.apiModels[account.id] = nil
                    self.apiChecks[account.id] = error.localizedDescription
                }
            }
        }
    }

    func selectModel(_ model: String, for account: Account) {
        guard var configuration = account.apiProvider else { return }
        configuration.model = model
        var changed = account
        changed.apiProvider = configuration
        do { try store.saveProvider(changed); accounts = store.accounts }
        catch { message = error.localizedDescription }
    }

    func copyAPIConfiguration(_ account: Account) {
        guard let configuration = account.apiProvider,
              let data = try? JSONEncoder().encode(configuration), let text = String(data: data, encoding: .utf8) else { return }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        message = "连接配置已复制（不含密钥）"
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
        [.gemini, .geminiApp, .antigravity, .deepseek].contains(account.app) && account.localProvider != nil
    }

    func refreshProviderUsage(_ account: Account) {
        refreshingQuotas.insert(account.id)
        Task { @MainActor [weak self] in
            let result: Result<ProviderUsage, Error>
            do {
                switch account.app {
                case .deepseek: result = .success(try await DeepSeekUsage.query(account))
                case .geminiApp: result = .success(try await NativeGeminiUsage.query(account))
                case .gemini, .antigravity: result = .success(try await GoogleProviderUsage.query(account))
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
