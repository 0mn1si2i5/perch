import Foundation

public enum MootJSON: Codable, Equatable, Sendable {
    case object([String: MootJSON]), array([MootJSON]), string(String), number(Double), bool(Bool), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([MootJSON].self) { self = .array(v) }
        else { self = .object(try c.decode([String: MootJSON].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self { case .object(let v): try c.encode(v); case .array(let v): try c.encode(v); case .string(let v): try c.encode(v); case .number(let v): try c.encode(v); case .bool(let v): try c.encode(v); case .null: try c.encodeNil() }
    }
    public subscript(_ key: String) -> MootJSON { if case .object(let o) = self { return o[key] ?? .null }; return .null }
    public var text: String { if case .string(let s) = self { return s }; return "" }
    public var items: [MootJSON] { if case .array(let a) = self { return a }; return [] }
    public var integer: Int { if case .number(let n) = self { return Int(n) }; return 0 }
    public var roundID: Int { self["number"].integer }
    public var seatID: String { self["seatID"].text }
    public var issueID: String { self["issueID"].text }
    public var eventID: String { self["id"].text }
    public var flag: Bool { if case .bool(let b) = self { return b }; return false }
    public static func encode<T: Encodable>(_ value: T) throws -> MootJSON { try JSONDecoder().decode(Self.self, from: JSONEncoder().encode(value)) }
    public func decode<T: Decodable>(_ type: T.Type) throws -> T { try JSONDecoder().decode(type, from: JSONEncoder().encode(self)) }
    public var pretty: String { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; return (try? String(data: e.encode(self), encoding: .utf8)) ?? "" }
}

public struct MootConfig: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var revision = 0
    public var apiEnabled = false
    public var automaticRoundtable = false
    public var connections: [MootConnection] = []
    public var capabilities: [MootCapability] = []
    public var meetingPreset = MootMeetingPreset()
    public init() {}
}
public struct MootConnection: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID().uuidString
    public var name = "新接入"
    public var perchAccountID: String?
    public var adapter = "codex"
    public var authMode = "subscription"
    public var enabled = true
    public var executable = ""
    public var accountRoot = ""
    public var defaultModel = ""
    public var credentialRef: String?
    public var tools: [String] = []
    public var models: [String]?
    public var verification: MootJSON?
    public init() {}
}
public struct MootCapability: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID().uuidString
    public var enabled = true
    public var description = "自定义能力"
    public var primaryConnectionID = ""
    public var modelOverride: String?
    public var completionMode = "delegate"
    public var requiredTools: [String] = []
    public var fallbackConnectionIDs: [String] = []
    public var instructions = ""
    public init() {}
}
public struct MootMeetingPreset: Codable, Equatable, Sendable {
    public var seats: [MootSeat] = []
    public var maxRounds = 3
    public var allowEarlyFinish = false
    public init() {}
}
public struct MootSeat: Codable, Equatable, Identifiable, Sendable {
    public var seatID = UUID().uuidString
    public var id: String { seatID }
    public var connectionID = ""
    public var model = ""
    public var role = "独立审视"
    public var instructions = ""
    public init() {}
}
public struct MootRPCRequest: Codable, Sendable {
    public var protocolVersion = 1
    public var requestID: String
    public var operation: String
    public var payload: MootJSON
    public init(operation: String, payload: MootJSON = .object([:]), requestID: String = UUID().uuidString) {
        self.operation = operation; self.payload = payload; self.requestID = requestID
    }
}
public struct MootRPCResponse: Codable, Sendable {
    public var protocolVersion: Int
    public var requestID: String
    public var ok: Bool
    public var data: MootJSON?
    public var error: MootRPCError?
    public static func decode(_ data: Data) throws -> Self {
        let r = try JSONDecoder().decode(Self.self, from: data)
        guard r.protocolVersion == 1 else { throw MootRPCError(code: "incompatibleProtocol", message: "扩展协议版本不兼容") }
        return r
    }
}
public struct MootRPCError: Error, Codable, LocalizedError, Sendable {
    public var code: String
    public var message: String
    public var errorDescription: String? { message }
    public init(code: String, message: String) { self.code = code; self.message = message }
}
public struct MootRunSnapshot: Identifiable, Equatable, Sendable {
    public var record: MootJSON
    public var id: String { record["id"].text }
    public var state: String { record["state"].text }
    public var title: String { String(record["brief"].text.prefix(90)) }
    public var active: Bool { !record["readOnlyHistory"].flag && !["ended", "failed", "cancelled", "legacy"].contains(state) }
    public init(record: MootJSON) { self.record = record }
}
