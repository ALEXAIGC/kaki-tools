import SwiftUI
import AppKit
import CoreImage.CIFilterBuiltins

@MainActor struct DreaminaConnectionView: View {
    @ObservedObject var connector: DreaminaConnector
    @ObservedObject var studio: StudioStore
    var isPresented: () -> Bool = { true }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let user = studio.user {
                HStack(spacing: 8) {
                    Text("KAKI 账号").foregroundStyle(.secondary)
                    Text(user.name ?? user.email).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    if let binding = connector.binding {
                        Text("即梦 ···\(binding.dreaminaUserID.suffix(6))").foregroundStyle(.secondary).monospacedDigit()
                    }
                }.font(.system(size: 12))
            } else {
                SettingsFootnote("先登录 KAKI Studio，再连接即梦。")
            }

            if let authorization = connector.authorization {
                DreaminaAuthorizationView(authorization: authorization, cancel: connector.cancel)
                    .id(authorization.id)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                HStack(spacing: 12) {
                    Button(connector.busy ? "处理中…" : connector.binding == nil ? "连接即梦" : "验证关联") {
                        Task { if isPresented() { await connector.connect() } }
                    }.buttonStyle(SettingsPrimaryButtonStyle())
                        .disabled(studio.user == nil || connector.owner == nil || connector.busy)
                    Button { Task { if isPresented() { await connector.refresh() } } } label: {
                        Label("刷新状态", systemImage: "arrow.clockwise")
                    }.disabled(connector.busy)
                    if connector.busy {
                        ProgressView().controlSize(.small)
                        Button("取消") { connector.cancel() }
                    }
                    Spacer(minLength: 0)
                }

                if connector.binding != nil {
                    HStack(spacing: 18) {
                        Button { Task { if isPresented() { await connector.loadVideoModels() } } } label: {
                            Label("视频模型", systemImage: "film")
                        }.disabled(!connector.verified || connector.busy)
                        Button("解除关联", role: .destructive) { Task { if isPresented() { await connector.disconnect() } } }
                            .disabled(connector.busy)
                        Spacer(minLength: 0)
                    }.buttonStyle(.borderless).font(.system(size: 12))
                }

            }

            if !connector.videoModels.isEmpty {
                Text(connector.videoModels.joined(separator: " · "))
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
            }
            if !connector.message.isEmpty {
                Text(connector.message).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            HStack(spacing: 12) {
                Text("授权保存在本机 · Studio 生成通道待接入")
                Spacer(minLength: 0)
                if !connector.version.isEmpty { Text("CLI \(connector.version)") }
            }.font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: connector.authorization?.id)
        .task(id: connector.owner) {
            guard !Task.isCancelled, isPresented() else { return }
            await connector.refresh()
        }
    }
}

@MainActor struct DreaminaAuthorizationView: View {
    let authorization: DreaminaAuthorization
    let cancel: () -> Void
    @State private var openFailed = false
    @State private var qrCode: NSImage?
    @State private var renderedAuthorizationID: UUID?
    private static func makeQRCode(_ authorization: DreaminaAuthorization) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(authorization.url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 22) {
                qrPanel
                actions.frame(minWidth: 200, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 16) {
                qrPanel
                actions
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(SettingsStyle.accent.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(SettingsStyle.accent.opacity(0.13), lineWidth: 1) }
            .task(id: authorization.id) {
                guard !Task.isCancelled, renderedAuthorizationID != authorization.id else { return }
                qrCode = Self.makeQRCode(authorization)
                renderedAuthorizationID = authorization.id; openFailed = false
            }
    }
    @ViewBuilder private var qrPanel: some View {
        if renderedAuthorizationID == authorization.id, let image = qrCode {
            Image(nsImage: image).interpolation(.none).resizable().scaledToFit()
                .frame(width: 144, height: 144).padding(12)
                .background(.white, in: RoundedRectangle(cornerRadius: 10))
                .accessibilityLabel("即梦官方授权二维码")
        }
    }
    private var actions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("扫码或打开官方页面").font(.system(size: 13, weight: .semibold))
            Button("打开官方授权页面") { openFailed = !NSWorkspace.shared.open(authorization.url) }
                .buttonStyle(SettingsPrimaryButtonStyle())
            Link(openFailed ? "重试打开官方授权链接" : "jimeng.jianying.com", destination: authorization.url)
                .font(.system(size: 11)).foregroundStyle(.secondary)
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text("等待授权确认…").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Text("有效至 \(authorization.expiresAt.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Button("取消", action: cancel).keyboardShortcut(.cancelAction)
                    .buttonStyle(.borderless).font(.system(size: 12))
            }
        }
    }
}
