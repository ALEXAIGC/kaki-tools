import SwiftUI
import AppKit
import AVKit

@MainActor struct StudioAccountView: View {
    @ObservedObject var studio: StudioStore
    var openLibrary: (() -> Void)?
    var settingsPresentation = false
    @State private var email = ""
    @State private var password = ""
    @State private var code = ""
    var body: some View {
        Group {
            if settingsPresentation {
                SettingsCard("Studio 账号") { form }
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Studio 账号").font(.title2.bold())
                    SettingsFootnote("使用 KAKI AIGC Studio 账号，访问素材与工作区。")
                    form
                }.padding(24)
            }
        }.tint(SettingsStyle.accent).accentColor(SettingsStyle.accent)
            .task { await studio.restoreSession() }
            .onChange(of: studio.user?.id) { _ in password = ""; code = "" }
            .onDisappear { password = ""; code = "" }
    }
    private var form: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("连接环境").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Picker("连接环境", selection: Binding(get: { studio.environment }, set: { value in
                    password = ""; code = ""
                    Task { await studio.changeEnvironment(value) }
                })) {
                    ForEach(StudioEnvironment.allCases) { Text($0.label).tag($0) }
                }.labelsHidden().frame(width: 142).disabled(studio.busy)
            }
            Divider()
            if let user = studio.user {
                HStack(spacing: 13) {
                    Image(systemName: "person.crop.circle.fill").font(.system(size: 40, weight: .light))
                        .foregroundStyle(SettingsStyle.accent.opacity(0.85))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(user.name ?? "Studio 用户").font(.system(size: 16, weight: .semibold)).lineLimit(1)
                        Text(user.email).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                    SettingsStatus(title: "已登录", active: true)
                }
                HStack(spacing: 10) {
                    if let openLibrary { Button("打开素材库", action: openLibrary).buttonStyle(SettingsPrimaryButtonStyle()) }
                    Button("退出账号") { password = ""; code = ""; Task { await studio.logout() } }
                }.controlSize(.large)
                SettingsFootnote("退出后保留已复制和下载的内容。")
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("邮箱").font(.system(size: 12)).foregroundStyle(.secondary)
                        TextField("Studio 邮箱", text: $email).textFieldStyle(.roundedBorder).accessibilityLabel("Studio 邮箱")
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("密码").font(.system(size: 12)).foregroundStyle(.secondary)
                        SecureField("输入密码", text: $password).textFieldStyle(.roundedBorder).onSubmit { signIn() }
                            .accessibilityLabel("Studio 密码")
                    }
                    if studio.twoFactorRequired {
                        TextField("动态验证码或备用码", text: $code).textFieldStyle(.roundedBorder).onSubmit { signIn() }
                    }
                    HStack(spacing: 10) {
                        Button(studio.twoFactorRequired ? "验证并登录" : "登录 Studio", action: signIn)
                            .buttonStyle(SettingsPrimaryButtonStyle()).disabled(studio.busy || email.isEmpty || password.isEmpty)
                        if studio.busy { ProgressView().controlSize(.small) }
                        Spacer()
                        Button("注册") { NSWorkspace.shared.open(studio.environment.baseURL.appendingPathComponent("sign-up")) }.buttonStyle(.link)
                        Button("忘记密码") { NSWorkspace.shared.open(studio.environment.baseURL.appendingPathComponent("forgot-password")) }.buttonStyle(.link)
                    }.padding(.top, 4)
                }.controlSize(.large)
                if studio.logoutCleanupPending {
                    Button("重试退出清理") { Task { await studio.logout() } }.disabled(studio.busy)
                } else if !studio.message.isEmpty && !studio.twoFactorRequired {
                    Button("重试连接") { Task { await studio.retrySession() } }.disabled(studio.busy)
                }
                SettingsFootnote("密码不保存，登录会话由 macOS 钥匙串保管。")
            }
            if !studio.message.isEmpty {
                SettingsFootnote(studio.message).textSelection(.enabled)
            }
        }
    }
    private func signIn() {
        let enteredEmail = email, enteredPassword = password, enteredCode = code
        Task {
            await studio.login(email: enteredEmail, password: enteredPassword, code: enteredCode)
            if studio.user != nil { password = ""; code = "" }
        }
    }
}



