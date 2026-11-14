import Foundation

public struct DshInstallCandidate: Identifiable, Equatable {
    public var id: String { path }
    public let path: String
    public let mode: DshMode
    public let version: String
    public let source: String
    public let node: String
    public let nodeRequirement: String
    public var label: String { source + " · " + version }

    public init(path: String, mode: DshMode, version: String, source: String,
                node: String = "", nodeRequirement: String = "") {
        self.path = path; self.mode = mode; self.version = version; self.source = source
        self.node = node; self.nodeRequirement = nodeRequirement
    }
}

/// No shell parses these arguments. Only the selected account receives DSH_HOME.
public struct DshLaunch: Codable, Equatable {
    public let node: String
    public let entry: String
    public let workingDirectory: String
    public let home: String
    public let profile: String

    public init(node: String, entry: String, workingDirectory: String, home: String, profile: String) {
        self.node = node; self.entry = entry; self.workingDirectory = workingDirectory
        self.home = home; self.profile = profile
    }

    public var arguments: [String] {
        [entry, "--profile", profile, "--host", "127.0.0.1", "--port", "0", "--no-open"]
    }

    public var environment: [String: String] {
        var values = ProcessInfo.processInfo.environment
        let nodeDirectory = URL(fileURLWithPath: node).deletingLastPathComponent().path
        let directories = [nodeDirectory] + ToolPaths.userDirectories() + ["/usr/bin", "/bin"]
        values["PATH"] = directories.joined(separator: ":") + ":" + (values["PATH"] ?? "")
        values["DSH_HOME"] = home
        return values
    }
}

