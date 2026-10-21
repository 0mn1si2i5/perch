import Foundation

/// A conversation that stopped running since the previous poll: it finished, failed or is waiting for the owner.
public struct SessionChange: Equatable {
    public let id: String
    /// `.completed`, `.failed` or `.waiting`.
    public let status: TaskStatus
    public init(id: String, status: TaskStatus) { self.id = id; self.status = status }
}

/// Compares one account's conversations between polls. The first update only records them, so a conversation
/// that finished before Perch started is never reported.
public struct SessionChangeTracker {
    private var last: [String: TaskStatus]?

    public init() {}

    /// Reports a conversation seen running or waiting on an earlier poll that has now completed, failed or started
    /// waiting, and a conversation that first appears already waiting. One that is merely new to the list and
    /// already finished is not reported: nothing says when it finished.
    public mutating func update(_ sessions: [(id: String, status: TaskStatus)]) -> [SessionChange] {
        var current: [String: TaskStatus] = [:]
        for session in sessions where current[session.id] == nil { current[session.id] = session.status }
        let previous = last
        // A conversation seen running keeps that record when one read misses it, so its finish is still noticed.
        last = current.merging((previous ?? [:]).filter { $0.value.isActive }) { now, _ in now }
        guard let previous else { return [] }
        var reported = Set<String>()
        return sessions.compactMap { session in
            guard reported.insert(session.id).inserted else { return nil }
            switch (previous[session.id], session.status) {
            case (.running?, .waiting), (.running?, .completed), (.running?, .failed),
                 (.waiting?, .completed), (.waiting?, .failed), (nil, .waiting):
                return SessionChange(id: session.id, status: session.status)
            default:
                return nil
            }
        }
    }
}
