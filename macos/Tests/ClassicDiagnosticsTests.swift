import Foundation

private actor CreditFixture: DreaminaRunning {
    let output: DreaminaOutput
    let submitFails: Bool
    let delegate=ClassicFixtureRunner()
    var calls: [[String]]=[]
    init(_ data: String,status:Int32=0,submitFails:Bool=false) {output=DreaminaOutput(status:status,data:Data(data.utf8));self.submitFails=submitFails}
    func allCalls()->[[String]] {calls}
    func run(_ arguments:[String],timeout:TimeInterval) async throws->DreaminaOutput {
        calls.append(arguments)
        if arguments == ["user_credit"] {
            if output.status == -1 {throw DreaminaError.timedOut}
            return output
        }
        if submitFails && arguments.first == "text2video" {return DreaminaOutput(status:1,data:Data("insufficient credits private-upstream-detail".utf8))}
        return try await delegate.run(arguments,timeout:timeout)
    }
}
private actor DiagnosticBridge: ClassicCliBridge {
    var records:[String]=[]
    var loseFailure=false
    func loseNextFailure() {loseFailure=true}
    func values()->[String] {records}
    func event(task:ClassicVideoTask,event:String,submitId:String?) async throws {records.append(event)}
    func failure(task:ClassicVideoTask,event:String,code:String) async throws {records.append(event+":"+code);if loseFailure {loseFailure=false;throw DreaminaError.timedOut}}
    func upload(task:ClassicVideoTask,submitId:String,file:URL) async throws {records.append("upload")}
}
func runClassicDiagnosticsTests() async throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("classic-diagnostics-"+UUID().uuidString)
    defer {try? FileManager.default.removeItem(at:root)}
    let snapshot=ClassicVideoSnapshot(prompt:"test",model:"seedance2.0",duration:5,aspect:"16:9",resolution:"720p",mode:"text",profile:"resolution-five")
    // An already authorized task must not be blocked by an unreliable budget query.
    for (i,item) in [("{\"total_credit\":0,\"user_id\":0,\"user_name\":\"\",\"vip_level\":\"\"}",Int32(0)),("{}",0),("{\"total_credit\":true,\"user_id\":\"fixture-account\"}",0),("network unavailable",1),("timeout",-1)].enumerated() {
        let runner=CreditFixture(item.0,status:item.1),bridge=DiagnosticBridge(),dir=root.appendingPathComponent(String(i)),cli=ClassicDreaminaCLI(runner:runner)
        do {_ = try await cli.loginState();throw NativeTestFailure(description:"empty identity or invalid response verified as logged in")} catch DreaminaError.invalidResponse {} catch DreaminaError.timedOut {}
        let executor=ClassicCliExecutor(cli:cli,directory:dir)
        let task=ClassicVideoTask(id:"credit",projectId:"project",nodeId:"node",payloadHash:String(repeating:"a",count:64),snapshot:snapshot,stage:"awaiting-confirmation",submitId:nil)
        try await executor.step(task:task,owner:"owner",bridge:bridge,isCurrent:{true},validateVideo:{_ in})
        try await executor.step(task:task,owner:"owner",bridge:bridge,isCurrent:{true},validateVideo:{_ in})
        let calls=await runner.allCalls(),records=await bridge.values()
        try check(calls.filter {$0 == ["user_credit"]}.count == 1 && calls.filter {$0.first == "text2video"}.count == 1,"budget uncertainty never adds a preflight or replays an authorized submission")
        try check(records == ["dispatch-intent","submitted","upload-ready","upload"],"empty identity/invalid budget cannot become an insufficient-credit failure")
        let journal=try JSONDecoder().decode(ClassicCliJournal.self,from:Data(contentsOf:dir.appendingPathComponent("credit.json")))
        try check(journal.stage == "completed" && journal.failureCode == nil,"authorized task follows its real submit result despite unknown budget")
    }
    for data in ["{\"total_credit\":0,\"user_id\":\"fixture-account\"}","{\"total_credit\":0,\"user_id\":42,\"vip_level\":\"\"}"] {
        let runner=CreditFixture(data),cli=ClassicDreaminaCLI(runner:runner)
        let loggedIn=try await cli.loginState();try check(loggedIn,"valid identity with zero credits is logged in; VIP/name is not required")
        let bridge=DiagnosticBridge(),executor=ClassicCliExecutor(cli:cli,directory:root.appendingPathComponent(UUID().uuidString))
        let task=ClassicVideoTask(id:"zero",projectId:"project",nodeId:"node",payloadHash:String(repeating:"a",count:64),snapshot:snapshot,stage:"awaiting-confirmation",submitId:nil)
        try await executor.step(task:task,owner:"owner",bridge:bridge,isCurrent:{true},validateVideo:{_ in})
        let calls=await runner.allCalls();try check(calls.filter {$0.first == "text2video"}.count == 1,"even an apparent genuine zero is not a client-side budget rejection")
    }
    let loggedOut=ClassicDreaminaCLI(runner:CreditFixture("未检测到有效登录态，请先执行 dreamina login",status:1))
    let loggedOutState=try await loggedOut.loginState();try check(!loggedOutState,"explicit missing login remains logged out")
    let insufficient=CreditFixture("{\"total_credit\":0}",submitFails:true),insufficientBridge=DiagnosticBridge(),insufficientDir=root.appendingPathComponent("actual-insufficient")
    let insufficientTask=ClassicVideoTask(id:"insufficient",projectId:"project",nodeId:"node",payloadHash:String(repeating:"c",count:64),snapshot:snapshot,stage:"awaiting-confirmation",submitId:nil)
    for _ in 0..<2 {try await ClassicCliExecutor(cli:ClassicDreaminaCLI(runner:insufficient),directory:insufficientDir).step(task:insufficientTask,owner:"owner",bridge:insufficientBridge,isCurrent:{true},validateVideo:{_ in})}
    let insufficientCalls=await insufficient.allCalls(),insufficientRecords=await insufficientBridge.values()
    try check(insufficientCalls.filter {$0.first == "text2video"}.count == 1 && !insufficientCalls.contains(["user_credit"]),"actual submission credit rejection is diagnosed once without a budget preflight/replay")
    try check(insufficientRecords == ["dispatch-intent","unknown:insufficient-credits","unknown:insufficient-credits"],"actual CLI insufficient-credit error stays safe UNKNOWN with its precise reason")
    let lostRunner=ClassicFixtureRunner(),lostBridge=DiagnosticBridge(),lostDir=root.appendingPathComponent("lost-failure")
    await lostRunner.configure(timeout:true);await lostBridge.loseNextFailure()
    let lostTask=ClassicVideoTask(id:"lost",projectId:"project",nodeId:"node",payloadHash:String(repeating:"b",count:64),snapshot:snapshot,stage:"awaiting-confirmation",submitId:nil)
    let first=ClassicCliExecutor(cli:ClassicDreaminaCLI(runner:lostRunner),directory:lostDir)
    try await first.step(task:lostTask,owner:"owner",bridge:lostBridge,isCurrent:{true},validateVideo:{_ in})
    let restored=ClassicCliExecutor(cli:ClassicDreaminaCLI(runner:lostRunner),directory:lostDir)
    try await restored.step(task:lostTask,owner:"owner",bridge:lostBridge,isCurrent:{true},validateVideo:{_ in})
    let lostCalls=await lostRunner.allCalls(),lostRecords=await lostBridge.values()
    try check(lostCalls.filter {$0.first == "text2video"}.count == 1 && !lostCalls.contains(["user_credit"]),"lost failure receipt recovery never retries credit gate or paid generation")
    try check(lostRecords == ["dispatch-intent","unknown:submit-timeout","unknown:submit-timeout"],"saved safe failure reason is retransmitted after lost receipt")
    let valid="upload progress {\"url\":\"https://fixture.invalid/image\"}\n{\"submit_id\":\"actual-ID\",\"message\":\"brace } and escaped \\\" quote\"}\n"
    let id=try ClassicDreaminaCLI.submissionID(DreaminaOutput(status:0,data:Data(valid.utf8)))
    try check(id == "actual-ID","final submission receipt survives prior upload JSON and quoted braces")
    for (text,status,expected) in [("{}",Int32(0),ClassicCliSubmissionError.receiptMissing),("{\"submit_id\":\"early\"}\n{",0,.receiptInvalid),("{\"submit_id\":\"id\"} trailing error",0,.receiptInvalid),("{\"submit_id\":\"unsafe/path\"}",0,.receiptMissing),("AigcComplianceConfirmationRequired cookie=never-persist",1,.complianceRequired),("insufficient credits secret=never-persist",1,.insufficientCredits),("unknown flag --bogus",1,.argumentsRejected),("请先执行 dreamina login",1,.loginRequired),("upstream error raw secret",1,.rejected)] {
        do {_ = try ClassicDreaminaCLI.submissionID(DreaminaOutput(status:status,data:Data(text.utf8)));throw NativeTestFailure(description:"unsafe or missing receipt accepted")} catch let error as ClassicCliSubmissionError {try check(error == expected,"CLI errors become bounded safe diagnostic codes")}
    }
    try check(ClassicCliSubmissionError.code(DreaminaError.timedOut) == "submit-timeout","timeout remains unknown with safe diagnostic")
}
