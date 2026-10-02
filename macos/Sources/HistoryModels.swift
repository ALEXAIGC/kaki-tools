import Foundation

struct ImageDimensions: Codable, Equatable {
    var width: Int
    var height: Int
}

struct HistoryItem: Identifiable, Codable, Equatable {
    var id: String
    var type: String
    var text: String?
    var html: String?
    var rtf: String?
    var rtfData: Data? // Raw RTF bytes; Codable stores base64 without transcoding.
    var createdAt: Double
    var pinned: Bool
    var board: String?
    var tags: [String]?
    var note: String?
    var file: String?
    var thumb: String?
    var hash: String?
    var size: ImageDimensions?
    var bytes: Int?

    init(id: String = UUID().uuidString.lowercased(), type: String = "text", text: String? = nil,
         html: String? = nil, rtf: String? = nil, rtfData: Data? = nil, createdAt: Double = Date().timeIntervalSince1970 * 1000,
         pinned: Bool = false, board: String? = nil, tags: [String]? = nil, note: String? = nil,
         file: String? = nil, thumb: String? = nil, hash: String? = nil, size: ImageDimensions? = nil, bytes: Int? = nil) {
        self.id = id; self.type = type; self.text = text; self.html = html; self.rtf = rtf; self.rtfData = rtfData
        self.createdAt = createdAt; self.pinned = pinned; self.board = board; self.tags = tags; self.note = note
        self.file = file; self.thumb = thumb; self.hash = hash; self.size = size; self.bytes = bytes
    }

    var hasRichText: Bool { html != nil || rtf != nil || rtfData != nil }

    private enum CodingKeys: String, CodingKey {
        case id, type, text, html, rtf, rtfData, createdAt, pinned, board, tags, note, file, thumb, hash, size, bytes
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        type = try c.decode(String.self, forKey: .type)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        html = try c.decodeIfPresent(String.self, forKey: .html)
        rtf = try c.decodeIfPresent(String.self, forKey: .rtf)
        rtfData = try c.decodeIfPresent(Data.self, forKey: .rtfData)
        createdAt = try c.decodeIfPresent(Double.self, forKey: .createdAt) ?? 0
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        board = try c.decodeIfPresent(String.self, forKey: .board)
        tags = try c.decodeIfPresent([String].self, forKey: .tags)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        file = try c.decodeIfPresent(String.self, forKey: .file)
        thumb = try c.decodeIfPresent(String.self, forKey: .thumb)
        hash = try c.decodeIfPresent(String.self, forKey: .hash)
        size = try c.decodeIfPresent(ImageDimensions.self, forKey: .size)
        bytes = try c.decodeIfPresent(Int.self, forKey: .bytes)
    }
}
