import SwiftUI
import AppKit

enum SettingsStyle {
    static let accent = Color(red: 0.988, green: 0.388, blue: 0.004)
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development" }
}

struct SettingsWordmark: View {
    var body: some View {
        if let logo = NativeBrand.logo {
            Image(nsImage: logo).resizable().scaledToFill().frame(width: 64, height: 30).clipped()
                .accessibilityLabel("KAKI")
        } else {
            Text("KAKI").font(.system(size: 21, weight: .black)).italic().foregroundStyle(SettingsStyle.accent)
        }
    }
}

struct SettingsCard<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    let title: String
    let subtitle: String?
    let content: Content
    init(_ title: String = "", subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title; self.subtitle = subtitle; self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !title.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    if let subtitle { Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary) }
                }
            }
            content
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(scheme == .dark ? Color.white.opacity(0.035) : Color.white, in: RoundedRectangle(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(scheme == .dark ? 0.09 : 0.065), lineWidth: 1) }
    }
}

struct SettingsRow<Control: View>: View {
    let title: String
    let detail: String?
    let control: Control
    init(_ title: String, detail: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title; self.detail = detail; self.control = control()
    }
    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .medium))
                if let detail { Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            control
        }.padding(.vertical, 9)
    }
}

struct SettingsStatus: View {
    let title: String
    var active = false
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(active ? Color.green : Color.secondary).frame(width: 5, height: 5)
            Text(title).font(.system(size: 11, weight: .medium))
        }.foregroundStyle(active ? Color.green : Color.secondary)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background((active ? Color.green : Color.secondary).opacity(0.08), in: Capsule())
    }
}

struct SettingsFootnote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct SettingsPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .semibold))
            .foregroundStyle(enabled ? Color.white : Color.secondary)
            .padding(.horizontal, 16).padding(.vertical, 9)
            .background(enabled ? SettingsStyle.accent.opacity(configuration.isPressed ? 0.8 : 1) : Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}
