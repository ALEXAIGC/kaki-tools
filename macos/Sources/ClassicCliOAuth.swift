import Foundation

struct ClassicCliAuthorization: Sendable {
    let url:URL
    let userCode:String
    let deviceCode:String // This session's memory only; never UI, logs, journal or credentials.
    static func parse(_ output:DreaminaOutput) throws -> Self {
        guard output.status == 0, output.data.count <= 16_384 else {throw DreaminaError.invalidResponse}
        var fields:[String:String]=[:]
        for line in String(decoding:output.data,as:UTF8.self).components(separatedBy:.newlines) {
            let parts=line.split(separator:":",maxSplits:1).map {String($0).trimmingCharacters(in:.whitespaces)}
            if parts.count == 2 && ["verification_uri","user_code","device_code"].contains(parts[0]) {
                guard fields[parts[0]] == nil else {throw DreaminaError.invalidResponse}
                fields[parts[0]]=parts[1]
            }
        }
        guard let uri=fields["verification_uri"], let url=URL(string:uri),let outer=URLComponents(url:url,resolvingAgainstBaseURL:false),outer.scheme == "https",outer.host == "jimeng.jianying.com",outer.path == "/ai-tool/cli-auth",outer.user == nil,outer.password == nil,outer.port == nil,outer.fragment == nil,
              let code=fields["user_code"],code.range(of:"^[A-Za-z0-9-]{1,64}$",options:.regularExpression) != nil,
              let device=fields["device_code"],!device.isEmpty,device.count <= 4096,!device.contains(where:{$0.isWhitespace}),!uri.contains(device),
              validAuthorizationQuery(url,userCode:code,deviceCode:device) else {throw DreaminaError.invalidResponse}
        return Self(url:url,userCode:code,deviceCode:device)
    }
    private static func validAuthorizationQuery(_ url:URL,userCode:String,deviceCode:String) -> Bool {
        guard let components=URLComponents(url:url,resolvingAgainstBaseURL:false) else {return false}
        let query=components.queryItems ?? []
        if query.isEmpty {return components.percentEncodedQuery == nil}
        // Official Device Flow wraps its exact scan endpoint in one verification_uri.
        guard query.count == 1,query[0].name == "verification_uri",let value=query[0].value,
              !value.contains(deviceCode),let nested=URLComponents(string:value),nested.scheme == "https",
              nested.host == "jimeng.jianying.com",nested.path == "/passport/open/scan_user_code/",
              nested.user == nil,nested.password == nil,nested.port == nil,nested.fragment == nil,
              let inner=nested.queryItems,
              inner.count == 1,inner[0].name == "user_code",inner[0].value == userCode else {return false}
        return true
    }
    enum Start: Sendable { case authorization(ClassicCliAuthorization), reusedSession }
    var qrURL: URL {
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        return query?.first(where: { $0.name == "verification_uri" })?.value.flatMap(URL.init(string:)) ?? url
    }
    static func start(_ runner: DreaminaRunning, force: Bool = false,
                      canReset: @Sendable () async -> Bool = { true }) async throws -> Start {
        let command = force ? "relogin" : "login"
        let help=try await runner.run([command,"--help"],timeout:5)
        guard help.status == 0,String(decoding:help.data,as:UTF8.self).contains("--headless") else {throw ClassicCliUpgradeError.required}
        try Task.checkCancellation()
        if force { guard await canReset() else { throw ClassicCliUpgradeError.active } }
        try Task.checkCancellation()
        let output = try await runner.run([command,"--headless"],timeout:15)
        if !force, output.status == 0, String(decoding: output.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "已复用当前本地 OAuth 登录态。" {
            return .reusedSession
        }
        return .authorization(try parse(output))
    }
    func poll(_ runner:DreaminaRunning) async throws -> Bool {
        let output=try await runner.run(["login","checklogin","--device_code",deviceCode,"--poll","0"],timeout:10)
        if output.status == 0 {return true}
        if output.status == 1,String(decoding:output.data,as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines) == "登录尚未完成，请稍后重试或增加 --poll" {return false}
        throw DreaminaError.expiredAuthorization
    }
}
