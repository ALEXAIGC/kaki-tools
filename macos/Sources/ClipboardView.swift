import SwiftUI
import AppKit

private struct ClipboardPalette {
    let background: Color
    let surface: Color
    let raised: Color
    let hover: Color
    let pressed: Color
    let sidebar: Color
    let foreground: Color
    let soft: Color
    let muted: Color
    let subtle: Color
    let faint: Color
    let border: Color
    let strongBorder: Color
    let control: Color
    let key: Color
    let accent = Color(rgb: 0xfc6301)
    let danger = Color(rgb: 0xe5484d)
    var accentSoft: Color { accent.opacity(0.12) }

    init(_ scheme: ColorScheme) {
        let light = scheme == .light
        background = Color(rgb: light ? 0xf3f4f5 : 0x0e1013)
        surface = Color(rgb: light ? 0xffffff : 0x15181c)
        raised = Color(rgb: light ? 0xf8f9fa : 0x1b1f24)
        hover = Color(rgb: light ? 0xf0f2f4 : 0x22272d)
        pressed = Color(rgb: light ? 0xeaeae7 : 0x0d0f11)
        sidebar = Color(rgb: light ? 0xf8f9fa : 0x121519)
        foreground = Color(rgb: light ? 0x181816 : 0xf4f4f2)
        soft = Color(rgb: light ? 0x343431 : 0xd6d7d4)
        muted = Color(rgb: light ? 0x626a73 : 0xaab2bc)
        subtle = Color(rgb: light ? 0x747e89 : 0x88929f)
        faint = Color(rgb: light ? 0x919aa4 : 0x68727e)
        border = Color(rgb: light ? 0xe0e4e8 : 0x2a3038)
        strongBorder = Color(rgb: light ? 0xc9cac3 : 0x3a3f44)
        control = Color(rgb: light ? 0xffffff : 0x16191c)
        key = Color(rgb: light ? 0xf0f0ed : 0x1b1e22)
    }
}

private extension Color {
    init(rgb: UInt32) {
        self.init(.sRGB, red: Double((rgb >> 16) & 255) / 255,
                  green: Double((rgb >> 8) & 255) / 255,
                  blue: Double(rgb & 255) / 255, opacity: 1)
    }
}



private struct ClipboardMetrics {
    let width: CGFloat
    var sidebar: CGFloat { width <= 1120 ? 132 : width <= 1480 ? 150 : 164 }
    var card: CGFloat { width <= 1120 ? 178 : width <= 1480 ? 188 : 200 }
    var showCounts: Bool { width > 1120 }
    var showHints: Bool { width > 1480 }
    var compactActions: Bool { width <= 1120 }
    var actionWidth: CGFloat { width <= 1480 ? 94 : 110 }
    var searchWidth: CGFloat { min(300, max(160, width * 0.22)) }
    var compactStudio: Bool { width <= 900 }
    var studioWidth: CGFloat { compactStudio ? 38 : 100 }
    var tabsWidth: CGFloat {
        min(480, max(80, width - 42 - searchWidth - (showHints ? 255 : 0) - studioWidth - 1 - 94 - 34 - 32 - 96))
    }
}

@MainActor struct ClipboardView: View {
    @ObservedObject var controller: AppController
    @ObservedObject var store: HistoryStore
    @ObservedObject private var settings: AppSettings
    @Environment(\.colorScheme) private var scheme
    @FocusState private var searchFocused: Bool
    @State private var now = Date()
    @State private var panelVisible = false

    init(controller: AppController, store: HistoryStore) {
        self.controller = controller; self.store = store; self.settings = controller.settings
    }
    private var palette: ClipboardPalette { ClipboardPalette(scheme) }

