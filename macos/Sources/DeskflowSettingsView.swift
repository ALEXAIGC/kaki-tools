import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct DeskflowSettingsView: View {
    @ObservedObject var service: DeskflowService
    @State private var hostname = ""
    @State private var serverFingerprint = ""
    @State private var selectedDevice: String?
    @State private var importError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Image(systemName: "desktopcomputer.and.macbook").font(.title2)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("跨屏键鼠").font(.title2.bold())
                        Text("在局域网中共享键盘、鼠标和剪贴板。")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                GroupBox {
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(service.componentAvailable ? "Deskflow 组件已安装" : "需要单独安装 Deskflow 组件")
                            Text("主应用不包含跨屏运行库。请选择下载并解压后的 DeskflowRuntime.bundle。")
                                .font(.caption).foregroundStyle(.secondary)
                            Text("跨屏组件可能需要单独的辅助功能权限。如提示未授权，请在系统设置中另外允许 DeskflowRuntime 或 deskflow-core。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(service.componentAvailable ? "更换组件…" : "导入组件…", action: chooseComponent)
                            .disabled(service.role != "idle")
                    }.padding(6)
                }
                HStack {
                    Circle().fill(service.peer == nil ? Color.secondary : Color.green).frame(width: 8, height: 8)
                    Text(service.statusText).font(.callout)
                    Spacer()
                    if service.role != "idle" { Button("停止") { service.stop(); selectedDevice = nil } }
                }
                if let message = importError ?? service.error {
                    Text(message).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                }
                GroupBox("这台 Mac 作为主机") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("在其他设备输入本机地址和指纹。连接使用 TLS 加密，客户端核对主机指纹。")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("开启主机") { importError = nil; service.startHost() }
                            .disabled(!service.componentAvailable || service.role == "host")
                        if !service.fingerprint.isEmpty {
                            copyRow("主机指纹", value: service.fingerprint)
                        }
                        ForEach(Array(service.addresses.enumerated()), id: \.offset) { entry in
                            copyRow(entry.offset == 0 ? "本机地址" : "其它地址", value: entry.element)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                }
                GroupBox("这台 Mac 连接其他主机") {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("主机 IP 地址", text: $hostname)
                        TextField("主机的 SHA-256 指纹", text: $serverFingerprint)
                        Button("连接") { importError = nil; service.connect(host: hostname, fingerprint: serverFingerprint) }
                            .disabled(!service.componentAvailable || hostname.trimmingCharacters(in: .whitespaces).isEmpty || serverFingerprint.trimmingCharacters(in: .whitespaces).isEmpty)
                    }.textFieldStyle(.roundedBorder).padding(6)
                }
                if service.role == "host" && !service.layout.isEmpty {
                    GroupBox("设备位置") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(selectedDevice.map { "已选择 \($0)，请点击空白位置移动。" } ?? "先点击设备，再点击空白位置。相邻格子之间可以切换鼠标。")
                                .font(.caption).foregroundStyle(.secondary)
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5), spacing: 6) {
                                ForEach(0..<15, id: \.self) { index in
                                    gridCell(col: index % 5, row: index / 5)
                                }
                            }
                        }.padding(6)
                    }
                }
            }.padding(24)
        }.frame(minWidth: 560, minHeight: 580)
    }

    private func copyRow(_ title: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(title).font(.caption).frame(width: 70, alignment: .leading)
            Text(value).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            Spacer(minLength: 8)
            Button("复制") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) }
        }
    }

    private func gridCell(col: Int, row: Int) -> some View {
        let position = DeskflowPosition(col: col, row: row)
        let name = service.layout.first(where: { $0.value == position })?.key
        return Button {
            if let name { selectedDevice = name }
            else if let selectedDevice, service.setLayout(name: selectedDevice, col: col, row: row) { self.selectedDevice = nil }
        } label: {
            VStack(spacing: 5) {
                Image(systemName: name == nil ? "plus" : "desktopcomputer")
                Text(name.map { $0 == service.deviceName ? "本机" : $0 } ?? "空位置").font(.caption).lineLimit(2)
            }.frame(maxWidth: .infinity, minHeight: 62)
        }
        .buttonStyle(.plain)
        .background(selectedDevice == name && name != nil ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(selectedDevice == name && name != nil ? Color.accentColor : .clear))
        .accessibilityLabel(name ?? "空位置，第\(row + 1)行第\(col + 1)列")
    }

    private func chooseComponent() {
        let panel = NSOpenPanel()
        panel.title = "导入 Deskflow 跨屏组件"
        panel.allowedContentTypes = [.bundle]
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do { try service.importComponent(from: url); importError = nil }
        catch { importError = error.localizedDescription }
    }
}
