import SwiftUI
import AppKit

enum AccountConnectionSite: String, CaseIterable, Identifiable {
    case studio, dreamina
    var id: String { rawValue }
    var title: String { self == .studio ? "KAKI Studio" : "即梦 AI" }
    var accent: Color { self == .studio ? SettingsStyle.accent : Color(red: 0.04, green: 0.65, blue: 0.7) }
}

@MainActor struct AccountConnectionsView: View {
    @ObservedObject var studio: StudioStore
    @ObservedObject var classicCli: ClassicCliConnection
    var openLibrary: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded: AccountConnectionSite?

    init(studio: StudioStore, classicCli: ClassicCliConnection, openLibrary: @escaping () -> Void,
         expanded: AccountConnectionSite? = nil) {
        self.studio = studio; self.classicCli = classicCli; self.openLibrary = openLibrary
        _expanded = State(initialValue: expanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(AccountConnectionSite.allCases) { site in
                    AccountWebsiteCard(site: site, domain: domain(site), status: status(site), active: active(site),
                                       subtitle: subtitle(site), selected: expanded == site) {
                        select(expanded == site ? nil : site)
                    }
                }
            }
            if let expanded {
                details(expanded)
                    .id(expanded)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .top)), removal: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.88), value: expanded)
        .task {
            guard !Task.isCancelled else { return }
            await studio.restoreSession()
            guard !Task.isCancelled else { return }
            classicCli.detect()
        }
        .onDisappear { select(nil) }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
            if isSettingsWindow(notification) { select(nil) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { notification in
            if isSettingsWindow(notification), let window = notification.object as? NSWindow, !window.isVisible { select(nil) }
        }
    }

    private func select(_ site: AccountConnectionSite?) {
        // Cancel before the removal animation: an outgoing view must never cancel
        // a new operation started after the user reopens the same card.
        if expanded == .dreamina, site != .dreamina, classicCli.busy || classicCli.authorizationURL != nil { classicCli.cancelOperation() }
        expanded = site
    }
    private func isSettingsWindow(_ notification: Notification) -> Bool {
        (notification.object as? NSWindow)?.contentView is NSHostingView<NativeSettingsView>
    }
    private func domain(_ site: AccountConnectionSite) -> String {
        site == .studio ? (studio.environment.siteLabel + " · " + (studio.environment.baseURL.host ?? "kakiai.xin")) : "jimeng.jianying.com"
    }
    private func active(_ site: AccountConnectionSite) -> Bool { site == .studio ? studio.user != nil : classicCli.connected }
    private func status(_ site: AccountConnectionSite) -> String {
        if site == .studio { return studio.user != nil ? "已登录" : "未登录" }
        if classicCli.connected { return "已连接" }
        if classicCli.busy { return "处理中" }
        if !classicCli.installed { return "待安装" }
        return classicCli.needsUpgrade ? "待更新" : classicCli.loginChecked && classicCli.loggedIn ? "待连接" : "未连接"
    }
    private func subtitle(_ site: AccountConnectionSite) -> String {
        if site == .studio { return studio.user.map { $0.name ?? $0.email } ?? "素材与工作区" }
        return classicCli.connected ? classicCli.targetWorkspaceName : "本机生成"
    }
    private func details(_ site: AccountConnectionSite) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(site.accent).frame(width: 3, height: 18)
                Text(site == .studio ? "Studio 账号" : "即梦连接")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button { select(nil) } label: { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).frame(width: 26, height: 26) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel("收起" + site.title).help("收起")
            }
            Group {
                if site == .studio { StudioAccountView(studio: studio, openLibrary: openLibrary, embedded: true) }
                else { ClassicCliConnectionView(connection: classicCli) }
            }
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
            .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(site.accent.opacity(0.22), lineWidth: 1) }
    }
}

