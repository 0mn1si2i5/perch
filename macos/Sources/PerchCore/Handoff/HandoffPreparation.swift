import Foundation

/// What the new conversation takes over.
public enum HandoffScope: String, Codable {
    /// The whole task moves; the source conversation is done with it.
    case task
    /// One requirement is split off; the source conversation keeps its own task.
    case split

    /// Stored as the log entry's method.
    public var method: String { self == .task ? "文档接力" : "拆出需求" }
}

/// Metadata for a user-driven handoff, never a transcript or a model request.
/// The target may be the source account itself: the document then goes to a new conversation there.
public struct HandoffPreparation: Codable, Equatable, Identifiable {
    public let id: UUID
    public let sourceID: String
    public let targetID: String
    public let conversationID: String
    public let title: String
    public let createdAt: Date
    public let scope: HandoffScope
    /// Set by the first delivery attempt that read the document: its saved copy and its log record.
    /// A retry after the target failed to open reuses both.
    public var documentPath: String?
    public var recordID: String?

    public var staysInAccount: Bool { sourceID == targetID }

    public init(sourceID: String, targetID: String, conversationID: String, title: String,
                scope: HandoffScope = .task, createdAt: Date = Date()) {
        id = UUID()
        self.sourceID = sourceID; self.targetID = targetID
        self.conversationID = conversationID; self.title = title; self.scope = scope; self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, sourceID, targetID, conversationID, title, createdAt, scope, documentPath, recordID
    }

    /// Pending records written before `scope` existed are whole-task handoffs.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        sourceID = try values.decode(String.self, forKey: .sourceID)
        targetID = try values.decode(String.self, forKey: .targetID)
        conversationID = try values.decode(String.self, forKey: .conversationID)
        title = try values.decode(String.self, forKey: .title)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        scope = try values.decodeIfPresent(HandoffScope.self, forKey: .scope) ?? .task
        documentPath = try values.decodeIfPresent(String.self, forKey: .documentPath)
        recordID = try values.decodeIfPresent(String.self, forKey: .recordID)
    }
}

extension HandoffDocument {
    public static func preparationPrompt(savedAt file: URL, scope: HandoffScope = .task) -> String {
        scope == .split ? splitPrompt(savedAt: file) : taskPrompt(savedAt: file)
    }

    /// Ends with an open label, so the owner types the requirement right after pasting.
    static func splitPrompt(savedAt file: URL) -> String {
        """
        请把当前对话里一项需要单独处理的需求整理成 Markdown 交接文档，交给一个新对话从头接手。只整理这一项，不执行它，也不继续原任务；原对话之后还会继续原来的工作。

        要拆出的需求写在本消息末尾。末尾没有写时，选最近讨论中明确说要单独处理的那一项，并在文档第一行写明选的是哪一项；无法确定就不要写文件，直接问我。

        请写入以下绝对路径（含空格，使用时请正确引用）：
        \(file.standardizedFileURL.path)

        按需包含四部分，无关项可省略：
        1. 需求：要做什么、为什么单独处理、完成标准、关键约束和已授权范围。
        2. 相关现状：与这项需求有关的文件、已有结论和已排除的方案；不写原任务的整体进展。
        3. 接续上下文：工作目录绝对路径、关键文件；代码任务注明当前分支／提交。原对话还会继续改同一个仓库时，说明哪些未提交改动与这项需求有关，并建议新对话使用单独的分支或工作树。
        4. 下一步：建议的第一步、真实阻塞及仍需用户决定的问题。

        通常 300–800 字，以接手后能直接开始为准。用当前事实和必要路径／命令代替聊天复述，省略原任务的无关背景、长日志、原始对话和凭据。不确定的标“未确认”。

        写完后只回复文件路径和一行摘要，然后停下，等我继续原任务。如无法写文件，请说明未写入并返回完整 Markdown，供我手动保存。

        要拆出的需求：
        """
    }

