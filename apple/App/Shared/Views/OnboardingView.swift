import SwiftUI
import PlamoTranslateCore

struct OnboardingView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("hasOnboarded") private var hasOnboarded = false

    private var spec: ModelSpec { ModelCatalog.defaultModel }
    private var file: ModelFile { spec.defaultFile }

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 0)
            Image(systemName: "character.bubble.fill")
                .font(.system(size: 56)).foregroundStyle(.tint)
            Text("PLaMo Translate へようこそ").font(.title2.bold())
            Text("翻訳はすべて端末の中で行われます。最初に翻訳モデル（PLaMo 3 Translate \(spec.label)、\(formatBytes(file.sizeBytes))）をダウンロードします。")
                .multilineTextAlignment(.center)
            Label("データ量が大きいため、Wi-Fi 接続での取得をおすすめします。", systemImage: "wifi")
                .font(.callout).foregroundStyle(.secondary)

            if model.downloading.contains(file.file) {
                VStack(spacing: 6) {
                    if let p = model.progress(for: file) {
                        ProgressView(value: p)
                        Text("\(Int(p * 100))%").font(.caption)
                    } else {
                        ProgressView()
                    }
                    Button("キャンセル", role: .cancel) { model.cancelDownload(file) }
                }
            } else {
                Button {
                    model.download(spec, file: file)
                } label: {
                    Text("ダウンロード（\(formatBytes(file.sizeBytes))）").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                Button("あとで") { hasOnboarded = true }
            }
            if let e = model.downloadErrors[file.file] {
                Text(e).font(.caption).foregroundStyle(.red)
            }
            Spacer(minLength: 0)
        }
        .padding(28)
        .frame(maxWidth: 480)
        .onChange(of: model.hasAnyInstalledModel) { _, installed in
            if installed { hasOnboarded = true }
        }
    }
}

struct OnboardingSheet: ViewModifier {
    @EnvironmentObject var model: AppModel
    @AppStorage("hasOnboarded") private var hasOnboarded = false

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(
            get: { !hasOnboarded && !model.hasAnyInstalledModel },
            set: { if !$0 { hasOnboarded = true } }
        )) {
            OnboardingView()
                .environmentObject(model)
                .interactiveDismissDisabled()
        }
    }
}

extension View {
    func onboardingSheet() -> some View { modifier(OnboardingSheet()) }
}