    var body: some View {
        GeometryReader { geometry in
            let metrics = ClipboardMetrics(width: geometry.size.width)
            VStack(spacing: 0) {
                commandbar(metrics)
                rule()
                HStack(spacing: 0) {
                    sidebar(metrics)
                    palette.border.frame(width: 1)
                    VStack(spacing: 0) {
                        cards(metrics)
                        rule()
                        actionbar(metrics)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(palette.background)
            .overlay(ClipboardPanelShape().stroke(palette.border, lineWidth: 1))
            .clipShape(ClipboardPanelShape())
        }
        .onReceive(NotificationCenter.default.publisher(for: .kakiPanelShown)) { notification in
            guard notification.object as? AppController === controller else { return }
            now = Date(); searchFocused = true; panelVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .kakiPanelHidden)) { notification in
            guard notification.object as? AppController === controller else { return }
            panelVisible = false
        }
        .task(id: panelVisible) {
            guard panelVisible else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return }
                guard !Task.isCancelled else { return }
                now = Date()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .kakiFocusSearch)) { notification in
            guard notification.object as? AppController === controller else { return }
            searchFocused = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
                guard let panel = NSApp.keyWindow as? ClipboardPanel, panel.controller === controller,
                      let editor = panel.firstResponder as? NSTextView else { return }
                editor.selectAll(nil)
            }
        }
        .onAppear { searchFocused = true; panelVisible = controller.panelIsVisible }
        .onDisappear { panelVisible = false }
    }

    private func rule() -> some View { palette.border.frame(height: 1) }

    private func commandbar(_ metrics: ClipboardMetrics) -> some View {
        HStack(spacing: 12) {
            Button { controller.showSettings() } label: {
                if let logo = NativeBrand.logo {
                    Image(nsImage: logo).resizable().scaledToFit().frame(width: 42, height: 42)
                } else {
                    Text("KAKI").font(.system(size: 15, weight: .black)).italic().foregroundColor(palette.accent).frame(width: 42, height: 42)
                }
            }.buttonStyle(.plain).help("Kaki Tools 设置 · ⌘,").accessibilityLabel("Kaki Tools 设置")
                .contextMenu {
                    Button("设置…") { controller.showSettings() }
                    Button("区域截图") { controller.takeScreenshot() }
                }
            search(metrics)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    boardButton("剪贴板", board: nil)
                    ForEach(store.boards, id: \.self) { name in
                        boardButton(name, board: name).contextMenu {
                            Button("重命名") { controller.renameBoard(name) }
                            Button("删除收藏", role: .destructive) { controller.deleteBoard(name) }
                        }
                    }
                    Button { controller.createBoard() } label: {
                        Image(systemName: "plus").font(.system(size: 16, weight: .regular)).frame(width: 36, height: 38)
                    }.buttonStyle(ClipboardControlStyle(palette: palette, quiet: true)).help("新建收藏分组").accessibilityLabel("新建收藏分组")
                }.padding(.vertical, 3)
            }.frame(maxWidth: metrics.tabsWidth).frame(height: 44)
            Spacer(minLength: 0)
            if metrics.showHints {
                Text("⌘1–9 使用 · Esc 关闭")
                    .font(.system(size: 11, design: .monospaced)).foregroundColor(palette.subtle).fixedSize()
            }
            palette.border.frame(width: 1, height: 24)
            Button { controller.showStudio() } label: {
                HStack(spacing: 7) {
                    Image(systemName: "photo.on.rectangle.angled").font(.system(size: 15))
                    if !metrics.compactStudio {
                        Text("素材库").font(.system(size: 13, weight: .medium))
                    }
                }.frame(width: metrics.studioWidth, height: 38)
            }.buttonStyle(ClipboardControlStyle(palette: palette))
                .help("打开 Studio 素材库 · \(HotkeyChord.parse(settings.studioHotkey)?.label ?? settings.studioHotkey)")
                .accessibilityLabel("打开 Studio 素材库")
            themeSwitcher
            Button { controller.showSettings() } label: {
                Image(systemName: "gearshape").font(.system(size: 16)).frame(width: 34, height: 34)
            }.buttonStyle(ClipboardControlStyle(palette: palette, quiet: true)).help("设置 · ⌘,").accessibilityLabel("Kaki Tools 设置")
        }.padding(.horizontal, 16).frame(height: 64).background(palette.surface)
    }

    private func search(_ metrics: ClipboardMetrics) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass").font(.system(size: 18, weight: .regular))
                .foregroundColor(searchFocused ? palette.accent : palette.subtle)
            TextField("", text: $controller.query, prompt: Text("搜索内容、标签或备注").foregroundColor(palette.subtle))
                .textFieldStyle(.plain).font(.system(size: 13)).foregroundColor(palette.foreground)
                .focused($searchFocused).accessibilityLabel("搜索剪贴板内容、标签或备注")
            if controller.searching { ProgressView().controlSize(.mini).frame(width: 12) }
            if !controller.query.isEmpty {
                Button { controller.query = ""; searchFocused = true } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundColor(palette.subtle)
                }.buttonStyle(.plain).help("清空搜索").accessibilityLabel("清空搜索")
            } else { KeyBadge(text: "⌘F", palette: palette) }
        }
        .padding(.leading, 12).padding(.trailing, 10).frame(width: metrics.searchWidth, height: 40)
        .background(searchFocused ? palette.surface : palette.control, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(searchFocused ? palette.accent.opacity(0.65) : palette.border, lineWidth: 1))
    }

    private func boardButton(_ title: String, board: String?) -> some View {
        Button {
            controller.board = board; controller.query = ""; controller.filter = .all; searchFocused = true
        } label: {
            HStack(spacing: 7) {
                if board == nil { Image(systemName: "clipboard").font(.system(size: 14)) }
                Text(title).font(.system(size: 13, weight: board == nil ? .semibold : .medium)).lineLimit(1)
            }.padding(.horizontal, board == nil ? 12 : 14).frame(height: 38).fixedSize(horizontal: true, vertical: false)
        }.buttonStyle(ClipboardControlStyle(palette: palette, active: controller.board == board, tinted: true, quiet: true))
    }

    private var themeSwitcher: some View {
        HStack(spacing: 2) {
            themeButton("system", label: "跟随系统")
            themeButton("light", label: "浅色模式")
            themeButton("dark", label: "深色模式")
        }.padding(3).background(palette.background, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.border, lineWidth: 1))
    }

    private func themeButton(_ mode: String, label: String) -> some View {
        Button { controller.setAppearance(mode) } label: {
            ThemeGlyph(mode: mode)
                .stroke(settings.appearance == mode ? palette.accent : palette.subtle,
                        style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
                .frame(width: 15, height: 15).frame(width: 27, height: 26)
        }
        .buttonStyle(ClipboardThemeStyle(palette: palette, active: settings.appearance == mode))
        .help(label).accessibilityLabel(label).accessibilityValue(settings.appearance == mode ? "已选中" : "")
    }

    private func sidebar(_ metrics: ClipboardMetrics) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(controller.board == nil ? "历史记录" : "收藏内容").font(.system(size: 11, weight: .medium))
                .foregroundColor(palette.subtle).padding(.leading, 10).padding(.bottom, 10)
            ForEach(AppController.Filter.allCases, id: \.self) { filter in
                Button { controller.filter = filter; searchFocused = true } label: {
                    HStack(spacing: 8) {
                        filterSymbol(filter)
                            .frame(width: 24)
                            .foregroundStyle(controller.filter == filter ? palette.accent : palette.subtle)
                        Text(filter.rawValue).font(.system(size: 13, weight: .medium))
                        Spacer(minLength: 0)
                        if metrics.showCounts {
                            Text("\(controller.currentBoardCounts[filter] ?? 0)").font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundColor(controller.filter == filter ? palette.accent : palette.subtle)
                                .frame(minWidth: 30, alignment: .trailing)
                        }
                    }.padding(.horizontal, 10).frame(height: 36)
                }
                .buttonStyle(ClipboardSidebarStyle(palette: palette, active: controller.filter == filter))
                .accessibilityLabel("\(filter.rawValue)，\(controller.currentBoardCounts[filter] ?? 0)条")
            }
            Spacer(minLength: 0)
            HStack(spacing: 7) {
                Circle().fill(palette.accent).frame(width: 5, height: 5)
                    .overlay(Circle().stroke(palette.accentSoft, lineWidth: 3).padding(-1))
                Text("仅存本机").font(.system(size: 11)).foregroundColor(palette.subtle)
            }.padding(.horizontal, 9).padding(.top, 8).padding(.bottom, 3)
        }.padding(.top, 14).padding(.horizontal, 10).padding(.bottom, 10)
            .frame(width: metrics.sidebar).background(palette.sidebar)
    }

    @ViewBuilder private func filterSymbol(_ filter: AppController.Filter) -> some View {
        let color = controller.filter == filter ? palette.accent : palette.subtle
        if filter == .text {
            Text("T").font(.system(size: 18, weight: .regular, design: .serif)).foregroundColor(color)
        } else {
            LibraryGlyph(kind: filter).stroke(color, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                .frame(width: 17, height: 17)
        }
    }

    private func cards(_ metrics: ClipboardMetrics) -> some View {
        GeometryReader { area in
            if controller.visibleItems.isEmpty {
                VStack(spacing: 9) {
                    Image(systemName: controller.query.isEmpty ? "clipboard" : "magnifyingglass").font(.system(size: 28, weight: .light)).foregroundColor(palette.faint)
                    Text(store.loading ? "正在加载历史…" : controller.query.isEmpty ? "还没有剪贴板记录" : "没有找到匹配内容").font(.system(size: 13, weight: .medium)).foregroundColor(palette.muted)
                    Text(store.isReadOnly ? (store.lastError ?? "原历史文件已保留，当前只读。") : controller.query.isEmpty ? "复制文本或图片后会自动出现在这里" : "试试其他内容、标签或备注")
                        .font(.system(size: 12)).foregroundColor(store.isReadOnly ? palette.accent : palette.subtle)
                }.frame(width: area.size.width, height: area.size.height)
            } else {
                ScrollViewReader { reader in
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 12) {
                            ForEach(Array(controller.visibleItems.enumerated()), id: \.element.id) { index, item in
                                ClipboardCard(item: item, index: index, selected: controller.selectedID == item.id,
                                              store: store, controller: controller, palette: palette, now: now,
                                              width: metrics.card, height: max(90, area.size.height - 28))
                                    .id(item.id)
                            }
                        }.padding(.horizontal, 16).padding(.vertical, 14)
                    }
                    .onChange(of: controller.selectedID) { id in
                        if let id { withAnimation(.easeOut(duration: 0.12)) { reader.scrollTo(id) } }
                    }
                    .onChange(of: controller.board) { _ in
                        if let first = controller.visibleItems.first { reader.scrollTo(first.id, anchor: .leading) }
                    }
                }
            }
        }.background(palette.background)
    }

    private func actionbar(_ metrics: ClipboardMetrics) -> some View {
        HStack(spacing: 14) {
            HStack(spacing: 10) {
                Text(selectionIndex).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundColor(palette.muted).fixedSize()
                Text(controller.message.isEmpty ? selectionSummary : controller.message)
                    .font(.system(size: 12)).foregroundColor(controller.message.isEmpty ? palette.muted : palette.accent).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                actionButton("粘贴", icon: "return", key: "↵", metrics: metrics, primary: true, enabled: controller.canPasteSelected) {
                    controller.activateSelected()
                }
                actionButton("纯文本", icon: "textformat", key: "⇧↵", metrics: metrics, enabled: controller.canPasteSelectedAsPlainText) {
                    controller.activateSelected(plainText: true)
                }
                actionButton(controller.selectedItem?.pinned == true ? "取消固定" : "固定", icon: "pin", key: "⌘P", metrics: metrics, enabled: controller.canPinSelected) {
                    controller.toggleSelectedPin()
                }
                actionButton("删除", icon: "trash", key: "⌫", metrics: metrics, danger: true, enabled: controller.canDeleteSelected) {
                    controller.deleteSelected()
                }
            }
        }.padding(.horizontal, 16).frame(height: 56).background(palette.surface)
    }

    private func actionButton(_ title: String, icon: String, key: String, metrics: ClipboardMetrics,
                              primary: Bool = false, danger: Bool = false, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if icon == "textformat" {
                    Text("T").font(.system(size: 18, weight: .regular, design: .serif))
                } else {
                    Image(systemName: icon).font(.system(size: 14)).symbolVariant(.none)
                }
                if !metrics.compactActions {
                    Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    KeyBadge(text: key, palette: palette, primary: primary)
                }
            }.padding(.horizontal, metrics.compactActions ? 0 : 10)
                .frame(minWidth: metrics.compactActions ? 38 : metrics.actionWidth, minHeight: 36)
        }.buttonStyle(ClipboardControlStyle(palette: palette, active: primary, danger: danger, quiet: !primary))
            .disabled(!enabled).help("\(title) · \(key)").accessibilityLabel(title)
    }

    private var selectionIndex: String {
        guard let selected = controller.selectedItem,
              let index = controller.visibleItems.firstIndex(where: { $0.id == selected.id }) else { return "—" }
        return String(format: "%02d / %02d", index + 1, controller.visibleItems.count)
    }
    private var selectionSummary: String {
        guard let item = controller.selectedItem else { return "选择一个项目开始操作" }
        if item.type == "image", let size = item.size { return "图片 · \(size.width) × \(size.height)" }
        return controller.summary(for: item)
    }
}