    static func taskPrompt(savedAt file: URL) -> String {
        """
        请为当前对话整理一份供另一位 agent 接手的 Markdown 交接文档。只整理交接，不继续执行原任务。

        请写入以下绝对路径（含空格，使用时请正确引用）：
        \(file.standardizedFileURL.path)

        按需包含四部分，无关项可省略：
        1. 目标与边界：最新用户要求、完成标准、关键约束和已授权范围。
        2. 当前状态：已完成与未完成事项、实际验证结果、失败及未验证项，明确区分。
        3. 接续上下文：工作目录绝对路径、关键文件或产物、影响下一步的决策；代码任务另注明当前分支／提交及未提交改动。
        4. 下一步：按优先级列出可执行步骤、真实阻塞及仍需用户决定的问题。

        以接手后能直接继续为准，通常 500–1000 字，简单任务更短；不要为凑字数扩写，也不要为压缩遗漏关键约束。用当前事实和必要路径／命令／结果代替聊天复述，省略无关背景、废弃方案、长日志、原始对话和凭据。不确定的标“未确认”；不要把测试通过写成已部署或已验收。

        写完后只回复文件路径和一行摘要。如无法写文件，请说明未写入并返回完整 Markdown，供我手动保存。
        """
    }
}

extension HandoffStore {
    private var preparationFile: URL { directory.appendingPathComponent("pending.json") }

    public enum PreparationError: LocalizedError {
        case alreadyPending, missingDocument
        public var errorDescription: String? {
            switch self {
            case .alreadyPending: return "已有待继续的接力，请先完成或取消。"
            case .missingDocument: return "交接文档尚未生成。请先在源对话发送提示词，等文档写入后再继续；也可使用已有文档。"
            }
        }
    }

    public func pendingPreparation() throws -> HandoffPreparation? {
        guard FileManager.default.fileExists(atPath: preparationFile.path) else { return nil }
        return try JSONDecoder().decode(HandoffPreparation.self, from: Data(contentsOf: preparationFile))
    }

    /// Preserve an unreadable pending record so it cannot permanently block new preparations.
    @discardableResult
    public func archivePreparationState() throws -> URL {
        let backup = directory.appendingPathComponent("pending-unreadable-\(UUID().uuidString).json")
        try FileManager.default.moveItem(at: preparationFile, to: backup)
        return backup
    }

    /// Allocate a unique private directory, but never create a pretend handoff document.
    public func prepare(sourceID: String, targetID: String, conversationID: String, title: String,
                        scope: HandoffScope = .task) throws -> HandoffPreparation {
        guard try pendingPreparation() == nil else { throw PreparationError.alreadyPending }
        let preparation = HandoffPreparation(sourceID: sourceID, targetID: targetID, conversationID: conversationID,
                                             title: title, scope: scope)
        try Self.makePrivateDirectory(directory)
        try Self.makePrivateDirectory(directory.appendingPathComponent("drafts"))
        try Self.makePrivateDirectory(preparedURL(for: preparation).deletingLastPathComponent())
        try write(preparation)
        return preparation
    }

    /// Stores the saved copy and log record on the pending handoff, so a retry does not add another of either.
    public func recordAttempt(_ preparation: HandoffPreparation) throws {
        guard try pendingPreparation()?.id == preparation.id else { return }
        try write(preparation)
    }

    /// The copy an earlier attempt saved, when it is still in the handoff folder.
    public func savedCopy(_ preparation: HandoffPreparation) -> (url: URL, markdown: String)? {
        guard let path = preparation.documentPath else { return nil }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.deletingLastPathComponent() == directory.standardizedFileURL,
              let markdown = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return (url, markdown)
    }

    private func write(_ preparation: HandoffPreparation) throws {
        try JSONEncoder().encode(preparation).write(to: preparationFile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: preparationFile.path)
    }

    public func preparedURL(for preparation: HandoffPreparation) -> URL {
        directory.appendingPathComponent("drafts/\(preparation.id.uuidString)/handoff.md").standardizedFileURL
    }

    public func copyPreparedDocument(_ preparation: HandoffPreparation) throws -> (url: URL, markdown: String) {
        let file = preparedURL(for: preparation)
        guard FileManager.default.fileExists(atPath: file.path) else { throw PreparationError.missingDocument }
        return try copyDocument(file, fileName: HandoffDocument.fileName(title: preparation.title, at: Date()))
    }

    /// Cancellation removes the pending state only; any document remains available.
    public func clearPreparation(id: UUID) throws {
        guard try pendingPreparation()?.id == id else { return }
        try FileManager.default.removeItem(at: preparationFile)
    }
}
