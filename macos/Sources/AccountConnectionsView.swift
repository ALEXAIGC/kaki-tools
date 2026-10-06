import SwiftUI
import Combine
import AppKit

enum AccountConnectionSite: String, CaseIterable, Identifiable {
    case studio, dreamina
    var id: String { rawValue }
    var title: String { self == .studio ? "KAKI Studio" : "即梦 AI" }
    var accent: Color { self == .studio ? SettingsStyle.accent : Color(red: 0.04, green: 0.65, blue: 0.7) }
}

@MainActor struct AccountConnectionsView: View {
    @ObservedObject var studio: StudioStore
    @ObservedObject var connector: DreaminaConnector
    var classicCli: ClassicCliConnection?
    var openLibrary: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var classicStatus = ""
    @State private var expanded: AccountConnectionSite?

    init(studio: StudioStore, connector: DreaminaConnector, classicCli: ClassicCliConnection? = nil, openLibrary: @escaping () -> Void,
         expanded: AccountConnectionSite? = nil) {
        self.studio = studio; self.connector = connector; self.classicCli = classicCli; self.openLibrary = openLibrary
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
        .onReceive(classicCli?.$status.eraseToAnyPublisher() ?? Just("").eraseToAnyPublisher()) { classicStatus = $0 }
        .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.88), value: expanded)
        .task { if !Task.isCancelled { await studio.restoreSession() } }
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
        if expanded == .dreamina, site != .dreamina, connector.busy || connector.authorization != nil { connector.cancel() }
        expanded = site
    }
    private func isSettingsWindow(_ notification: Notification) -> Bool {
        (notification.object as? NSWindow)?.contentView is NSHostingView<NativeSettingsView>
    }
    private func domain(_ site: AccountConnectionSite) -> String {
        site == .studio ? (studio.environment.baseURL.host ?? "kakiai.xin") : "jimeng.jianying.com"
    }
    private func active(_ site: AccountConnectionSite) -> Bool { site == .studio ? studio.user != nil : (classicCli?.connected == true || connector.verified) }
    private func status(_ site: AccountConnectionSite) -> String {
        if site == .studio { return studio.user != nil ? "已登录" : "未登录" }
        if classicCli != nil { return classicStatus.isEmpty ? "未连接" : classicStatus }
        return connector.verified ? "已关联" : connector.binding == nil ? "未关联" : "待验证"
    }
    private func subtitle(_ site: AccountConnectionSite) -> String {
        if site == .studio { return studio.user.map { $0.name ?? $0.email } ?? "素材与工作区" }
        if classicCli != nil { return "使用本机即梦登录" }
        return connector.binding == nil ? "连接创作账号" : "账号 ···" + (connector.binding?.dreaminaUserID.suffix(6) ?? "")
    }
    private func details(_ site: AccountConnectionSite) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(site.accent).frame(width: 3, height: 18)
                Text(site == .studio ? (studio.user == nil ? "登录 KAKI Studio" : "Studio 账号") : "即梦账号")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button { select(nil) } label: { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).frame(width: 26, height: 26) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel("收起" + site.title).help("收起")
            }
            Divider()
            Group {
                if site == .studio { StudioAccountView(studio: studio, openLibrary: openLibrary, embedded: true) }
                else if let classicCli {
                    ClassicCliConnectionView(connection: classicCli)
                    DisclosureGroup("dreamina-canvas 独立连接") { DreaminaConnectionView(connector: connector, studio: studio, isPresented: { expanded == .dreamina }) }
                }
                else { DreaminaConnectionView(connector: connector, studio: studio, isPresented: { expanded == .dreamina }) }
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
                WebsiteIllustration(site: site).frame(height: 78).clipShape(RoundedRectangle(cornerRadius: 10))
                    .accessibilityHidden(true)
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

private struct WebsiteIllustration: View {
    let site: AccountConnectionSite
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack {
                LinearGradient(colors: [site.accent.opacity(0.13), site.accent.opacity(0.025)], startPoint: .topLeading, endPoint: .bottomTrailing)
                if site == .studio {
                    ForEach(0..<3) { index in
                        ImageTile(accent: site.accent, index: index)
                            .frame(width: 62, height: 49)
                            .rotationEffect(.degrees(Double(index - 1) * 9))
                            .position(x: width / 2 + CGFloat(index - 1) * 42, y: 39 + CGFloat(index % 2) * 4)
                    }
                } else {
                    RoundedRectangle(cornerRadius: 10).fill(LinearGradient(colors: [Color(red: 0.09, green: 0.2, blue: 0.3), Color(red: 0.03, green: 0.52, blue: 0.59)], startPoint: .bottomLeading, endPoint: .topTrailing))
                        .frame(width: 126, height: 59).rotationEffect(.degrees(-4))
                        .overlay { Image(systemName: "play.fill").font(.system(size: 17)).foregroundStyle(.white.opacity(0.9)) }
                    Image(systemName: "sparkle").font(.system(size: 18, weight: .light)).foregroundStyle(site.accent.opacity(0.65))
                        .position(x: width / 2 + 86, y: 18)
                    Capsule().fill(site.accent.opacity(0.3)).frame(width: 34, height: 3).position(x: width / 2 - 66, y: 64)
                }
            }
        }
    }
    private struct ImageTile: View {
        let accent: Color
        let index: Int
        var body: some View {
            ZStack {
                RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .controlBackgroundColor))
                RoundedRectangle(cornerRadius: 5).fill(accent.opacity(index == 1 ? 0.2 : 0.09)).padding(5)
                Image(systemName: index == 1 ? "photo.fill" : "square.stack.fill").font(.system(size: 22, weight: .light)).foregroundStyle(accent.opacity(index == 1 ? 0.85 : 0.35))
            }.overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(accent.opacity(0.12), lineWidth: 1) }
        }
    }
}

@MainActor private struct ClassicCliConnectionView: View {
    @ObservedObject var connection: ClassicCliConnection
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("经典即梦 CLI").font(.system(size: 12, weight: .semibold))
            Text(connection.status).font(.system(size: 13, weight: .medium))
            Text("使用本机即梦登录 · 每次生成需确认本人即梦额度").font(.system(size: 11)).foregroundStyle(.secondary)
            if !connection.version.isEmpty {Text(connection.version).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)}
            HStack {
                if !connection.installed {Button("安装即梦 CLI") {connection.install()}.disabled(connection.busy)}
                Button("重新检测") {connection.detect()}.disabled(connection.busy)
                if connection.installed {Button("登录即梦") {connection.login()}.disabled(connection.busy)}
                Button(connection.connected ? "重新检查" : "连接本机 CLI") { connection.connect() }.disabled(connection.busy || !connection.installed)
                if connection.connected { Button("断开") { connection.disconnect() } }
            }
        }.onAppear {connection.detect()}
    }
}
