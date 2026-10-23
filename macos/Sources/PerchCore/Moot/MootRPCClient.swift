import Foundation
public struct MootRPCClient: Sendable {
    public var paths: MootPaths
    public init(paths: MootPaths = MootPaths()) { self.paths = paths }
    public func call(_ request: MootRPCRequest) async throws -> MootRPCResponse {
        let input = try JSONEncoder().encode(request), paths = self.paths
        return try await Task.detached {
            let process = Process(), stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
            process.executableURL = paths.executable
            process.arguments = ["rpc"]
            var environment = ProcessInfo.processInfo.environment
            environment["MOOT_ROOT"] = paths.root.path
            process.environment = environment
            process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
            // Drain both streams concurrently; a full stderr pipe cannot stall a JSON reply.
            stderr.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }
            defer { stderr.fileHandleForReading.readabilityHandler = nil }
            try process.run()
            stdin.fileHandleForWriting.write(input)
            try stdin.fileHandleForWriting.close()
            let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 35, execute: deadline)
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit(); deadline.cancel()
            let response = try MootRPCResponse.decode(data)
            guard response.requestID == request.requestID else { throw MootRPCError(code: "requestMismatch", message: "扩展响应不匹配") }
            if !response.ok { throw response.error ?? MootRPCError(code: "failed", message: "扩展操作失败") }
            return response
        }.value
    }
}