@MainActor private struct ClipboardCard: View {
    let item: HistoryItem
    let index: Int
    let selected: Bool
    @ObservedObject var store: HistoryStore
    @ObservedObject var controller: AppController
    let palette: ClipboardPalette
    let now: Date
    let width: CGFloat
    let height: CGFloat
    @State private var image: NSImage?
    @State private var hovered = false
    @State private var cardVisible = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Text(String(format: "%02d", index + 1)).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundColor(selected ? palette.accent : palette.subtle)
                if item.pinned { Image(systemName: "pin.fill").font(.system(size: 10)).foregroundColor(palette.accent) }
                Spacer(minLength: 0)
                if hovered { cardActions }
                else { Text(age).font(.system(size: 11)).foregroundColor(palette.subtle).lineLimit(1) }
            }.padding(.horizontal, 12).frame(height: 30)
            content
            if !(item.tags ?? []).isEmpty || !(item.note ?? "").isEmpty { annotations }
            rule()
            HStack(spacing: 5) {
                if index < 9 { KeyBadge(text: "⌘\(index + 1)", palette: palette, compact: true) }
                Text(metadata).font(.system(size: 11)).foregroundColor(palette.muted).lineLimit(1)
                Spacer(minLength: 0)
            }.padding(.horizontal, 12).frame(height: 28)
        }
        .frame(width: width, height: height)
        .background(selected || hovered ? palette.raised : palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? palette.accent.opacity(0.8) : hovered ? palette.strongBorder : palette.border, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onHover { inside in hovered = inside; if inside { controller.selectItem(item.id) } }
        .onTapGesture { controller.activate(item.id, plainText: NSEvent.modifierFlags.contains(.shift)) }
        .contextMenu {
            Button("粘贴") { controller.activate(item.id) }
            if item.type == "text" { Button("纯文本粘贴") { controller.activate(item.id, plainText: true) } }
            Button("仅复制") { controller.activate(item.id, copyOnly: true) }
            if item.board == nil { Button(item.pinned ? "取消固定" : "固定") { store.togglePin(id: item.id) } }
            Button("标签与备注…") { controller.editMetadata(item.id) }
            Menu("添加到收藏") {
                ForEach(store.boards, id: \.self) { board in Button(board) { Task { await store.addToBoardInBackground(id: item.id, board: board) } } }
                if store.boards.isEmpty { Text("请先新建收藏") }
            }
            Divider()
            Button(item.board == nil ? "删除" : "从收藏移除", role: .destructive) { store.remove(id: item.id) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(item.type == "image" ? "图片 \(index + 1)" : "剪贴板条目 \(index + 1)，\(String((item.text ?? "").prefix(120)))")
        .accessibilityValue(selected ? "已选中" : "")
        .onAppear {
            cardVisible = true
            if item.type == "image" { reloadImage() }
            else { controller.requestTextPresentation(item) }
        }
        .onDisappear { cardVisible = false; image = nil }
        .onReceive(store.thumbnailChanges.filter { $0 == item.id }) { _ in
            if cardVisible, item.type == "image" { reloadImage() }
        }
        .onChange(of: HistoryStore.ThumbnailSource(item)) { _ in
            if cardVisible, item.type == "image" { reloadImage() }
        }
    }

    private func reloadImage() {
        // Completion can arrive before SwiftUI replaces a callback's item
        // snapshot. Resolve by stable ID so the pending hash cannot reject it.
        guard let current = store.item(id: item.id), current.type == "image" else { image = nil; return }
        image = store.thumbnail(for: current)
    }

    private func rule() -> some View { palette.border.frame(height: 1) }
    private var content: some View {
        GeometryReader { geometry in
            if item.type == "image" {
                ZStack {
                    palette.pressed
                    if let image {
                        Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                            .frame(width: max(0, geometry.size.width - 20), height: max(0, geometry.size.height - 16))
                            .frame(width: geometry.size.width, height: geometry.size.height)
                    } else {
                        Image(systemName: store.isPending(id: item.id) ? "hourglass" : "photo").font(.system(size: 26, weight: .light)).foregroundColor(palette.faint)
                    }
                }
            } else {
                Text(String((item.text ?? "").prefix(600))).font(.system(size: 14, weight: .regular)).lineSpacing(4).foregroundColor(palette.soft)
                    .lineLimit(max(1, Int((geometry.size.height - 20) / 21))).truncationMode(.tail)
                    .frame(width: max(0, geometry.size.width - 28), height: max(0, geometry.size.height - 20), alignment: .topLeading)
                    .padding(.horizontal, 14).padding(.vertical, 10).clipped()
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var annotations: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let tags = item.tags, !tags.isEmpty {
                HStack(spacing: 4) {
                    ForEach(Array(tags.prefix(3).enumerated()), id: \.offset) { _, tag in
                        Text(tag).font(.system(size: 11, design: .monospaced)).foregroundColor(palette.accent)
                            .padding(.horizontal, 6).padding(.vertical, 3).lineLimit(1)
                            .background(palette.accentSoft, in: Capsule()).overlay(Capsule().stroke(palette.accent.opacity(0.48), lineWidth: 1))
                    }
                    if tags.count > 3 { Text("+\(tags.count - 3)").font(.system(size: 11, design: .monospaced)).foregroundColor(palette.muted) }
                }
            }
            if let note = item.note, !note.isEmpty { Text(note).font(.system(size: 11)).foregroundColor(palette.muted).lineLimit(1) }
        }.padding(.horizontal, 9).padding(.vertical, 7).frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.raised).overlay(alignment: .top) { rule() }
    }
    private var cardActions: some View {
        HStack(spacing: 4) {
            smallAction("tag", label: "标签与备注") { controller.editMetadata(item.id) }
            if item.board == nil { smallAction(item.pinned ? "pin.slash" : "pin", label: item.pinned ? "取消固定" : "固定") { store.togglePin(id: item.id) } }
            smallAction("trash", label: "删除", danger: true) { store.remove(id: item.id) }
        }
    }
    private func smallAction(_ icon: String, label: String, danger: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).font(.system(size: 11)).frame(width: 21, height: 21) }
            .buttonStyle(ClipboardControlStyle(palette: palette, danger: danger, radius: 5, quiet: true)).help(label).accessibilityLabel(label)
    }
    private var metadata: String {
        if item.type == "image", let size = item.size { return "\(size.width) × \(size.height)" }
        let base = controller.textCount(for: item).map { "\($0) 字" } ?? "文本"
        return item.hasRichText ? base + " · 富文本" : base
    }
    private var age: String {
        let elapsed = max(0, now.timeIntervalSince1970 - item.createdAt / 1000)
        if elapsed < 60 { return "刚刚" }
        if elapsed < 3600 { return "\(Int(elapsed / 60)) 分钟前" }
        if elapsed < 86400 { return "\(Int(elapsed / 3600)) 小时前" }
        if elapsed < 7 * 86400 { return "\(Int(elapsed / 86400)) 天前" }
        let calendar = Calendar.current, date = Date(timeIntervalSince1970: item.createdAt / 1000)
        return "\(calendar.component(.month, from: date))/\(calendar.component(.day, from: date))"
    }
}