@MainActor struct StudioLibraryView: View {
    @ObservedObject var studio: StudioStore
    var copyMaterial: (StudioAsset) -> Void
    var copyReferences: ([String]) -> Void = { _ in }
    var downloadMaterials: ([String]) -> Void = { _ in }
    var openDownloadSettings: () -> Void = {}
    var close: () -> Void = {}
    @State private var selection = StudioSelection()
    @State private var accountVisible = false
    @State private var previewAsset: StudioAsset?
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var searchFocused: Bool
    private let accent = Color(red: 0.988, green: 0.388, blue: 0.004)
    private var selected: StudioAsset? { studio.visibleAssets.first { $0.id == selection.primary } }
    var body: some View {
        Group {
            if studio.user == nil {
                HStack { Spacer(); StudioAccountView(studio: studio).frame(maxWidth: 460); Spacer() }.frame(maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    toolbar
                    Divider()
                    if studio.workspaces.isEmpty {
                        VStack(spacing: 16) {
                            Image(systemName: "lock.shield").font(.system(size: 32)).foregroundStyle(.secondary)
                            Text("暂无可访问的工作区")
                            Text(studio.message).font(.callout).foregroundStyle(.secondary)
                            Button("重新检查权限") { Task { await studio.retryWorkspaces() } }.disabled(studio.busy)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        GeometryReader { viewport in
                        ScrollView {
                            if studio.visibleAssets.isEmpty {
                                VStack(spacing: 12) {
                                    if studio.loadingAssets { ProgressView() }
                                    else { Image(systemName: "photo.on.rectangle.angled").font(.system(size: 32)).foregroundStyle(.secondary) }
                                    Text(studio.loadingAssets ? "加载中…" : !studio.query.isEmpty ? "没有匹配结果" : studio.source == .recent ? "暂无生成结果" : "暂无素材")
                                        .font(.callout).foregroundStyle(.secondary)
                                    if !studio.loadingAssets && !studio.query.isEmpty {
                                        Button("清除搜索") { studio.query = "" }.buttonStyle(.link)
                                    }
                                }.padding(.top, 80).frame(maxWidth: .infinity)
                            }
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 166, maximum: 220), spacing: 14)], spacing: 14) {
                                ForEach(studio.visibleAssets) { asset in
                                    StudioAssetCard(studio: studio, asset: asset, selected: selection.ids.contains(asset.id), accent: accent, viewportHeight: viewport.size.height, preview: { previewAsset = asset })
                                        .onTapGesture {
                                            searchFocused = false
                                            let flags = NSEvent.modifierFlags
                                            if !selection.select(asset.id, visible: studio.visibleAssets.map(\.id), toggle: flags.contains(.command), range: flags.contains(.shift)) {
                                                studio.setMessage("一次最多选择20项素材。")
                                            }
                                        }
                                        .contextMenu {
                                            if asset.kind == "video" { Button("预览视频") { previewAsset = asset } }
                                            Button("复制代码") { copyReferences(selection.ids.contains(asset.id) ? selection.ids : [asset.id]) }.disabled(studio.mediaBusy)
                                            Button("复制素材") { copyMaterial(asset) }.disabled(studio.mediaBusy)
                                            Button("下载素材") { downloadMaterials(selection.ids.contains(asset.id) ? selection.ids : [asset.id]) }.disabled(studio.mediaBusy)
                                        }
                                }
                            }.padding(20)
                            if studio.nextCursor != nil {
                                Button(studio.loadingAssets ? "加载中…" : "加载更多") { Task { await studio.refresh(more: true) } }
                                    .disabled(studio.loadingAssets).padding(.bottom, 20)
                            }
                        }.coordinateSpace(name: "studio-grid")
                        }
                    }
                    Divider()
                    if !studio.workspaces.isEmpty && (!studio.message.isEmpty || !studio.syncNote.isEmpty) { notice }
                    footer
                }
            }
        }.tint(accent).background(Color(nsColor: .windowBackgroundColor))
            .sheet(item: $previewAsset) { asset in
                StudioVideoPreview(studio: studio, asset: asset, copy: { previewAsset = nil; copyReferences([asset.id]) }, copyMaterial: { previewAsset = nil; copyMaterial(asset) }, download: { downloadMaterials([asset.id]) }, accent: accent)
            }
            .frame(minWidth: 680, minHeight: 480)
            .task { await studio.restoreSession() }
            .onAppear { selection.reconcile(studio.visibleAssets.map(\.id)) }
            .onExitCommand { close() }
            .task(id: "\(studio.libraryActive):\(studio.sessionRevision):\(studio.workspaceID)") {
                guard studio.libraryActive, studio.user != nil else { return }
                searchFocused = true
                await studio.refresh(background: true)
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return }
                    guard !Task.isCancelled, studio.libraryActive else { return }
                    await studio.refresh(background: true)
                }
            }
            .onChange(of: studio.visibleAssets.map(\.id)) { ids in
                selection.reconcile(ids)
            }
            .onChange(of: studio.query) { _ in
                searchTask?.cancel()
                searchTask = Task {
                    do { try await Task.sleep(nanoseconds: 300_000_000) } catch { return }
                    guard !Task.isCancelled else { return }
                    await studio.refresh()
                }
            }
            .onChange(of: studio.sessionRevision) { _ in previewAsset = nil; selection.clear(); selection.reconcile(studio.visibleAssets.map(\.id)); searchTask?.cancel() }
            .onDisappear { searchTask?.cancel() }
    }
    private var toolbar: some View {
        HStack(spacing: 12) {
            if let logo = NativeBrand.logo {
                Image(nsImage: logo).resizable().scaledToFill().frame(width: 76, height: 34).clipped()
                    .accessibilityLabel("KAKI").help(studio.environment.baseURL.host ?? "Studio")
            }
            Picker("来源", selection: Binding(get: { studio.source }, set: { value in Task { await studio.selectSource(value) } })) {
                ForEach(StudioSource.allCases) { Text($0 == .library ? "已保存" : "最近生成").tag($0) }
            }.pickerStyle(.segmented).labelsHidden().frame(width: 164)
            HStack(spacing: 8) {
                Button { searchFocused = true } label: { Image(systemName: "magnifyingglass").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).keyboardShortcut("f", modifiers: .command)
                    .help("搜索 · ⌘F").accessibilityLabel("搜索素材")
                TextField("搜索素材", text: $studio.query)
                    .textFieldStyle(.plain).focused($searchFocused)
                    .onSubmit { if !selection.ids.isEmpty && !studio.mediaBusy { copyReferences(selection.ids) } }
                if !studio.query.isEmpty {
                    Button { studio.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("清除搜索").accessibilityLabel("清除搜索")
                }
            }.padding(.horizontal, 10).padding(.vertical, 9)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(searchFocused ? accent.opacity(0.6) : Color.secondary.opacity(0.12), lineWidth: 1))
            Picker("类型", selection: $studio.kind) {
                Text("全部").tag("all"); Text("图片").tag("image"); Text("视频").tag("video")
                Text("音频").tag("audio")
            }.pickerStyle(.menu).labelsHidden().frame(width: 82)
                .help("素材类型").accessibilityLabel("素材类型")
            Menu {
                if studio.source == .library {
                    Picker("工作区", selection: Binding(get: { studio.workspaceID }, set: { value in Task { await studio.selectWorkspace(value) } })) {
                        ForEach(studio.workspaces) { Text($0.name).tag($0.id) }
                    }
                    Divider()
                }
                Button("下载与缓存设置…", action: openDownloadSettings)
            } label: {
                Image(systemName: "slider.horizontal.3").frame(width: 18, height: 18)
            }.menuStyle(.borderlessButton).fixedSize()
                .help(studio.source == .library ? studio.workspaceName : "最近生成 · 当前账号")
                .accessibilityLabel("工作区和设置")
            Button { Task { await studio.refresh() } } label: { Image(systemName: "arrow.clockwise").frame(width: 18, height: 18) }
                .buttonStyle(.borderless).help("刷新").accessibilityLabel("刷新素材").disabled(studio.loadingAssets || studio.mediaBusy)
            Button { accountVisible.toggle() } label: { Image(systemName: "person.crop.circle").frame(width: 18, height: 18) }
                .buttonStyle(.borderless).help("账号").accessibilityLabel("Studio 账号")
                .popover(isPresented: $accountVisible) { StudioAccountView(studio: studio).frame(width: 400) }
        }.padding(.horizontal, 20).padding(.vertical, 14)
    }
    private var notice: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: studio.message.isEmpty ? "exclamationmark.circle" : "info.circle")
            Text(studio.message.isEmpty ? studio.syncNote : studio.message).lineLimit(3).textSelection(.enabled)
            Spacer(minLength: 0)
            if studio.mediaBusy {
                Button("取消") { studio.cancelMedia() }.buttonStyle(.plain)
            } else if !studio.message.isEmpty {
                Button { studio.dismissMessage() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).help("关闭提示").accessibilityLabel("关闭提示")
            }
        }.font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 20).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading).background(accent.opacity(0.05))
    }
    private var footer: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                if studio.loadingAssets { ProgressView().controlSize(.mini) }
                else { Circle().fill(Color.secondary.opacity(0.45)).frame(width: 6, height: 6).help(studio.syncStatus) }
                Text(selection.ids.isEmpty ? "\(studio.assets.count) 项" : "已选 \(selection.ids.count) 项")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            }.help("\(studio.assets.count) / \(studio.total) 项 · ⌘点击多选，⇧点击连续选择")
            Spacer(minLength: 8)
            Button("复制代码") { copyReferences(selection.ids) }.buttonStyle(StudioPrimaryButtonStyle(accent: accent))
                .keyboardShortcut(.return, modifiers: []).disabled(selection.ids.isEmpty || studio.mediaBusy)
                .help("复制素材引用，到画布或 Harness 按 ⌘V 使用")
            Button("复制素材") { if let selected { copyMaterial(selected) } }.controlSize(.large)
                .disabled(selection.ids.count != 1 || studio.mediaBusy)
                .help(selection.ids.count > 1 ? "请选择一个素材，复制真实图片、视频或音频" : "复制真实素材到剪贴板")
            Button("下载素材") { downloadMaterials(selection.ids) }.controlSize(.large)
                .disabled(selection.ids.isEmpty || studio.mediaBusy)
                .help("下载选中的素材到本地")
        }.padding(.horizontal, 20).padding(.vertical, 12)
    }
}

