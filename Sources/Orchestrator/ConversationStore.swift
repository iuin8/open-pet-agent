import Foundation

/// Persistent, actor-isolated conversation history store.
///
/// Writes are atomic (tmp-file + rename). Load failures trigger `.bak` recovery
/// without crashing the app. All public methods are safe to call from any
/// concurrency context.
public actor ConversationStore {

    // MARK: - Internal state

    private var envelope: ConversationEnvelope
    private let storeURL: URL

    // MARK: - Init

    /// Designated init used by tests (injects a hermetic store path).
    public init(storeURL: URL) {
        self.storeURL = storeURL
        self.envelope = ConversationEnvelope()
    }

    /// Convenience init that uses the default Application Support path.
    public init() {
        self.init(storeURL: Self.defaultStoreURL())
    }

    // MARK: - Default path

    /// `~/Library/Application Support/OpenPetAgent/conversations.json`
    public static func defaultStoreURL() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory

        return appSupport
            .appendingPathComponent("OpenPetAgent", isDirectory: true)
            .appendingPathComponent("conversations.json")
    }

    // MARK: - Public API

    /// Load persisted messages from disk.
    ///
    /// - If the file does not exist, the store silently starts empty.
    /// - If the JSON is corrupt, the file is renamed to `.bak` and the store
    ///   starts fresh. This method never throws in practice; the signature
    ///   keeps `throws` as a forward-compatible interface.
    public func load() async throws {
        guard FileManager.default.fileExists(atPath: storeURL.path) else {
            return
        }
        do {
            let data = try Data(contentsOf: storeURL)
            let decoded = try JSONDecoder().decode(ConversationEnvelope.self, from: data)
            envelope = decoded
        } catch {
            recoverFromCorruption(error: error)
        }
    }

    /// Append a message and immediately persist to disk.
    public func append(_ message: ConversationMessage) async {
        envelope.messages.append(message)
        do {
            try await persist()
        } catch {
            print("[ConversationStore] persist failed: \(error)")
        }
    }

    /// Return the current in-memory message list.
    public func messages() async -> [ConversationMessage] {
        envelope.messages
    }

    /// Remove all messages from memory and disk.
    public func clear() async {
        envelope = ConversationEnvelope(
            id: envelope.id,
            createdAt: envelope.createdAt,
            messages: []
        )
        do {
            try await persist()
        } catch {
            print("[ConversationStore] persist after clear failed: \(error)")
        }
    }

    /// Returns a rolling-window subset of messages that fits within the token budget.
    ///
    /// **Budget formula:**
    /// ```
    /// budget = max(0, modelContextWindow - reservedReplyTokens - reservedSystemTokens)
    /// ```
    ///
    /// **Pair-preservation rule:**
    /// Messages are collected in complete turns (one user message + zero or one following
    /// assistant message). Starting from the most recent turn and working backwards:
    /// - If the entire turn fits within the remaining budget, it is included.
    /// - If the turn does not fit (even partially), that turn and all older turns are dropped.
    ///
    /// This preserves conversation semantic integrity — no half-turns where the AI's reply
    /// exists without the preceding user question, or vice versa.
    ///
    /// System messages in history (not expected under normal operation) are treated as
    /// independent single-message units rather than forcing a crash.
    ///
    /// - Parameters:
    ///   - reservedReplyTokens: Tokens reserved for the AI's reply output. Default: 2048.
    ///   - reservedSystemTokens: Tokens reserved for the system prompt + context block. Default: 1024.
    ///   - modelContextWindow: Total context window size for the active model.
    /// - Returns: The most recent messages that fit within the budget, in chronological order
    ///   (oldest first), or an empty array when the budget is zero or no turns fit.
    public func truncatedMessages(
        reservedReplyTokens: Int,
        reservedSystemTokens: Int,
        modelContextWindow: Int
    ) async -> [ConversationMessage] {
        let budget = max(0, modelContextWindow - reservedReplyTokens - reservedSystemTokens)
        guard budget > 0, !envelope.messages.isEmpty else { return [] }
        return Self.applyRollingWindow(to: envelope.messages, budget: budget)
    }

    // MARK: - Token estimation

    /// Heuristic token estimator for a content string.
    ///
    /// CJK Unified Ideograph scalars (U+4E00–U+9FFF) count as 2 weighted units each;
    /// all other characters count as 1 weighted unit. The weighted sum is divided by 4
    /// (roughly matching GPT tokenisation) with a minimum of 1.
    ///
    /// Accuracy target: within 20% of actual token count for typical conversation content.
    /// Estimation is intentionally conservative (may overcount) to avoid context window overflow.
    internal static func estimateTokens(_ text: String) -> Int {
        var cjkCount = 0
        var restCount = 0
        for scalar in text.unicodeScalars {
            if scalar.value >= 0x4E00 && scalar.value <= 0x9FFF {
                cjkCount += 1
            } else {
                restCount += 1
            }
        }
        return (cjkCount * 2 + restCount) / 4 + 1
    }

    // MARK: - Private rolling-window implementation

    /// Applies the rolling-window pair-preservation algorithm.
    ///
    /// Traverses the message array from the end (newest) towards the start (oldest),
    /// collecting complete turns. A turn begins with a `user` message and may be followed
    /// by an `assistant` message. The turn is only included when its total token cost fits
    /// within the remaining budget.
    ///
    /// Collected turns are prepended into `kept` so the final output is in the original
    /// chronological order (oldest first).
    private static func applyRollingWindow(
        to messages: [ConversationMessage],
        budget: Int
    ) -> [ConversationMessage] {
        // `kept` accumulates accepted turns in chronological order (oldest first).
        // We build it by prepending each accepted turn as we scan newest → oldest.
        var kept: [ConversationMessage] = []
        var usedTokens = 0
        var index = messages.endIndex - 1

        while index >= messages.startIndex {
            // collectTurn returns the turn in chronological order: [user, assistant] or [single].
            // `consumed` is how many messages from the end the turn occupies.
            let (turn, consumed) = collectTurn(from: messages, endingAt: index)
            let turnTokens = turn.reduce(0) { $0 + estimateTokens($1.content) }

            if usedTokens + turnTokens <= budget {
                // Prepend this (older) turn before previously accepted (newer) turns.
                kept = turn + kept
                usedTokens += turnTokens
                index -= consumed
            } else {
                // Turn doesn't fit; stop — all older turns cost even more tokens.
                break
            }
        }

        return kept
    }

    /// Collects one complete turn ending at `endingAt` (inclusive, 0-based index).
    ///
    /// A turn is:
    /// - `assistant` at end + preceding `user`: a complete two-message turn.
    ///   Returns `([user, assistant], consumed: 2)`.
    /// - `user` at end (partial turn, no reply yet): a single-message turn.
    ///   Returns `([user], consumed: 1)`.
    /// - Any other role (`system` or unexpected): a single-message independent unit.
    ///   Returns `([message], consumed: 1)`.
    /// - Orphaned `assistant` (no preceding `user`): single-message independent unit.
    ///   Returns `([assistant], consumed: 1)`.
    ///
    /// - Returns: A tuple of (chronological messages in this turn, count consumed from end).
    private static func collectTurn(
        from messages: [ConversationMessage],
        endingAt index: Int
    ) -> (turn: [ConversationMessage], consumed: Int) {
        let current = messages[index]

        switch current.role {
        case .assistant:
            // Look for the immediately preceding user message.
            if index > messages.startIndex {
                let prev = messages[index - 1]
                if prev.role == .user {
                    // Complete turn in chronological order: user → assistant
                    return ([prev, current], 2)
                }
            }
            // Orphaned assistant (no preceding user) → independent unit.
            return ([current], 1)

        case .user:
            // Partial turn (awaiting reply, or start of history).
            return ([current], 1)

        default:
            // Defensive: system or unexpected role → independent single-message unit.
            return ([current], 1)
        }
    }

    // MARK: - Private helpers

    /// Atomic write: encode → tmp file → rename over target.
    private func persist() async throws {
        let dir = storeURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(envelope)
        let tmpURL = dir.appendingPathComponent(storeURL.lastPathComponent + ".tmp")
        try data.write(to: tmpURL, options: .atomic)

        // Atomic rename: remove target first (moveItem doesn't overwrite),
        // then rename tmp → target. On the same volume this is a POSIX rename(2).
        if FileManager.default.fileExists(atPath: storeURL.path) {
            _ = try FileManager.default.replaceItemAt(storeURL, withItemAt: tmpURL)
        } else {
            try FileManager.default.moveItem(at: tmpURL, to: storeURL)
        }
    }

    /// Rename the damaged file to `.bak`, then reset to an empty envelope.
    private func recoverFromCorruption(error: Error) {
        print("[ConversationStore] decode failed, recovering: \(error)")
        let bakURL = storeURL.deletingLastPathComponent()
            .appendingPathComponent(
                storeURL.deletingPathExtension().lastPathComponent + ".bak"
            )
        // Overwrite any existing .bak
        if FileManager.default.fileExists(atPath: bakURL.path) {
            try? FileManager.default.removeItem(at: bakURL)
        }
        try? FileManager.default.moveItem(at: storeURL, to: bakURL)
        envelope = ConversationEnvelope()
    }
}
