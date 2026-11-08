import SwiftUI

struct HistoryView: View {
    @EnvironmentObject var model: AppModel
    var onSelect: () -> Void = {}
    @State private var confirmClear = false

    var body: some View {
        Group {
            if model.history.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock").font(.largeTitle).foregroundStyle(.secondary)
                    Text("翻訳履歴はまだありません").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(model.history) { entry in
                        Button {
                            model.restore(entry)
                            onSelect()
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.source).lineLimit(2).foregroundStyle(.primary)
                                Text(entry.translation).lineLimit(2).foregroundStyle(.secondary)
                                Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { model.deleteHistory(at: $0) }
                }
            }
        }
        .navigationTitle("履歴")
        .toolbar {
            ToolbarItem {
                Button("すべて削除", role: .destructive) { confirmClear = true }
                    .disabled(model.history.isEmpty)
            }
        }
        .confirmationDialog("翻訳履歴をすべて消去しますか？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("消去", role: .destructive) { model.clearHistory() }
        }
    }
}