private struct AccountWebsiteCard: View {
    let site: AccountConnectionSite
    let domain: String
    let status: String
    let active: Bool
    let subtitle: String
    let selected: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    WebsiteLogo(site: site).frame(width: 46, height: 42)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(site.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.primary)
                        Text(domain).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    Spacer(minLength: 0)
                }

                HStack(spacing: 5) {
                    SettingsStatus(title: status, active: active)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(selected ? 180 : 0)).foregroundStyle(selected ? site.accent : Color.secondary)
                }
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(scheme == .dark ? Color.white.opacity(selected ? 0.055 : 0.03) : Color.white, in: RoundedRectangle(cornerRadius: 16))
                .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(selected ? site.accent.opacity(0.75) : Color.primary.opacity(hovered ? 0.16 : 0.075), lineWidth: selected ? 1.5 : 1) }
                .contentShape(RoundedRectangle(cornerRadius: 16))
        }.buttonStyle(.plain)
            .scaleEffect(hovered && !reduceMotion ? 1.012 : 1)
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: hovered)
            .accessibilityLabel(site.title + "，" + status)
            .accessibilityValue(selected ? "已展开" : "已收起")
            .accessibilityHint(selected ? "收起账号区域" : "展开登录或账号管理")
    }
}

private struct WebsiteLogo: View {
    let site: AccountConnectionSite
    private static let dreamina = Bundle.main.url(forResource: "dreamina-icon", withExtension: "ico").flatMap { NSImage(contentsOf: $0) }
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 11).fill(site.accent.opacity(0.09))
            if site == .studio {
                Text("KAKI").font(.system(size: 16, weight: .black)).italic().foregroundStyle(SettingsStyle.accent)
            } else if let logo = Self.dreamina {
                Image(nsImage: logo).resizable().scaledToFit().padding(5)
            } else { Image(systemName: "sparkles").font(.system(size: 24)).foregroundStyle(site.accent) }
        }.accessibilityHidden(true)
    }
}

