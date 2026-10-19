import Foundation
import CryptoKit

/// Terminal receives a private command file, not an AppleScript command or a shell-interpolated credential.
public enum LocalProviderLauncher {
    public static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Perch/Launchers")
    }

    public static func scriptURL(for account: Account, directory: URL = directory) -> URL {
        let digest = SHA256.hash(data: Data(account.id.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest + ".command")
    }

    public static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    public static func script(for account: Account, directory: URL = directory) throws -> String {
        guard let config = account.localProvider, config.kind == .terminal else { throw ProviderError.invalid("不是终端客户端") }
        try config.validate()
        let location = scriptURL(for: account, directory: directory)
        let marker = location.appendingPathExtension("pid").path
        var lines = ["#!/bin/zsh", "umask 077", "print -r -- $$ > " + quote(marker),
                     "trap " + quote("/bin/rm -f -- " + quote(marker)) + " EXIT"]
        let home = NSHomeDirectory()
        // GUI launches may have no npm/Homebrew PATH. Keep the user's shell PATH as a fallback.
        let paths = [URL(fileURLWithPath: config.target).deletingLastPathComponent().path,
                     home + "/.local/bin", home + "/.npm-global/bin", home + "/.bun/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        lines += ["export PATH=" + quote(paths.joined(separator: ":")) + ":\"$PATH\""]
        if account.app == .gemini {
            guard URL(fileURLWithPath: account.profilePath).lastPathComponent == ".gemini" else {
                throw ProviderError.invalid("Gemini 数据目录必须是 .gemini；其父目录作为 GEMINI_CLI_HOME")
            }
            lines += ["export GEMINI_CLI_HOME=" + quote(URL(fileURLWithPath: account.profilePath).deletingLastPathComponent().path)]
        } else if account.app == .deepseek {
            lines += ["export DSH_HOME=" + quote(account.profilePath)]
        }
        if !config.workingDirectory.isEmpty { lines += ["cd -- " + quote(config.workingDirectory) + " || exit 1"] }
        lines += [([config.target] + config.arguments).map(quote).joined(separator: " "),
                  "result=$?", "if (( result != 0 )); then print -r -- \"客户端已退出（$result）\"; fi", "exit $result"]
        return lines.joined(separator: "\n") + "\n"
    }

    public static func isRunning(_ account: Account, processes: [RunningProcess], directory: URL = directory) -> Bool {
        if account.localProvider?.kind == .application {
            return applicationProcess(account, processes: processes) != nil
        }
        let url = scriptURL(for: account, directory: directory)
        guard let text = try? String(contentsOf: url.appendingPathExtension("pid"), encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return processes.contains { $0.pid == pid && ($0.args == "/bin/zsh " + url.path || $0.args == "/bin/zsh -- " + url.path) }
    }

    public static func applicationProcess(_ account: Account, processes: [RunningProcess]) -> RunningProcess? {
        guard let config = account.localProvider, config.kind == .application,
              let data = try? Data(contentsOf: URL(fileURLWithPath: config.target).appendingPathComponent("Contents/Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let name = plist["CFBundleExecutable"] as? String else { return nil }
        let executable = URL(fileURLWithPath: config.target).appendingPathComponent("Contents/MacOS").appendingPathComponent(name).path
        return processes.first { $0.args == executable || $0.args.hasPrefix(executable + " ") }
    }

    public static func command(for account: Account, directory: URL = directory) throws -> LaunchCommand {
        guard let config = account.localProvider else { throw ProviderError.invalid("缺少启动配置") }
        try config.validate()
        switch config.kind {
        case .website: return LaunchCommand(arguments: [config.target])
        case .application:
            return LaunchCommand(arguments: ["-a", config.target] + (config.arguments.isEmpty ? [] : ["--args"] + config.arguments))
        case .terminal:
            let contents = try script(for: account, directory: directory)
            let fm = FileManager.default
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let url = scriptURL(for: account, directory: directory)
            try Data(contents.utf8).write(to: url, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            return LaunchCommand(arguments: ["-a", "Terminal", url.path])
        }
    }
}
