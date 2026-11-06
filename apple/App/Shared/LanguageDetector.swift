import Foundation
import NaturalLanguage
import PlamoTranslateCore

/// NaturalLanguage による端末内の言語検出。確信度が低い / 未対応言語は nil。
enum LanguageDetector {
    static let minConfidence = 0.6

    static func detect(_ text: String) -> String? {
        let sample = String(text.prefix(1000))
        guard sample.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        let hyp = recognizer.languageHypotheses(withMaximum: 3)
        guard let best = hyp.max(by: { $0.value < $1.value }), best.value >= minConfidence else { return nil }
        let code = best.key.rawValue.lowercased()   // 例: "zh-hans", "ja", "en"
        let supported = Set(LanguageCatalog.all.map { $0.code })
        if supported.contains(code) { return code }
        if code == "zh" { return "zh-hans" }
        return nil
    }
}