@MainActor struct ClassicCliConnectionView: View {
    @ObservedObject var connection: ClassicCliConnection
    private var stage: Int { !connection.installed || connection.needsUpgrade ? 0 : !connection.loginChecked || !connection.loggedIn ? 1 : 2 }
    private var heading: String {
        if connection.connected { return "已连接 Studio" }
        if connection.busy { return connection.authorizationURL == nil ? connection.actionTitle + "…" : "等待即梦授权" }
        if !connection.installed { return "安装即梦 CLI" }
        if connection.needsUpgrade { return "更新即梦 CLI" }
        if !connection.loginChecked { return "检查本机登录" }
        return connection.loggedIn ? "连接 Studio" : "登录即梦"
    }
    var body: some View {
        VStack(spacing: 20) {
            HStack(spacing: 8) {
                ForEach(0..<3) { index in
                    HStack(spacing: 6) {
                        Image(systemName: connection.connected || index < stage ? "checkmark.circle.fill" : "\(index + 1).circle")
                        Text(["安装 CLI", "登录即梦", "连接 Studio"][index])
                    }.font(.system(size: 12, weight: index == stage ? .semibold : .regular))
                        .foregroundStyle(connection.connected || index <= stage ? Color.primary : Color.secondary)
                    if index < 2 { Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.tertiary) }
                }
            }.padding(.top, 4)
            VStack(spacing: 10) {
                if connection.busy { ProgressView().controlSize(.regular).frame(height: 36) }
                else { Image(systemName: connection.connected ? "checkmark.circle.fill" : "link.circle.fill")
                    .font(.system(size: 36, weight: .light)).foregroundStyle(connection.connected ? Color.green : SettingsStyle.accent) }
                Text(heading).font(.system(size: 19, weight: .semibold))
                if let _ = connection.authorizationURL {
                    Text(connection.authorizationUserCode).font(.system(size: 24, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                    HStack {
                        Button("复制授权码") { connection.copyAuthorizationCode() }
                        Button("打开授权页面") { connection.openAuthorizationPage() }.buttonStyle(SettingsPrimaryButtonStyle())
                    }
                }
            }.frame(maxWidth: .infinity).padding(.vertical, 8)
            if connection.hasStudioAccount {
                HStack(spacing: 28) {
                    context("站点", value: connection.targetSiteName)
                    Divider().frame(height: 28)
                    context("工作区", value: connection.targetWorkspaceName)
                }.frame(maxWidth: .infinity).padding(12)
                    .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
            }
            if stage == 2 && !connection.hasStudioAccount { Text("请先登录 Studio").font(.system(size: 12)).foregroundStyle(.secondary) }
            if !connection.busy && !connection.status.isEmpty && !connection.status.hasPrefix("已") {
                Text(connection.status).font(.system(size: 12)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 430)
            }
            VStack(alignment: .leading, spacing: 6) {
                if let total = connection.creditTotal { Text("即梦积分 " + String(format: "%g", total)) }
                if let queried = connection.creditQueriedAt, connection.creditTotal != nil { Text("最近查询 " + queried.formatted(date: .omitted, time: .shortened)) }
                Text(connection.creditStatus).foregroundStyle(.secondary)
                Text("在Studio打开即梦CLI分区或点击刷新时查询；当前设备须已连接。积分仅供展示，不作为生成或会员资格判断。")
                    .foregroundStyle(.secondary)
            }.font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 8) {
                Button("检测并更新设备能力") { connection.detectCapabilities() }
                    .disabled(connection.busy)
                if let preview = connection.capabilityPreview {
                    Text("当前型号（版本 \(preview.current.effectiveRevision)）：" + modelList(preview.current.models))
                    Text("新增：" + modelList(preview.added))
                    Text("移除：" + modelList(preview.removed))
                    Text("确认后型号：" + modelList(preview.payload.models))
                    if preview.retry { Text("上次结果未确认：将原样重试已确认请求（revision \(preview.payload.expectedRevision)），不会覆盖其他版本。") }
                    Text("使用本机即梦额度；会员资格独立。移除型号后，尚未提交的对应任务可能终止，已提交任务保留原 ID。")
                    HStack {
                        Button(preview.retry ? "确认重试原请求" : "确认更新设备能力") { connection.confirmCapabilities() }
                            .buttonStyle(SettingsPrimaryButtonStyle()).disabled(connection.busy)
                        Button("取消") { connection.discardCapabilityPreview() }.disabled(connection.busy)
                    }
                }
                if !connection.capabilityStatus.isEmpty { Text(connection.capabilityStatus) }
                Text("旧设备：先单独连接原设备再检测；CLI 路径或内容变化需重新授权。不会自动注册或恢复断开。")
                    .foregroundStyle(.secondary)
            }.font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 12) {
                if connection.busy {
                    Button("取消") { connection.cancelOperation() }
                } else if connection.connected {
                    Label("可在 Studio 中生成视频", systemImage: "play.circle").font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    Button(heading) { primaryAction() }.buttonStyle(SettingsPrimaryButtonStyle())
                        .disabled(stage == 2 && !connection.hasStudioAccount)
                }
                Menu {
                    Button("重新检测") { connection.detect() }.disabled(connection.busy)
                    if connection.installed {
                        Button("更新 CLI") { connection.upgrade() }.disabled(connection.busy || connection.connected)
                        Button("登录即梦") { connection.login() }.disabled(connection.busy || connection.connected || connection.needsUpgrade)
                    }
                    if connection.connected { Button("断开连接") { connection.disconnect() } }
                    if !connection.version.isEmpty { Divider(); Text("CLI · " + connection.version) }
                } label: { Image(systemName: "ellipsis").frame(width: 28, height: 28) }
                    .menuStyle(.borderlessButton).fixedSize().help("更多操作").accessibilityLabel("即梦连接更多操作")
            }.frame(maxWidth: .infinity).padding(.bottom, 4)
        }.frame(maxWidth: .infinity)
    }
    private func modelList(_ models: [String]) -> String { models.isEmpty ? "无" : models.map(ClassicVideoModels.title).joined(separator: "、") }
    private func context(_ label: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 12, weight: .medium)).lineLimit(1).help(value)
        }.frame(maxWidth: .infinity)
    }
    private func primaryAction() {
        if !connection.installed { connection.install() }
        else if connection.needsUpgrade { connection.upgrade() }
        else if !connection.loginChecked { connection.detect() }
        else if !connection.loggedIn { connection.login() }
        else { connection.connect() }
    }
}
