import Foundation

struct StudioMaterialReference: Codable, Equatable {
    let source: String
    let id: String
    let workspaceId: String?
}
struct StudioReferenceEnvelope: Codable, Equatable {
    static let prefix = "KAKI_MATERIALS_V1\n"
    static let maximumItems = 20
    let version: Int
    let origin: String
    let items: [StudioMaterialReference]
    func clipboardText() throws -> String {
        guard version == 1, !items.isEmpty, items.count <= Self.maximumItems,
              StudioEnvironment.allCases.contains(where: { $0.baseURL.absoluteString == origin }),
              items.allSatisfy({ ["asset", "job"].contains($0.source) && !$0.id.isEmpty && $0.id.count <= 200 }) else { throw StudioError.invalidResponse }
        let data = try JSONEncoder().encode(self)
        guard data.count <= 65536, let text = String(data: data, encoding: .utf8) else { throw StudioError.invalidResponse }
        return Self.prefix + text
    }
}

// Selection order is stable across background refreshes. Shift ranges follow display order.
struct StudioSelection {
    private(set) var ids: [String] = []
    private var anchor: String?
    mutating func reconcile(_ visible: [String]) {
        let available = Set(visible)
        ids.removeAll { !available.contains($0) }
        if anchor.map({ !available.contains($0) }) == true { anchor = nil }
        if ids.isEmpty, let first = visible.first { ids = [first]; anchor = first }
    }
    mutating func clear() { ids = []; anchor = nil }
    @discardableResult mutating func select(_ id: String, visible: [String], toggle: Bool, range: Bool) -> Bool {
        guard visible.contains(id) else { return false }
        var candidate = ids
        if range, let anchor, let start = visible.firstIndex(of: anchor), let end = visible.firstIndex(of: id) {
            let span = Array(visible[min(start, end)...max(start, end)])
            candidate = toggle ? ids + span.filter { !ids.contains($0) } : span
        } else if toggle {
            if candidate.contains(id) { candidate.removeAll { $0 == id } } else { candidate.append(id) }
        } else { candidate = [id] }
        guard candidate.count <= StudioReferenceEnvelope.maximumItems else { return false }
        ids = candidate
        if !range { anchor = id }
        return true
    }
    var primary: String? { ids.last }
}
