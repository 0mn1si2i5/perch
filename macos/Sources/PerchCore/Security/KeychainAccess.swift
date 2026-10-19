import Foundation
import Security

/// Legacy keychain interaction is process-wide; every Perch SecItem operation uses this lock.
/// LAContext alone does not suppress the access dialog for file-based keychain items.
final class KeychainAccess {
    static let shared = KeychainAccess(getInteractionAllowed: {
        var allowed: DarwinBoolean = false
        let status = SecKeychainGetUserInteractionAllowed(&allowed)
        return (status, allowed.boolValue)
    }, setInteractionAllowed: { SecKeychainSetUserInteractionAllowed($0) })

    struct Failure: Error, Equatable {
        let status: OSStatus
    }

    private let lock = NSLock()
    private let getInteractionAllowed: () -> (status: OSStatus, allowed: Bool)
    private let setInteractionAllowed: (Bool) -> OSStatus

    init(getInteractionAllowed: @escaping () -> (status: OSStatus, allowed: Bool),
         setInteractionAllowed: @escaping (Bool) -> OSStatus) {
        self.getInteractionAllowed = getInteractionAllowed
        self.setInteractionAllowed = setInteractionAllowed
    }

    func serialized<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }

    func withInteraction<T>(allowed: Bool, _ operation: () throws -> T) throws -> T {
        try serialized {
            let previous = getInteractionAllowed()
            guard previous.status == errSecSuccess else { throw Failure(status: previous.status) }
            var restoreStatus = errSecSuccess
            let result: Result<T, Error> = {
                // Restore even when changing the flag or the protected operation fails.
                defer { restoreStatus = setInteractionAllowed(previous.allowed) }
                let status = setInteractionAllowed(allowed)
                guard status == errSecSuccess else { return .failure(Failure(status: status)) }
                return Result(catching: operation)
            }()
            guard restoreStatus == errSecSuccess else { throw Failure(status: restoreStatus) }
            return try result.get()
        }
    }
}
