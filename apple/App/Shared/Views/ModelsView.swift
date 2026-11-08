import SwiftUI
import PlamoTranslateCore
#if os(macOS)
import UniformTypeIdentifiers
#endif

struct ModelsView: View {
    @EnvironmentObject var model: AppModel
    #if os(macOS)
    @State private var importing = false
    #endif

    var body: some View {
        List {
            Section {
                Text("この端末のメモリ: 約 \(String(format: "%.1f", DeviceInfo.ramGB)) GB")
                    .font(.callout)
                Text("モデルは Hugging Face から端末内にダウンロードされ、翻訳は端末上だけで実行されます。大きなモデルはWi-Fi接続での取得を推奨します。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("モデル") {
                ForEach(model.models) { spec in
                    ModelRow(spec: spec)
                }
            }
            #if os(macOS)
            Section {
                Button { importing = true } label: { Label("GGUFファイルを読み込む…", systemImage: "square.and.arrow.down") }
                if let e = model.errorMessage { Text(e).font(.caption).foregroundStyle(.red) }
            } footer: {
                Text("すでに入手済みの PLaMo 3 Translate の GGUF を取り込めます。")
            }
            #endif
        }
        .navigationTitle("モデル")
        #if os(macOS)
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [UTType(filenameExtension: "gguf") ?? .data]) { result in
            if case .success(let url) = result {
                Task { await model.importGGUF(url: url) }
            }
        }
        #endif
    }
}

struct ModelRow: View {
    @EnvironmentObject var model: AppModel
    let spec: ModelSpec
    @State private var showAdvanced = false
    @State private var confirmDelete = false

    private var file: ModelFile { model.selectedFile(for: spec) }
    private var installed: Bool { model.isInstalled(file) }
    private var isDownloading: Bool { model.downloading.contains(file.file) }
    private var ramShort: Bool { DeviceInfo.isShort(minRamGB: spec.minRamGB) }
    /// iOS では不足時に実行を許可しない（Mac は許可して警告のみ）
    private var blocked: Bool { ramShort && !DeviceInfo.isMac }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("PLaMo 3 Translate \(spec.label)").font(.headline)
                if model.isActive(spec) { StatusBadge(text: "使用中", color: .green) }
                if model.recommendedModelIDs.contains(spec.id) { StatusBadge(text: "おすすめ", color: .blue) }
                Spacer()
            }
            Text(spec.description).font(.callout).foregroundStyle(.secondary)
            Text("サイズ \(formatBytes(file.sizeBytes)) ・ 必要メモリ目安 \(spec.minRamGB) GB ・ \(file.quant)")
                .font(.caption).foregroundStyle(.secondary)

            if ramShort {
                Label(DeviceInfo.isMac
                      ? "この Mac のメモリ(約\(Int(DeviceInfo.ramGB)) GB)では動作が遅くなる、または失敗する可能性があります。"
                      : "この端末のメモリでは動作しません（\(spec.minRamGB) GB 以上が必要）。",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            } else if spec.size.lowercased() == "8b", DeviceInfo.isPhone {
                Label("iPhone では 8GB 以上のメモリ搭載機種でのみ動作します。他のアプリを終了してお使いください。",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }

            controls

            if let err = model.downloadErrors[file.file] {
                Text(err).font(.caption).foregroundStyle(.red)
            }

            DisclosureGroup("詳細設定（量子化）", isExpanded: $showAdvanced) {
                Picker("量子化", selection: Binding(get: { file.quant },
                                                  set: { q in
                    if let f = spec.files.first(where: { $0.quant == q }) { model.chooseQuant(f, for: spec) }
                })) {
                    ForEach(spec.files, id: \.quant) { f in
                        Text("\(f.quant)（\(formatBytes(f.sizeBytes))）\(model.isInstalled(f) ? " ✓" : "")").tag(f.quant)
                    }
                }
                Text("Q4_K_M が標準です。数字が小さいほど軽量ですが精度が下がります。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .font(.callout)
        }
        .padding(.vertical, 4)
        .confirmationDialog("このモデルファイルを削除しますか？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("削除", role: .destructive) { model.delete(file) }
        }
    }

    @ViewBuilder
    private var controls: some View {
        if isDownloading {
            HStack {
                if let p = model.progress(for: file) {
                    ProgressView(value: p) { EmptyView() } currentValueLabel: { Text("\(Int(p * 100))%").font(.caption) }
                } else {
                    ProgressView()
                }
                Button("キャンセル", role: .cancel) { model.cancelDownload(file) }.buttonStyle(.borderless)
            }
        } else if installed {
            HStack {
                if model.settings.modelID == spec.id && model.settings.quant == file.quant {
                    Text("選択中").font(.callout).foregroundStyle(.secondary)
                } else {
                    Button("使用する") { model.activate(spec, file: file) }
                        .buttonStyle(.borderedProminent).disabled(blocked)
                }
                Spacer()
                Button("削除", role: .destructive) { confirmDelete = true }.buttonStyle(.borderless)
            }
        } else {
            Button { model.download(spec, file: file) } label: {
                Label("ダウンロード（\(formatBytes(file.sizeBytes))）", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.borderedProminent)
            .disabled(blocked)
        }
    }
}
