import AppKit
import SwiftUI

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// Colors modeled on Gmail's current web design, with dark-mode equivalents.
enum Theme {
    static func color(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            NSColor(hex: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light)
        })
    }

    static let canvas = color(0xF6F8FC, 0x1B1C1E)
    static let surface = color(0xFFFFFF, 0x26272A)
    static let unreadRow = color(0xFFFFFF, 0x2E2F33)
    static let readRow = color(0xF2F6FC, 0x232427)
    static let checkedRow = color(0xC2DBFF, 0x0B3A63)
    static let rowDivider = color(0xECEFF3, 0x323337)
    static let divider = color(0xE3E3E3, 0x3C3D41)
    static let outline = color(0x747775, 0x8E918F)
    static let hover = color(0xE9EBEF, 0x37383C)
    static let navSelected = color(0xD3E3FD, 0x004A77)
    static let navSelectedText = color(0x001D35, 0xC2E7FF)
    static let compose = color(0xC2E7FF, 0x004A77)
    static let composeText = color(0x001D35, 0xC2E7FF)
    static let composeHeader = color(0xF2F6FC, 0x323337)
    static let search = color(0xE9EEF6, 0x303134)
    static let text = color(0x1F1F1F, 0xE3E3E3)
    static let secondaryText = color(0x444746, 0xC4C7C5)
    static let mutedText = color(0x5F6368, 0x9AA0A6)
    static let accent = color(0x0B57D0, 0xA8C7FA)
    static let onAccent = color(0xFFFFFF, 0x062E6F)
    static let link = color(0x1155CC, 0x8AB4F8)
    static let chip = color(0xDDE3EA, 0x3C3D41)
    static let star = color(0xF4B400, 0xFDD663)
    static let danger = color(0xC5221F, 0xF28B82)
    static let warning = color(0xB06000, 0xFCAD70)
    static let badge = color(0xC5221F, 0xF28B82)
    static let snackbar = color(0x303030, 0xE3E3E3)
    static let snackbarText = color(0xF2F2F2, 0x1F1F1F)
    static let snackbarAction = color(0xA8C7FA, 0x0B57D0)

    private static let avatarPalette: [UInt32] = [0x1A73E8, 0xD93025, 0x188038, 0xE37400, 0x9334E6, 0x12B5CB, 0xE52592, 0x795548]
    private static let accountPalette: [UInt32] = [0x1A73E8, 0xD93025, 0x188038, 0xE37400, 0x9334E6, 0x12B5CB]

    static func avatarColor(for key: String) -> Color {
        // A stable hash, so a sender keeps the same color between launches.
        let value = key.lowercased().unicodeScalars.reduce(7) { ($0 &* 31 &+ Int($1.value)) & 0xFFFFF }
        return Color(nsColor: NSColor(hex: avatarPalette[value % avatarPalette.count]))
    }

    static func accountColor(_ index: Int) -> Color {
        Color(nsColor: NSColor(hex: accountPalette[index % accountPalette.count]))
    }
}

extension Account {
    var color: Color { Theme.accountColor(colorIndex) }
    var title: String { displayName.isEmpty ? email : displayName }
}

struct Avatar: View {
    let name: String
    let size: CGFloat
    var color: Color? = nil

    var body: some View {
        ZStack {
            Circle().fill(color ?? Theme.avatarColor(for: name))
            Text(initial)
                .font(.system(size: size * 0.46, weight: .medium))
                .foregroundStyle(Color.white)
        }
        .frame(width: size, height: size)
    }

    private var initial: String {
        let trimmed = name.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        return trimmed.first.map { String($0).uppercased() } ?? "?"
    }
}

struct IconButton: View {
    let systemName: String
    let help: String
    var size: CGFloat = 40
    var iconSize: CGFloat = 16
    var tint: Color = Theme.secondaryText
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: iconSize))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .background(hover ? Theme.hover : Color.clear, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hover = $0 }
    }
}

struct PillButton: View {
    let title: String
    let icon: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                Text(title)
            }
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(Theme.secondaryText)
            .padding(.horizontal, 20)
            .frame(height: 36)
            .background(hover ? Theme.hover : Color.clear, in: Capsule())
            .overlay(Capsule().stroke(Theme.outline, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct LabelChip: View {
    let name: String
    var body: some View {
        Text(name)
            .font(.system(size: 12))
            .foregroundStyle(Theme.secondaryText)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Theme.chip, in: RoundedRectangle(cornerRadius: 4))
    }
}

/// A small menu button with no arrow, for toolbars.
struct ToolbarMenu<Content: View>: View {
    let systemName: String
    let help: String
    let content: Content

    init(systemName: String, help: String, @ViewBuilder content: () -> Content) {
        self.systemName = systemName
        self.help = help
        self.content = content()
    }

    var body: some View {
        Menu {
            content
        } label: {
            Image(systemName: systemName).font(.system(size: 16))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 40, height: 40)
        .help(help)
    }
}

enum DateText {
    static func short(_ date: Date) -> String {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        if calendar.isDateInToday(date) {
            formatter.timeStyle = .short
            formatter.dateStyle = .none
        } else if calendar.isDate(date, equalTo: Date(), toGranularity: .year) {
            formatter.setLocalizedDateFormatFromTemplate("MMMd")
        } else {
            formatter.dateStyle = .short
            formatter.timeStyle = .none
        }
        return formatter.string(from: date)
    }

    /// Gmail's conversation style, such as "Thu, Nov 5, 3:14 PM (2 days ago)".
    static func conversation(_ date: Date) -> String {
        let formatter = DateFormatter()
        if Calendar.current.isDateInToday(date) {
            formatter.timeStyle = .short
            formatter.dateStyle = .none
        } else {
            let sameYear = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year)
            formatter.setLocalizedDateFormatFromTemplate(sameYear ? "EEEMMMdjmm" : "EEEMMMdyjmm")
        }
        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .full
        return formatter.string(from: date) + " (" + relative.localizedString(for: date, relativeTo: Date()) + ")"
    }

    static func full(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
