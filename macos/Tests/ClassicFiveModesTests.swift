import Foundation
import CryptoKit

private actor ReferenceTransportFixture: StudioTransport {
    let bytes: Data
    var redirected = false
    var requests: [URLRequest] = []
    init(bytes: Data, redirected: Bool = false) {self.bytes = bytes; self.redirected = redirected}
    func recorded() -> [URLRequest] {requests}
    func perform(_ request: URLRequest, maximumBytes: Int64) async throws -> StudioHTTPFile {
        requests.append(request)
        guard bytes.count <= maximumBytes else {throw StudioError.tooLarge}
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try bytes.write(to: file)
        return StudioHTTPFile(file:file,response:HTTPURLResponse(url:redirected ? URL(string:"https://foreign.invalid/ref")! : request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"image/png"])!)
    }
}
private actor PreparationBridgeFixture: ClassicCliBridge {
    let files: [URL]
    let failing: Bool
    var events: [String] = []
    init(files: [URL] = [], failing: Bool = false) {self.files = files; self.failing = failing}
    func recorded() -> [String] {events}
    func prepareReferences(task: ClassicVideoTask, directory: URL) async throws -> [URL] {
        if failing {throw StudioError.invalidResponse}
        return try files.enumerated().map {index,file in
            let target=directory.appendingPathComponent("reference-" + String(index) + "." + file.pathExtension)
            try FileManager.default.copyItem(at:file,to:target)
            return target
        }
    }
    func event(task: ClassicVideoTask, event: String, submitId: String?) async throws {events.append(event)}
    func upload(task: ClassicVideoTask, submitId: String, file: URL) async throws {}
}
private actor ConfirmationFixture {var count = 0; func approve() -> Bool {count += 1; return true}; func value() -> Int {count}}

