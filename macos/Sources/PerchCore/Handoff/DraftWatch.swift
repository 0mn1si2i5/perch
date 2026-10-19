import Foundation

/// Tells when the source conversation has finished writing a handoff draft: the file exists, is not empty, kept
/// the same size over two polls in a row, and the source conversation is no longer running. Says so once.
public struct DraftWatch {
    private var size: Int?
    public private(set) var reported = false

    public init() {}

    /// `size` is the draft's size this poll, nil when it does not exist yet.
    public mutating func observe(size newSize: Int?, sourceBusy: Bool) -> Bool {
        defer { size = newSize }
        guard !reported, !sourceBusy, let newSize, newSize > 0, newSize == size else { return false }
        reported = true
        return true
    }
}