/// Reads installation metadata only: discovering a package never runs npm, npx, or a shell shim.
public enum DshInstallation {
    public static func normalize(_ value: String, home: String = NSHomeDirectory(),
                                 environment: [String: String] = ProcessInfo.processInfo.environment) throws -> String {
        var value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first {
            value.removeFirst(); value.removeLast()
        }
        guard !value.isEmpty, !value.contains("\0") else { throw DshError.invalid("请输入有效的绝对路径。") }
        if value == "~" || value.hasPrefix("~/") { value = home + String(value.dropFirst()) }
        var variables = environment
        variables["HOME"] = home
        let regex = try NSRegularExpression(pattern: #"\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)"#)
        let original = value as NSString
        for match in regex.matches(in: value, range: NSRange(location: 0, length: original.length)).reversed() {
            let range = match.range(at: match.range(at: 1).location == NSNotFound ? 2 : 1)
            let key = original.substring(with: range)
            guard let replacement = variables[key] else { throw DshError.invalid("路径中的环境变量尚未定义：" + key) }
            guard let swiftRange = Range(match.range, in: value) else { throw DshError.invalid("路径无效。") }
            value.replaceSubrange(swiftRange, with: replacement)
        }
        guard value.hasPrefix("/") else { throw DshError.invalid("请选择绝对路径，或使用 ~/ 表示个人目录。") }
        return URL(fileURLWithPath: value).standardizedFileURL.resolvingSymlinksInPath().path
    }

    public static func findNode(home: String = NSHomeDirectory(), path: String = ProcessInfo.processInfo.environment["PATH"] ?? "") -> String? {
        directories(home: home, path: path).lazy.map { $0 + "/node" }.first {
            FileManager.default.isExecutableFile(atPath: $0) && isRegularFile($0)
        }.flatMap { try? normalize($0, home: home) }
    }

    public static func discover(home: String = NSHomeDirectory(), path: String = ProcessInfo.processInfo.environment["PATH"] ?? "",
                                environment: [String: String] = ProcessInfo.processInfo.environment) -> [DshInstallCandidate] {
        var found: [DshInstallCandidate] = []
        var seen = Set<String>()
        func add(_ location: String, _ source: String) {
            guard let normalized = try? normalize(location, home: home, environment: environment),
                  let candidate = inspect(normalized, source: source), seen.insert(candidate.path).inserted else { return }
            found.append(candidate)
        }
        for directory in directories(home: home, path: path) {
            add(directory + "/dsh", "PATH / npm")
            add(directory, "PATH / npm")
            add(directory + "/../lib", "npm 前缀")
        }
        let npmrc = npmPaths(home + "/.npmrc")
        for prefix in [environment["npm_config_prefix"], npmrc.prefix, home + "/.npm-global", "/opt/homebrew", "/usr/local"].compactMap({ $0 }) {
            add(prefix, "npm 全局安装")
        }
        for cache in [environment["npm_config_cache"], npmrc.cache, home + "/.npm"].compactMap({ $0 }) {
            guard let cache = try? normalize(cache, home: home, environment: environment) else { continue }
            for directory in children(cache + "/_npx").sorted(by: { modificationDate($0) > modificationDate($1) }) {
                add(directory, "npx 缓存（可能被 npm 清理）")
            }
        }
        return found
    }

    public static func inspect(_ input: String) -> DshInstallCandidate? { inspect(input, source: "手动选择") }

    private static func inspect(_ input: String, source: String) -> DshInstallCandidate? {
        guard let path = try? normalize(input) else { return nil }
        if isRegularFile(path) {
            // npm's bin entry is normally a symlink. Resolve it, then locate its package manifest.
            var directory = URL(fileURLWithPath: path).deletingLastPathComponent()
            for _ in 0..<6 {
                if let candidate = package(directory.path, source: source) { return candidate }
                if let candidate = sourcePackage(directory.path, source: source) { return candidate }
                let parent = directory.deletingLastPathComponent()
                if parent == directory { break }
                directory = parent
            }
            return nil
        }
        guard isDirectory(path) else { return nil }
        if let candidate = package(path, source: source) { return candidate }
        if let candidate = sourcePackage(path, source: source) { return candidate }
        for suffix in ["node_modules/@deepseek-ai/dsh", "@deepseek-ai/dsh", "lib/node_modules/@deepseek-ai/dsh"] {
            if let candidate = package(path + "/" + suffix, source: source) { return candidate }
        }
        return nil
    }

    public static func resolve(account: Account) throws -> DshLaunch {
        guard account.app == .deepseek, let configuration = account.dshWeb,
              configuration.mode != .external else { throw DshError.invalid("这个账号仅连接已有 dsh 实例，请提供授权 URL。") }
        let candidate = configuration.installationPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? discover().first : inspect(configuration.installationPath)
        guard let candidate else { throw DshError.invalid("未找到完整的 dsh 安装，请选择 npm 包目录、dsh 命令或已构建的源码目录。") }
        guard candidate.mode == configuration.mode else { throw DshError.invalid("安装目录与启动方式不一致，请重新选择源码构建版或 npm 安装版。") }
        let packagePath = candidate.mode == .source ? candidate.path + "/apps/cli" : candidate.path
        if candidate.mode == .source, !isRegularFile(candidate.path + "/apps/web/dist/index.html") {
            throw DshError.invalid("dsh Web 尚未构建，请在源码目录运行 pnpm install 和 pnpm run build。")
        }
        guard let manifest = manifest(packagePath), let entry = entry(manifest, package: packagePath) else {
            throw DshError.invalid("dsh 安装不完整，找不到 package.json 声明的 CLI 入口。")
        }
        let node: String?
        if configuration.nodePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            node = candidate.node.isEmpty ? findNode() : candidate.node
        } else { node = try normalize(configuration.nodePath) }
        guard let node, isRegularFile(node), FileManager.default.isExecutableFile(atPath: node) else {
            throw DshError.invalid("找不到可执行的 Node.js，请安装符合 dsh 要求的 Node 或选择 node 文件。")
        }
        let profile = configuration.profile.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !profile.isEmpty, profile.lowercased() != "desktop", ![".", ".."].contains(profile),
              !profile.contains("/"), !profile.contains("\\"), !profile.contains("\0") else {
            throw DshError.invalid("请选择有效的 Web profile，不能使用 Electron 专属的 desktop。")
        }
        let home = try normalize(account.profilePath)
        if profile != "web", !isRegularFile(home + "/profiles/" + profile + "/package.json") {
            throw DshError.invalid("自定义 Web profile 不存在，请先在 dsh 中创建并配置。")
        }
        return DshLaunch(node: node, entry: entry, workingDirectory: candidate.path, home: home, profile: profile)
    }