private struct StudioPrimaryButtonStyle: ButtonStyle {
    let accent: Color
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(accent.opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.35), in: RoundedRectangle(cornerRadius: 7))
            .contentShape(RoundedRectangle(cornerRadius: 7))
    }
}

@MainActor private struct StudioAssetCard: View {
    @ObservedObject var studio: StudioStore
    let asset: StudioAsset
    let selected: Bool
    let accent: Color
    var viewportHeight: CGFloat = 0
    var preview: () -> Void = {}
    @State private var image: NSImage?
    @State private var cardFrame: CGRect = .zero
    private var nearby: Bool { viewportHeight > 0 && cardFrame.maxY >= -180 && cardFrame.minY <= viewportHeight + 180 }
    var body: some View {
        content
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? accent : Color.secondary.opacity(0.2), lineWidth: selected ? 1.5 : 1))
            .help(([asset.title, asset.kindLabel] + (asset.tags ?? [])).joined(separator: " · "))
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(asset.title + "，" + asset.kindLabel))
            .accessibilityAddTraits(selected ? .isSelected : [])
            .background(GeometryReader { proxy in
                let frame = proxy.frame(in: .named("studio-grid"))
                Color.clear.onAppear { cardFrame = frame }.onChange(of: frame) { cardFrame = $0 }
            })
            .task(id: "\(studio.sessionRevision):\(asset.id):\(asset.url):\(asset.thumbUrl ?? ""):\(nearby):\(studio.libraryActive)") {
                guard nearby else { image = nil; return }
                guard studio.libraryActive else { image = nil; return }
                image = await studio.thumbnail(asset)
            }
            .onDisappear { image = nil }
    }
    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Color(nsColor: .controlBackgroundColor)
                if let image { Image(nsImage: image).resizable().scaledToFit().padding(8) }
                else { Image(systemName: asset.kind == "video" ? "play.rectangle" : asset.kind == "audio" ? "waveform" : "photo").font(.system(size: 28)).foregroundStyle(.secondary) }
                VStack {
                    HStack {
                        if asset.kind == "video" || asset.kind == "audio" {
                            if asset.kind == "video" {
                                Button(action: preview) { mediaBadge("play.fill") }.buttonStyle(.plain)
                                    .help("预览视频").accessibilityLabel("预览 " + asset.title)
                            } else { mediaBadge("waveform") }
                        }
                        Spacer()
                        if selected {
                            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                                .frame(width: 20, height: 20).background(accent, in: Circle())
                        }
                    }
                    Spacer()
                }.padding(10)
            }.frame(height: 140).clipped()
            Text(asset.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
        }
    }
    private func mediaBadge(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
            .frame(width: 28, height: 28).background(Color.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }
}

