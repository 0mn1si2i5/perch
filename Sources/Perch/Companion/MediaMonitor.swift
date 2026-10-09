import AppKit
import Foundation
import PerchCore

/// Read-only access to the system's active media session through the bundled, pinned adapter.
/// The command is fixed; neither media text nor UI input can choose arguments or execute commands.
final class MediaMonitor {
    private let queue = DispatchQueue(label: "com.omnis.perch.media", qos: .utility)
    private var busy = false

    func poll(_ completion: @escaping (MediaSnapshot) -> Void) {
        guard !busy else { return }
        guard let resources = Bundle.main.resourceURL else {
            completion(MediaSnapshot(source: "媒体组件未安装")); return
        }
        let script = resources.appendingPathComponent("mediaremote-adapter.pl")
        let framework = resources.appendingPathComponent("MediaRemoteAdapter.framework")
        guard FileManager.default.fileExists(atPath: script.path),
              FileManager.default.fileExists(atPath: framework.path) else {
            completion(MediaSnapshot(source: "媒体组件未安装")); return
        }
        busy = true
        queue.async { [weak self] in
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
            process.arguments = [script.path, framework.path, "get", "--no-artwork", "--allow-missing-title"]
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            // Never pass Codex credentials or the host's process environment to the helper.
            process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]
            let result: MediaSnapshot
            do {
                try process.run()
                let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3, execute: timeout)
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                timeout.cancel()
                if process.terminationStatus != 0 {
                    result = MediaSnapshot(source: "系统媒体状态暂不可用")
                } else if data.count < 64 * 1024,
                          let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
                          let values = json as? [String: Any] {
                    let playing = values["playing"] as? Bool ?? false
                    let id = values["parentApplicationBundleIdentifier"] as? String ?? values["bundleIdentifier"] as? String ?? ""
                    let kind = MediaPolicy.classify(type: values["mediaType"] as? String, bundleID: id,
                                                    isMusicApp: values["isMusicApp"] as? Bool ?? false)
                    // Only state and application identity are retained. Song/video titles are discarded.
                    result = MediaSnapshot(kind: playing ? kind : .none, playing: playing, source: id)
                } else {
                    result = MediaSnapshot(source: "未检测到正在播放的媒体")
                }
            } catch {
                result = MediaSnapshot(source: "媒体组件暂不可用")
            }
            DispatchQueue.main.async {
                self?.busy = false
                var value = result
                if result.playing {
                    value.source = NSRunningApplication.runningApplications(withBundleIdentifier: result.source).first?.localizedName ?? "系统播放器"
                } else if result.source.contains(".") {
                    value.source = "播放已暂停"
                }
                completion(value)
            }
        }
    }
}
