import Foundation

public enum ProviderError: LocalizedError, Equatable {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case .invalid(let text): return text }
    }
}

public enum LocalLaunchKind: String, Codable, CaseIterable {
    case terminal, application
    public var displayName: String {
        switch self {
        case .terminal: return "终端命令"
        case .application: return "macOS 应用"
        }
    }
}

/// Public configuration only. Authentication stays in the client's existing data directory.
public struct LocalProviderConfiguration: Codable, Equatable {
    public var kind: LocalLaunchKind
    public var target: String
    public var arguments: [String]
    public var workingDirectory: String

    public init(kind: LocalLaunchKind, target: String, arguments: [String] = [], workingDirectory: String = "") {
        self.kind = kind; self.target = target; self.arguments = arguments; self.workingDirectory = workingDirectory
    }

    public func validate() throws {
        guard !target.isEmpty, !([target, workingDirectory] + arguments).contains(where: { $0.contains("\0") }) else {
            throw ProviderError.invalid("启动位置无效")
        }
        switch kind {
        case .terminal:
            guard target.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: target) else {
                throw ProviderError.invalid("找不到可执行文件 \(target)")
            }
        case .application:
            guard target.hasPrefix("/"), target.hasSuffix(".app"), FileManager.default.fileExists(atPath: target) else {
                throw ProviderError.invalid("找不到应用 \(target)")
            }
        }
        if !workingDirectory.isEmpty {
            var directory: ObjCBool = false
            guard workingDirectory.hasPrefix("/"), FileManager.default.fileExists(atPath: workingDirectory, isDirectory: &directory), directory.boolValue else {
                throw ProviderError.invalid("工作目录不存在")
            }
        }
    }
}

public struct LocalProviderCandidate: Identifiable, Equatable {
    public var id: String { app.rawValue + ":" + profilePath }
    public let name: String
    public let app: AppKind
    public let profilePath: String
    public let configuration: LocalProviderConfiguration
    public init(name: String, app: AppKind, profilePath: String, configuration: LocalProviderConfiguration) {
        self.name = name; self.app = app; self.profilePath = profilePath; self.configuration = configuration
    }
}

/// An added provider whose client a scan found at another launch location. Its data directory is unchanged.
public struct LocalLaunchUpdate: Identifiable, Equatable {
    public var id: String { account.id }
    public let account: Account
    public let configuration: LocalProviderConfiguration
    public init(account: Account, configuration: LocalProviderConfiguration) {
        self.account = account; self.configuration = configuration
    }
}

public enum LocalProviderDiscovery {
    /// The configuration a scanned candidate offers an added account with the same data directory, when the launch
    /// location differs. Arguments and working directory are kept unless the launch kind changes.
    public static func launchUpdate(for account: Account, candidate: LocalProviderCandidate) -> LocalLaunchUpdate? {
        guard let current = account.localProvider, account.app == candidate.app, account.profilePath == candidate.profilePath else { return nil }
        let found = candidate.configuration
        guard found.kind != current.kind || found.target != current.target else { return nil }
        var updated = found
        if found.kind == current.kind { updated = current; updated.target = found.target }
        return LocalLaunchUpdate(account: account, configuration: updated)
    }

    public static func executable(_ name: String, home: String = NSHomeDirectory(), path: String = ProcessInfo.processInfo.environment["PATH"] ?? "") -> String? {
        let directories = ToolPaths.userDirectories(home: home) + path.split(separator: ":").map(String.init)
        return directories.map { ($0 as NSString).appendingPathComponent(name) }.first {
            $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    private static func deepSeekDesktopHome(home: String) -> String? {
        let state = URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/DSH Desktop/data-directory/state.json")
        let fm = FileManager.default
        if fm.fileExists(atPath: state.path) {
            guard let values = try? state.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 65536,
                  let data = try? Data(contentsOf: state),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["version"] as? Int == 1, let active = json["activeHome"] as? String, active.hasPrefix("/"),
                  let target = try? URL(fileURLWithPath: active).resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  target.isDirectory == true, target.isSymbolicLink != true else { return nil }
            return active
        }
        let path = (home as NSString).appendingPathComponent(".dsh")
        var directory: ObjCBool = false
        return fm.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue ? path : nil
    }

    public static func scan(home: String = NSHomeDirectory(), path: String = ProcessInfo.processInfo.environment["PATH"] ?? "",
                            applicationRoots: [URL] = AppLocator.searchRoots()) -> [LocalProviderCandidate] {
        let entries: [(AppKind, String, String, [String])] = [
            (.gemini, "gemini", ".gemini", []),
            (.antigravity, "agy", ".gemini/antigravity-cli", []),
            (.deepseek, "dsh", ".dsh", ["--profile", "web", "--host", "127.0.0.1", "--port", "3080"])
        ]
        var candidates = entries.compactMap { app, command, relative, arguments -> LocalProviderCandidate? in
            let data = (home as NSString).appendingPathComponent(relative)
            if app == .deepseek, let desktop = applicationRoots.map({ $0.appendingPathComponent("DSH Desktop.app") })
                .first(where: { AppLocator.bundleID(at: $0) == "ai.deepseek.dsh.desktop" }) {
                guard let activeHome = deepSeekDesktopHome(home: home) else { return nil }
                return LocalProviderCandidate(name: "DSH Desktop", app: .deepseek, profilePath: activeHome,
                                              configuration: .init(kind: .application, target: desktop.path))
            }
            guard FileManager.default.fileExists(atPath: data), let executable = executable(command, home: home, path: path) else { return nil }
            return LocalProviderCandidate(name: app.displayName, app: app, profilePath: data,
                                          configuration: .init(kind: .terminal, target: executable, arguments: arguments, workingDirectory: home))
        }
        let nativeData = home + "/Library/Application Support/com.google.GeminiMacOS"
        if let nativeGemini = applicationRoots.map({ $0.appendingPathComponent("Gemini.app") })
            .first(where: { AppLocator.bundleID(at: $0) == "com.google.GeminiMacOS" }),
           FileManager.default.fileExists(atPath: nativeData) {
            candidates.append(.init(name: "Gemini", app: .geminiApp, profilePath: nativeData,
                                    configuration: .init(kind: .application, target: nativeGemini.path)))
        }
        return candidates
    }
}