func runClassicFiveModesTests() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("classic-five-" + UUID().uuidString)
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    defer {try? FileManager.default.removeItem(at:root)}
    let image = Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a3YQAAAAASUVORK5CYII=")!
    let sha = SHA256.hash(data:image).map {String(format:"%02x",$0)}.joined()
    func ref(_ i: Int) -> ClassicCliReference {ClassicCliReference(nodeId:"node-\(i)",kind:"image",source:"/api/private-files/00000000-0000-4000-8000-000000000001.png",sha256:sha,bytes:image.count,mediaType:"image/png",extension:"png",duration:nil)}
    let files = (0..<3).map {root.appendingPathComponent("image-\($0).png")}
    for file in files {try image.write(to:file)}
    for (mode,count,command) in [("text",0,"text2video"),("image",1,"image2video"),("firstlast",2,"frames2video"),("imageref",3,"multiframe2video"),("omni",1,"multimodal2video")] {
        let snapshot = ClassicVideoSnapshot(prompt:"literal ; $(never)",model:mode == "imageref" ? "dreamina-multiframe" : "seedance2.0fast",duration:mode == "imageref" ? 6 : 5,aspect:["image","firstlast","imageref"].contains(mode) ? "source" : "16:9",resolution:mode == "imageref" ? "1080p" : "720p",mode:mode,profile:"resolution-five",references:(0..<count).map(ref),transitions:mode == "imageref" ? [ClassicCliTransition(prompt:"first → second",duration:2),ClassicCliTransition(prompt:"second → third",duration:4)] : nil)
        let review = ClassicCliConfirmation.text(snapshot)
        try check(!review.contains("node-") && !review.contains("方式：" + mode),"confirmation shows Chinese mode and no internal IDs")
        if mode == "imageref" {try check(review.contains("first → second") && review.contains("second → third") && review.contains("2段过渡") && !review.contains(snapshot.prompt),"confirmation previews actual N-1 prompts instead of unused top prompt")}
        if mode == "firstlast" {try check(review.contains("首帧 → 尾帧"),"confirmation preserves first/last roles")}
        let args = try ClassicDreaminaCLI.arguments(snapshot,files:Array(files.prefix(count)))
        try check(args[0] == command && args.suffix(2) == ["--poll","0"],"five-mode fixed actual command/poll")
        if ["image","firstlast"].contains(mode) {try check(!args.contains("--ratio"),"single/frames source aspect without invented ratio")}
        if mode == "firstlast" {try check(args[2] == files[0].path && args[4] == files[1].path,"frozen first/last ordering")}
        if mode == "imageref" {
            try check(!args.contains("--model_version") && args.contains("1080p"),"new multiframe real resolution/fixed model")
            try check(args.filter {$0 == "--transition-prompt"}.count == 2 && args.contains("first → second") && args.contains("second → third"),"N-1 descriptions retained")
            var old = snapshot; old.profile = "legacy-five"
            // Construct the old fixed-resolution contract explicitly.
            old = ClassicVideoSnapshot(prompt:old.prompt,model:old.model,duration:old.duration,aspect:old.aspect,resolution:"default",mode:old.mode,profile:old.profile,references:old.references,transitions:old.transitions)
            let oldArgs = try ClassicDreaminaCLI.arguments(old,files:files)
            try check(!oldArgs.contains("--video_resolution"),"old multiframe has no unsupported resolution flag")
        }
        let runner = ClassicFixtureRunner(), cli = ClassicDreaminaCLI(runner:runner)
        let task = ClassicVideoTask(id:mode,projectId:"project",nodeId:"target",payloadHash:String(repeating:"a",count:64),snapshot:snapshot,stage:"awaiting-confirmation",submitId:nil)
        let bridge = PreparationBridgeFixture(files:Array(files.prefix(count)))
        let executor = ClassicCliExecutor(cli:cli,directory:root.appendingPathComponent(mode))
        try await executor.step(task:task,owner:"same-owner",bridge:bridge,authorize:{true},isCurrent:{true},validateVideo:{_ in})
        try await executor.step(task:task,owner:"same-owner",bridge:bridge,authorize:{throw StudioError.invalidResponse},isCurrent:{true},validateVideo:{_ in})
        let calls = await runner.allCalls()
        try check(calls.filter {$0.first == command}.count == 1,"every mode uploads/reenters without second submission")
    }
    let snapshot = ClassicVideoSnapshot(prompt:"test",model:"seedance2.0",duration:5,aspect:"source",resolution:"720p",mode:"image",profile:"resolution-five",references:[ref(0)])
    let task = ClassicVideoTask(id:"bad-reference",projectId:"project",nodeId:"target",payloadHash:String(repeating:"b",count:64),snapshot:snapshot,stage:"awaiting-confirmation",submitId:nil)
    let bad = PreparationBridgeFixture(failing:true), consent = ConfirmationFixture(), runner = ClassicFixtureRunner()
    let executor = ClassicCliExecutor(cli:ClassicDreaminaCLI(runner:runner),directory:root.appendingPathComponent("prepare"))
    for _ in 0..<2 {try await executor.step(task:task,owner:"same",bridge:bad,authorize:{await consent.approve()},isCurrent:{true},validateVideo:{_ in})}
    let confirmations = await consent.value(), paidCalls = await runner.allCalls(), events = await bad.recorded()
    try check(confirmations == 0,"failed reference never repeatedly prompts personal-credit confirmation")
    try check(paidCalls.isEmpty,"failed preparation never spawns paid CLI")
    try check(events == ["preparation-failed","preparation-failed"],"terminal preparation failure retries only its receipt")
    let remains = try FileManager.default.contentsOfDirectory(atPath:root.appendingPathComponent("prepare").path)
    try check(!remains.contains {$0.contains("-input-")},"failed preparation removes private inputs")
    let transport = ReferenceTransportFixture(bytes:image)
    let bridge = ClassicStudioBridge(client:StudioClient(environment:.test,transport:transport),session:StudioSession(value:"fixture",expiresAt:Date().addingTimeInterval(600)),workspace:"fixture-workspace",device:ClassicCliDevice(id:"fixture-device",epoch:"fixture-epoch",secret:"fixture-secret"),current:{true})
    let inputs = root.appendingPathComponent("download")
    try FileManager.default.createDirectory(at:inputs,withIntermediateDirectories:false)
    let downloaded = try await bridge.prepareReferences(task:task,directory:inputs)
    let downloadedBytes = try Data(contentsOf:downloaded[0])
    try check(downloaded.count == 1 && downloadedBytes == image,"real image decoder/hash/protected download")
    let request = await transport.recorded()[0]
    try check(request.url?.host == StudioEnvironment.test.baseURL.host && request.url?.path == "/api/local-cli/tasks/bad-reference/references/0" && request.value(forHTTPHeaderField:"X-Workspace-Id") == "fixture-workspace","protected download stays owner/environment/workspace bound")
    let redirected = ReferenceTransportFixture(bytes:image,redirected:true)
    let wrong = ClassicStudioBridge(client:StudioClient(environment:.test,transport:redirected),session:bridge.session,workspace:bridge.workspace,device:bridge.device,current:{true})
    do {_ = try await wrong.prepareReferences(task:task,directory:inputs);throw NativeTestFailure(description:"redirect must fail")} catch StudioError.invalidResponse {}
    let fixtureRoot = URL(fileURLWithPath:#filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
    var mixed = [ref(0)], mixedFiles = [files[0]]
    for (kind,ext,type) in [("video","mp4","video/mp4"),("audio","wav","audio/wav")] {
        let file = fixtureRoot.appendingPathComponent("classic-reference-" + kind + "." + ext), bytes = try Data(contentsOf:file)
        let reference = ClassicCliReference(nodeId:kind,kind:kind,source:"/api/private-files/00000000-0000-4000-8000-000000000002." + ext,sha256:SHA256.hash(data:bytes).map {String(format:"%02x",$0)}.joined(),bytes:bytes.count,mediaType:type,extension:ext,duration:3)
        try await ClassicStudioBridge.validateReference(file,reference:reference)
        mixed.append(reference);mixedFiles.append(file)
    }
    let mixedSnapshot = ClassicVideoSnapshot(prompt:"use all three",model:"seedance2.0fast",duration:5,aspect:"16:9",resolution:"720p",mode:"omni",profile:"resolution-five",references:mixed)
    let mixedArgs = try ClassicDreaminaCLI.arguments(mixedSnapshot,files:mixedFiles)
    try check(mixedArgs[1...6] == ["--image",files[0].path,"--video",mixedFiles[1].path,"--audio",mixedFiles[2].path],"mixed actual decoded media retains each type and frozen order")
    var excessive = mixedSnapshot; excessive.references = [mixed[0],mixed[1],mixed[1],mixed[1],mixed[1]]
    do {try excessive.validate();throw NativeTestFailure(description:"excess media must fail")} catch DreaminaError.invalidResponse {}
    let failureTransport = ReferenceTransportFixture(bytes:Data("not a binary".utf8))
    do {_ = try await ClassicCliInstaller(directory:root.appendingPathComponent("install-failed"),transport:failureTransport).install();throw NativeTestFailure(description:"invalid installer must fail")} catch DreaminaError.invalidResponse {}
    try check(!FileManager.default.fileExists(atPath:root.appendingPathComponent("install-failed/dreamina").path),"failed install creates no executable")
    if let path = ProcessInfo.processInfo.environment["KAKI_CLI_INSTALL_QA_DIR"] {
        let installation = try await ClassicCliInstaller(directory:URL(fileURLWithPath:path)).install()
        let receipt: [String: String] = ["executable":installation.executable.path,"version":installation.version,"contentSha256":installation.sha256,"authenticity":"fixed official HTTPS; vendor checksum absent"]
        try JSONSerialization.data(withJSONObject:receipt,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:path).appendingPathComponent("inspection.json"))
        let preserved = try await ClassicCliInstaller(directory:URL(fileURLWithPath:path),transport:failureTransport).install()
        try check(preserved.sha256 == installation.sha256,"existing valid installation is inspected and never overwritten")
        let profile = try await ClassicDreaminaCLI(runner:DreaminaProcessRunner(executable:installation.executable)).detectedProfile()
        try check(profile == "resolution-five","real official ARM binary five-mode profile detected")
    }
}
