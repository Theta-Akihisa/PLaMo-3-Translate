import Foundation
import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// MARK: - クリップボード

enum Clipboard {
    static func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }

    static func paste() -> String? {
        #if os(iOS)
        return UIPasteboard.general.string
        #elseif os(macOS)
        return NSPasteboard.general.string(forType: .string)
        #endif
    }
}

// MARK: - 端末情報

enum DeviceInfo {
    static var ramGB: Double {
        Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
    }

    static var isPhone: Bool {
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .phone
        #else
        return false
        #endif
    }

    static var isMac: Bool {
        #if os(macOS)
        return true
        #else
        return false
        #endif
    }

    /// 物理メモリが目安より不足しているか（表示上の誤差のため 10% 余裕を見る）
    static func isShort(minRamGB: Int) -> Bool {
        ramGB < Double(minRamGB) * 0.9
    }
}

func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

// MARK: - 値型

struct GlossaryRow: Identifiable, Equatable {
    var id = UUID()
    var source = ""
    var target = ""
}

struct HistoryEntry: Identifiable, Codable, Equatable {
    var id = UUID()
    var date = Date()
    var source: String
    var translation: String
    /// 原文言語の指定（nil = 自動検出）
    var sourceLang: String?
    var targetLang: String
    /// 自動検出だったときに検出された原文言語（履歴を文脈に使うときの言語の照合用）
    var detectedLang: String?
}

// MARK: - 共通ビュー部品

struct StatusBadge: View {
    let text: String
    var color: Color = .accentColor
    var body: some View {
        Text(text)
            .font(.caption2.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}
