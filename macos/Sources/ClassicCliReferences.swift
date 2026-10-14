import Foundation
import CryptoKit
import ImageIO
import AVFoundation

private enum ClassicReferenceTransferError: Error { case unverifiedResponse }

extension ClassicStudioBridge {
    func prepareReferences(task: ClassicVideoTask, directory: URL) async throws -> [URL] {
        var files: [URL] = []
        for (index, reference) in (task.snapshot.references ?? []).enumerated() {
            guard await current(), ClassicDreaminaCLI.validID(task.id) else {throw DreaminaError.wrongOwner}
            var request = client.request(path: "api/local-cli/tasks/" + task.id + "/references/" + String(index), session: session, workspace: workspace)
            request.setValue(device.id, forHTTPHeaderField: "X-Local-CLI-Device")
            request.setValue(device.secret, forHTTPHeaderField: "X-Local-CLI-Secret")
            let response: StudioHTTPFile
            do { response = try await client.transport.perform(request, maximumBytes: Int64(reference.bytes)) }
            catch StudioError.tooLarge { throw ClassicReferenceTransferError.unverifiedResponse }
            catch StudioError.invalidResponse { throw ClassicReferenceTransferError.unverifiedResponse }
            defer {try? FileManager.default.removeItem(at: response.file)}
            guard await current() else { throw DreaminaError.wrongOwner }
            guard response.response.url == request.url else { throw StudioError.invalidResponse }
            // Preserve HTTP identity/temporary failures for retry classification;
            // a 5xx HTML response must not permanently fail valid reference media.
            guard response.response.statusCode == 200 else { throw StudioError.mediaHTTP(response.response.statusCode) }
            guard response.response.mimeType == reference.mediaType.split(separator: ";").first.map(String.init) else { throw StudioError.invalidResponse }
            let bytes = try Data(contentsOf: response.file, options: .mappedIfSafe)
            guard bytes.count == reference.bytes, SHA256.hash(data: bytes).map({String(format: "%02x", $0)}).joined() == reference.sha256,
                  ["png", "jpg", "jpeg", "webp", "mp4", "mov", "webm", "mp3", "wav", "m4a", "aac", "flac", "ogg"].contains(reference.extension) else {throw StudioError.invalidResponse}
            let file = directory.appendingPathComponent("reference-" + String(index) + "." + reference.extension)
            try bytes.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            try await Self.validateReference(file, reference: reference, maximumDuration: task.snapshot.model == "seedance2.5" ? 30 : 15)
            files.append(file)
        }
        return files
    }
    nonisolated static func validateReference(_ file: URL, reference: ClassicCliReference, maximumDuration: Double = 15) async throws {
        if reference.kind == "image" {
            guard let source = CGImageSourceCreateWithURL(file as CFURL, nil), CGImageSourceGetCount(source) == 1,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? NSNumber, let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
                  width.intValue > 0, height.intValue > 0, width.intValue <= 16384, height.intValue <= 16384,
                  Int64(width.intValue) * Int64(height.intValue) <= 64_000_000,
                  CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) != nil else {throw StudioError.invalidResponse}
        } else {
            do {
                let asset = AVURLAsset(url: file), duration = try await asset.load(.duration).seconds
                let tracks = try await asset.loadTracks(withMediaType: reference.kind == "video" ? .video : .audio)
                guard !tracks.isEmpty, duration.isFinite, duration >= 2, duration <= maximumDuration, let expected = reference.duration, abs(expected - duration) < 0.1 else {throw StudioError.invalidResponse}
            } catch {
                try Task.checkCancellation()
                if (error as NSError).domain == AVFoundationErrorDomain { throw StudioError.invalidResponse }
                throw error
            }
        }
    }
}