    private static func package(_ path: String, source: String) -> DshInstallCandidate? {
        guard let path = try? normalize(path), let value = manifest(path),
              value["name"] as? String == "@deepseek-ai/dsh", entry(value, package: path) != nil else { return nil }
        return .init(path: path, mode: .npm, version: value["version"] as? String ?? "版本未知", source: source,
                     node: associatedNode(path), nodeRequirement: (value["engines"] as? [String: Any])?["node"] as? String ?? "")
    }

    private static func sourcePackage(_ path: String, source: String) -> DshInstallCandidate? {
        guard manifest(path)?["name"] as? String == "@deepseek-ai/dsh-root",
              let cli = package(path + "/apps/cli", source: source) else { return nil }
        return .init(path: path, mode: .source, version: cli.version, source: source,
                     node: associatedNode(path), nodeRequirement: cli.nodeRequirement)
    }

    private static func entry(_ manifest: [String: Any], package: String) -> String? {
        guard let relative = manifest["bin"] as? String ?? (manifest["bin"] as? [String: String])?["dsh"],
              !relative.isEmpty, !relative.hasPrefix("/"), !relative.contains("\0"),
              let path = try? normalize(package + "/" + relative), path.hasPrefix(package + "/"), isRegularFile(path) else { return nil }
        return path
    }

    private static func associatedNode(_ package: String) -> String {
        var directory = URL(fileURLWithPath: package)
        for _ in 0..<7 {
            if directory.path == "/" { break }
            for location in [directory.appendingPathComponent("bin/node").path, directory.appendingPathComponent("node").path] {
                if isRegularFile(location), FileManager.default.isExecutableFile(atPath: location) {
                    return (try? normalize(location)) ?? location
                }
            }
            let parent = directory.deletingLastPathComponent()
            if parent == directory { break }
            directory = parent
        }
        return ""
    }

    private static func manifest(_ directory: String) -> [String: Any]? {
        let url = URL(fileURLWithPath: directory).appendingPathComponent("package.json")
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1_048_576,
              let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func directories(home: String, path: String) -> [String] {
        let values = path.split(separator: ":").map(String.init) + ToolPaths.userDirectories(home: home) + nvmDirectories(home: home)
        var seen = Set<String>()
        return values.filter { $0.hasPrefix("/") && seen.insert($0).inserted }
    }

    /// Finder launches have no shell-selected Node; prefer the newest installed nvm version numerically.
    static func nvmDirectories(home: String) -> [String] {
        children(home + "/.nvm/versions/node").sorted {
            URL(fileURLWithPath: $0).lastPathComponent.compare(URL(fileURLWithPath: $1).lastPathComponent,
                                                            options: .numeric, locale: Locale(identifier: "en_US_POSIX")) == .orderedDescending
        }.map { $0 + "/bin" }
    }

    private static func children(_ path: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }.map(\.path)
    }
    private static func modificationDate(_ path: String) -> Date {
        (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
    private static func isDirectory(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }
    private static func isRegularFile(_ path: String) -> Bool {
        (try? URL(fileURLWithPath: path).resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }
    private static func npmPaths(_ path: String) -> (prefix: String?, cache: String?) {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)), data.count <= 65_536,
              let text = String(data: data, encoding: .utf8) else { return (nil, nil) }
        var prefix: String?, cache: String?
        for line in text.components(separatedBy: .newlines) {
            let fields = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count == 2 else { continue }
            if fields[0] == "prefix" { prefix = fields[1] }
            if fields[0] == "cache" { cache = fields[1] }
        }
        return (prefix, cache)
    }
}
