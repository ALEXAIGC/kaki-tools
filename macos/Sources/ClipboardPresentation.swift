import Foundation

// Display work never rewrites the retained or copied clipboard content.
struct ClipboardTextPresentation: Sendable {
    let summary: String
    let utf16Count: Int
    init(_ text: String) {
        summary = Self.summary(text)
        utf16Count = text.utf16.count
    }
    static func summary(_ text: String, limit: Int = 160, scanLimit: Int? = nil) -> String {
        guard limit > 0 else { return "" }
        var result = "", count = 0, scanned = 0, space = false
        for character in text {
            if let scanLimit, scanned >= scanLimit { break }
            scanned += 1
            if character.isWhitespace { space = !result.isEmpty; continue }
            if space {
                result.append(" "); count += 1; space = false
                if count == limit { break }
            }
            result.append(character); count += 1
            if count == limit { break }
        }
        return result
    }
}

final class ClipboardSearchCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

struct ClipboardFocusContext {
    private(set) var externalPID: Int32?
    private(set) var revision = 0
    mutating func enter(frontPID: Int32?, ownPID: Int32) {
        guard frontPID != ownPID else { return }
        externalPID = frontPID; revision += 1
    }
}
