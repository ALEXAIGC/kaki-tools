import Foundation

// Public protocol only: no credential fields and no task mutation.
struct ClassicCliPublicDevice: Codable, Equatable, Sendable {
    let id: String
    let epoch: String
    let models: [String]
    let revision: Int?
    let profile: String?
    var effectiveRevision: Int { revision ?? 0 }
    func validate(for device: ClassicCliDevice, minimumRevision: Int = 0) throws {
        let allowed = Set(ClassicVideoModels.supported + ["dreamina-multiframe"])
        guard id == device.id, epoch == device.epoch,
              effectiveRevision >= minimumRevision, effectiveRevision <= 9_007_199_254_740_991,
              !models.isEmpty, models.count <= 7, Set(models).count == models.count,
              Set(models).isSubset(of: allowed) else { throw DreaminaError.wrongOwner }
    }
}
struct ClassicCliCapabilityPayload: Codable, Equatable, Sendable {
    let expectedRevision: Int
    let profile: String
    let models: [String]
    init(current: ClassicCliPublicDevice, models: [String]) throws {
        guard current.effectiveRevision >= 0, current.effectiveRevision < 9_007_199_254_740_991 else { throw DreaminaError.invalidResponse }
        let sorted = Array(Set(models)).sorted()
        guard !sorted.isEmpty, sorted.count <= 7,
              Set(sorted).isSubset(of: Set(ClassicVideoModels.supported + ["dreamina-multiframe"])) else { throw DreaminaError.invalidResponse }
        expectedRevision = current.effectiveRevision; profile = "resolution-five"; self.models = sorted
    }
    func validateReceipt(_ receipt: ClassicCliPublicDevice, device: ClassicCliDevice) throws {
        try receipt.validate(for: device, minimumRevision: expectedRevision)
        guard receipt.profile == profile, Set(receipt.models) == Set(models),
              receipt.effectiveRevision == expectedRevision || receipt.effectiveRevision == expectedRevision + 1 else { throw DreaminaError.invalidResponse }
    }
}
struct ClassicCliCapabilityPreview: Sendable {
    let current: ClassicCliPublicDevice
    let payload: ClassicCliCapabilityPayload
    let retry: Bool
    var added: [String] { payload.models.filter { !current.models.contains($0) } }
    var removed: [String] { current.models.filter { !payload.models.contains($0) }.sorted() }
}