private struct ThemeGlyph: Shape {
    let mode: String
    func path(in rect: CGRect) -> Path {
        var path = Path()
        if mode == "light" {
            path.addEllipse(in: CGRect(x: 7, y: 7, width: 10, height: 10))
            let rays: [(CGPoint, CGPoint)] = [
                (.init(x: 12, y: 2), .init(x: 12, y: 4)), (.init(x: 12, y: 20), .init(x: 12, y: 22)),
                (.init(x: 2, y: 12), .init(x: 4, y: 12)), (.init(x: 20, y: 12), .init(x: 22, y: 12)),
                (.init(x: 5, y: 5), .init(x: 6.5, y: 6.5)), (.init(x: 17.5, y: 17.5), .init(x: 19, y: 19)),
                (.init(x: 5, y: 19), .init(x: 6.5, y: 17.5)), (.init(x: 17.5, y: 6.5), .init(x: 19, y: 5))
            ]
            for (start, end) in rays { path.move(to: start); path.addLine(to: end) }
        } else if mode == "dark" {
            path.move(to: CGPoint(x: 20.5, y: 13.5))
            path.addCurve(to: CGPoint(x: 11, y: 21), control1: CGPoint(x: 19.5, y: 18), control2: CGPoint(x: 16, y: 21))
            path.addCurve(to: CGPoint(x: 3, y: 13), control1: CGPoint(x: 6.5, y: 21), control2: CGPoint(x: 3, y: 17.5))
            path.addCurve(to: CGPoint(x: 10.5, y: 3.5), control1: CGPoint(x: 3, y: 8), control2: CGPoint(x: 6.5, y: 4.5))
            path.addCurve(to: CGPoint(x: 12, y: 12), control1: CGPoint(x: 8, y: 6), control2: CGPoint(x: 8.5, y: 9.5))
            path.addCurve(to: CGPoint(x: 20.5, y: 13.5), control1: CGPoint(x: 14.5, y: 15.5), control2: CGPoint(x: 18, y: 16))
            path.closeSubpath()
        } else {
            path.addRoundedRect(in: CGRect(x: 2, y: 3, width: 20, height: 14), cornerSize: CGSize(width: 2, height: 2))
            path.move(to: CGPoint(x: 12, y: 17)); path.addLine(to: CGPoint(x: 12, y: 21))
            path.move(to: CGPoint(x: 8, y: 21)); path.addLine(to: CGPoint(x: 16, y: 21))
        }
        return path.applying(CGAffineTransform(scaleX: rect.width / 24, y: rect.height / 24)
            .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
    }
}

private struct LibraryGlyph: Shape {
    let kind: AppController.Filter
    func path(in rect: CGRect) -> Path {
        var path = Path()
        switch kind {
        case .all:
            for x in [3, 14] { for y in [3, 14] {
                path.addRoundedRect(in: CGRect(x: CGFloat(x), y: CGFloat(y), width: 7, height: 7), cornerSize: CGSize(width: 1, height: 1))
            } }
        case .image:
            path.addRoundedRect(in: CGRect(x: 3, y: 3, width: 18, height: 18), cornerSize: CGSize(width: 2, height: 2))
            path.addEllipse(in: CGRect(x: 7, y: 7, width: 3, height: 3))
            path.move(to: CGPoint(x: 3, y: 18)); path.addLine(to: CGPoint(x: 10, y: 11))
            path.addLine(to: CGPoint(x: 14, y: 15)); path.addLine(to: CGPoint(x: 18, y: 11)); path.addLine(to: CGPoint(x: 21, y: 14))
        case .pinned:
            path.move(to: CGPoint(x: 9, y: 3)); path.addLine(to: CGPoint(x: 15, y: 3))
            path.addLine(to: CGPoint(x: 15, y: 9)); path.addLine(to: CGPoint(x: 19, y: 13))
            path.addLine(to: CGPoint(x: 19, y: 16)); path.addLine(to: CGPoint(x: 5, y: 16))
            path.addLine(to: CGPoint(x: 5, y: 13)); path.addLine(to: CGPoint(x: 9, y: 9)); path.closeSubpath()
            path.move(to: CGPoint(x: 12, y: 16)); path.addLine(to: CGPoint(x: 12, y: 22))
        case .text: break
        }
        return path.applying(CGAffineTransform(scaleX: rect.width / 24, y: rect.height / 24)
            .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
    }
}

private struct KeyBadge: View {
    let text: String
    let palette: ClipboardPalette
    var primary = false
    var compact = false
    var body: some View {
        Text(text).font(.system(size: 10, design: .monospaced))
            .foregroundColor(primary ? .white : compact ? palette.muted : palette.subtle)
            .padding(.horizontal, compact ? 5 : 6).padding(.vertical, 2)
            .background(primary ? Color.white.opacity(0.12) : palette.key.opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
    }
}

private struct ClipboardControlStyle: ButtonStyle {
    let palette: ClipboardPalette
    var active = false
    var danger = false
    var radius: CGFloat = 8
    var tinted = false
    var quiet = false
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(active ? tinted ? palette.accent : .white : hovered ? danger ? palette.danger : palette.foreground : palette.muted)
            .background(active ? tinted ? palette.accentSoft : palette.accent : hovered ? danger ? palette.danger.opacity(0.1) : palette.hover : quiet ? .clear : palette.control,
                        in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(active ? tinted ? palette.accent.opacity(0.16) : palette.accent : hovered ? danger ? palette.danger.opacity(0.4) : palette.strongBorder : quiet ? .clear : palette.border, lineWidth: 1))
            .opacity(enabled ? 1 : 0.38)
            .offset(y: configuration.isPressed ? 1 : 0)
            .onHover { hovered = $0 }
    }
}

private struct ClipboardSidebarStyle: ButtonStyle {
    let palette: ClipboardPalette
    let active: Bool
    @State private var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(active || hovered ? palette.foreground : palette.muted)
            .background(active ? palette.accentSoft : hovered ? palette.hover : .clear, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(active ? palette.accent.opacity(0.16) : hovered ? palette.border : .clear, lineWidth: 1))
            .onHover { hovered = $0 }
    }
}

private struct ClipboardThemeStyle: ButtonStyle {
    let palette: ClipboardPalette
    let active: Bool
    @State private var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundColor(active ? palette.accent : palette.subtle)
            .background(active ? palette.surface : hovered ? palette.hover : .clear, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(active ? palette.border : .clear, lineWidth: 1))
            .onHover { hovered = $0 }
    }
}

private struct ClipboardPanelShape: Shape {
    func path(in rect: CGRect) -> Path {
        let r = min(12, min(rect.width, rect.height) / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY)); path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath(); return path
    }
}