@MainActor private struct StudioVideoPreview: View {
    @ObservedObject var studio: StudioStore
    let asset: StudioAsset
    let copy: () -> Void
    let copyMaterial: () -> Void
    let download: () -> Void
    let accent: Color
    @StateObject private var playback = StudioVideoPlayback()
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(asset.title).font(.headline).lineLimit(1)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).help("关闭").accessibilityLabel("关闭预览")
            }.padding(16)
            ZStack {
                Color.black
                if !playback.error.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "play.slash").font(.system(size: 28))
                        Text(playback.error).font(.callout)
                    }.foregroundStyle(.white.opacity(0.8)).padding(24)
                } else if let player = playback.player { VideoPlayer(player: player) }
                else { ProgressView().tint(.white) }
            }.frame(minHeight: 320)
            HStack {
                Spacer()
                Button("复制代码", action: copy).buttonStyle(StudioPrimaryButtonStyle(accent: accent))
                Button("复制素材", action: copyMaterial)
                Button("下载素材", action: download)
            }.disabled(studio.mediaBusy).padding(16)
        }.frame(width: 680, height: 460).tint(accent)
            .onAppear { playback.start(asset, studio: studio) }
            .onDisappear { playback.stop() }
            .onExitCommand { dismiss() }
            .onChange(of: studio.sessionRevision) { _ in playback.stop(); dismiss() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in playback.player?.pause() }
    }
}
