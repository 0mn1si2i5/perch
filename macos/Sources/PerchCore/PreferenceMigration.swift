import Foundation

/// One-time copy of desktop-pet preferences from the old Pox bundle ID (`com.pox.desktop`).
public enum PreferenceMigration {
    public static let legacyDomain = "com.pox.desktop"
    public static let keys = ["petX", "petY", "petSize", "quiet", "mediaEnabled", "codexHome"]
    static let marker = "migratedFromPox"

    /// Copies listed keys that the target does not have yet. Runs at most once per target domain.
    @discardableResult
    public static func run(from legacy: UserDefaults?, to target: UserDefaults) -> [String] {
        guard !target.bool(forKey: marker) else { return [] }
        var copied: [String] = []
        if let legacy {
            for key in keys where target.object(forKey: key) == nil {
                if let value = legacy.object(forKey: key) {
                    target.set(value, forKey: key)
                    copied.append(key)
                }
            }
        }
        target.set(true, forKey: marker)
        return copied
    }
}
