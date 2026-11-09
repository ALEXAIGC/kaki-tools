import Foundation
import ImageIO

// Tokens are kept separate from Seedance. Help detection advertises only installed capabilities.
enum ClassicImageModels {
    static let versions = ["4.0", "4.1", "4.5", "4.6", "4.7", "5.0", "5.0Pro"]
    static let supported = versions.map { "seedream-" + $0 }
    static let aspects = ["1:1", "3:4", "4:3", "16:9", "9:16", "3:2", "2:3", "21:9"]
    static func contains(_ model: String) -> Bool { supported.contains(model) }
    static func title(_ model: String) -> String { "Seedream " + String(model.dropFirst(9)) }
    static func validate(_ snapshot: ClassicVideoSnapshot) throws {
        let refs = snapshot.references ?? []
        guard contains(snapshot.model), snapshot.profile == "resolution-five",
              !snapshot.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, snapshot.prompt.count <= 10000,
              snapshot.duration == 0, snapshot.transitions?.isEmpty != false,
              ["2k", "4k"].contains(snapshot.resolution), aspects.contains(snapshot.aspect),
              snapshot.effectiveMode == (refs.isEmpty ? "text2image" : "image2image"),
              refs.count <= 10, Set(refs.map(\.nodeId)).count == refs.count,
              refs.allSatisfy({ $0.kind == "image" && !$0.nodeId.isEmpty && $0.bytes > 0 && $0.bytes <= 30 * 1024 * 1024 && ["png","jpg","jpeg","webp"].contains($0.extension) && $0.mediaType.hasPrefix("image/") && $0.sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil && $0.source.range(of: "^/api/private-files/[a-f0-9-]{36}\\.[a-z0-9]{1,5}$", options: .regularExpression) != nil }) else { throw DreaminaError.invalidResponse }
    }
    static func arguments(_ snapshot: ClassicVideoSnapshot, files: [URL]) throws -> [String] {
        try validate(snapshot)
        guard files.count == (snapshot.references ?? []).count, files.allSatisfy({ $0.isFileURL && !$0.path.contains(",") && !$0.path.contains("\n") && !$0.path.contains("\0") }) else { throw DreaminaError.invalidResponse }
        var arguments = [snapshot.effectiveMode, "--prompt", snapshot.prompt, "--model_version", String(snapshot.model.dropFirst(9)), "--resolution_type", snapshot.resolution, "--ratio", snapshot.aspect, "--generate_num", "1", "--poll", "0"]
        if !files.isEmpty { arguments += ["--images", files.map(\.path).joined(separator: ",")] }
        return arguments
    }
    static func detected(textHelp: DreaminaOutput, imageHelp: DreaminaOutput) -> [String] {
        var available = Set(versions)
        for (output, referenceFlag) in [(textHelp, false), (imageHelp, true)] {
            let text = String(decoding: output.data, as: UTF8.self)
            let required = ["--prompt", "--model_version", "--resolution_type", "--ratio", "--generate_num", "--poll", "2k", "4k"] + (referenceFlag ? ["--images"] : [])
            guard output.status == 0, output.data.count < 128000, required.allSatisfy(text.contains) else { return [] }
            let tokens = Set(text.components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".")).inverted))
            available.formIntersection(tokens)
        }
        return versions.filter(available.contains).map { "seedream-" + $0 }
    }
    static func validateResult(_ file: URL) throws {
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 30 * 1024 * 1024,
              let source = CGImageSourceCreateWithURL(file as CFURL, nil), CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber, let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.intValue > 0, height.intValue > 0, width.intValue <= 16384, height.intValue <= 16384,
              Int64(width.intValue) * Int64(height.intValue) <= 64_000_000,
              CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) != nil else { throw DreaminaError.invalidResponse }
    }
    static func contentType(_ file: URL) throws -> String {
        switch file.pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "webp": return "image/webp"
        default: throw DreaminaError.invalidResponse
        }
    }
}
