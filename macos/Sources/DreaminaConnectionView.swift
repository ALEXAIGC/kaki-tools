import SwiftUI
import AppKit
import CoreImage.CIFilterBuiltins

@MainActor struct DreaminaConnectionView: View {
    @ObservedObject var connector: DreaminaConnector
    @ObservedObject var studio: StudioStore
    var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    HStack(spacing: 10) {
                        Image(systemName: "link").font(.system(size: 19)).foregroundStyle(SettingsStyle.accent)
                            .frame(width: 38, height: 38).background(SettingsStyle.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                        VStack(alignment: .leading, spacing: 4) {
                            Text("即梦").font(.system(size: 14, weight: .semibold))
                            Text(connector.version.isEmpty ? "本机连接" : "CLI \(connector.version)").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    SettingsStatus(title: connector.verified ? "已关联" : connector.binding != nil ? "待验证" : "未关联", active: connector.verified)
                }
                if let user = studio.user {
                    Text("关联到 " + (user.name ?? user.email)).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    if let binding = connector.binding {
                        Text("即梦账号 ···\(binding.dreaminaUserID.suffix(6))").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    SettingsFootnote("登录 Studio 后，即可授权你的即梦账号。")
                }
                HStack(spacing: 10) {
                    Button(connector.busy ? "连接中…" : connector.binding == nil ? "连接即梦" : "验证关联") {
                        Task { await connector.connect() }
                    }.buttonStyle(SettingsPrimaryButtonStyle()).disabled(studio.user == nil || connector.busy)
                    Button { Task { await connector.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(connector.busy).help("刷新关联状态").accessibilityLabel("刷新即梦关联状态")
                    if connector.busy { Button("取消") { connector.cancel() } }
                    if connector.binding != nil || connector.verified {
                        Menu("更多") {
                            if connector.verified { Button("检查视频模型") { Task { await connector.loadVideoModels() } } }
                            if connector.binding != nil { Button("解除关联", role: .destructive) { Task { await connector.disconnect() } } }
                        }.disabled(connector.busy).fixedSize()
                    }
                    Spacer()
                }
                if !connector.videoModels.isEmpty {
                    Text(connector.videoModels.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
                }
                if !connector.message.isEmpty {
                    Text(connector.message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                SettingsFootnote("授权保存在本机。Studio 生成通道尚待接入。")
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: connector.owner) { await connector.refresh() }
        .sheet(item: Binding(get: { connector.authorization }, set: { value in
            if value == nil && connector.authorization != nil { connector.cancel() }
        })) { authorization in
            DreaminaAuthorizationView(authorization: authorization, cancel: connector.cancel)
        }
    }
}

@MainActor struct DreaminaAuthorizationView: View {
    let authorization: DreaminaAuthorization
    let cancel: () -> Void
    @State private var openFailed = false
    private var qrCode: NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(authorization.url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
    var body: some View {
        VStack(spacing: 16) {
            Text("连接即梦账号").font(.title2.bold())
            Text("打开官方页面授权，或用手机扫码。").font(.callout).foregroundStyle(.secondary)
            if let image = qrCode {
                Image(nsImage: image).interpolation(.none).resizable().scaledToFit()
                    .frame(width: 184, height: 184).padding(14).background(.white, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel("即梦官方授权二维码")
            }
            Button("打开即梦授权页面") { openFailed = !NSWorkspace.shared.open(authorization.url) }
                .buttonStyle(SettingsPrimaryButtonStyle()).controlSize(.large)
            if openFailed {
                Link("点击打开官方授权链接", destination: authorization.url).font(.caption)
            }
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("等待授权确认…").font(.callout) }
            Text("有效至 \(authorization.expiresAt.formatted(date: .omitted, time: .shortened))")
                .font(.caption).foregroundStyle(.secondary)
            Button("取消连接", action: cancel).keyboardShortcut(.cancelAction)
        }.padding(28).frame(width: 440)
    }
}
