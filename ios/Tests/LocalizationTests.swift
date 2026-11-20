import XCTest
@testable import BirdCM

/// Both string catalogs: every key has zh-Hans and en, en has no Chinese and keeps the key's format specifiers; the built
/// app carries both languages. Chinese literals the compiler does not extract are listed by `tools/check_l10n.py`.
final class LocalizationTests: XCTestCase {
    /// Keys whose en value may contain Chinese (a bird's Chinese name would go here). None today.
    static let chineseInEnglish: Set<String> = []

    func testCatalogsHaveEnglishAndChinese() throws {
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("BirdCM/Resources")
        let chinese = try NSRegularExpression(pattern: "[\\u3000-\\u303f\\u4e00-\\u9fff\\uff00-\\uffef]")
        let spec = try NSRegularExpression(pattern: "%(?:\\d+\\$)?(?:\\.\\d+)?(?:lld|ld|d|@|f|%)")
        func specs(_ s: String) -> [String] {
            spec.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { String(s[Range($0.range, in: s)!]).replacingOccurrences(of: #"\d+\$"#, with: "", options: .regularExpression) }.sorted()
        }
        for name in ["Localizable", "InfoPlist"] {
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: resources.appendingPathComponent(name + ".xcstrings"))) as? [String: Any])
            let strings = try XCTUnwrap(json["strings"] as? [String: [String: Any]])
            XCTAssertGreaterThan(strings.count, 3, name)
            for (key, entry) in strings {
                let l = entry["localizations"] as? [String: [String: Any]] ?? [:]
                guard let zh = forms(l["zh-Hans"]).first, let en = l["en"], !forms(en).isEmpty else { XCTFail("\(name): \(key) lacks zh-Hans or en"); continue }
                for en in forms(en) {
                    if !Self.chineseInEnglish.contains(key) {
                        XCTAssertNil(chinese.firstMatch(in: en, range: NSRange(en.startIndex..., in: en)), "\(name): en of \(key) has Chinese: \(en)")
                    }
                    XCTAssertEqual(specs(en), specs(key), "\(name): \(key) → \(en)")
                }
                XCTAssertEqual(specs(zh), specs(key), "\(name): \(key) → \(zh)")
            }
        }
    }

    /// Every form a localization can show: its string, each plural form, and a string with each substitution's forms put in
    /// (`%#@arg@` → the form, `%arg` → the argument's own positional specifier).
    func forms(_ l: [String: Any]?) -> [String] {
        func unit(_ v: Any?) -> String? { ((v as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String }
        func plural(_ v: Any?) -> [String] { (((v as? [String: Any])?["variations"] as? [String: Any])?["plural"] as? [String: Any])?.values.compactMap(unit) ?? [] }
        guard let l else { return [] }
        guard let value = unit(l) else { return plural(l) }
        var out = [value]
        for (name, sub) in l["substitutions"] as? [String: [String: Any]] ?? [:] {
            let arg = "%\(sub["argNum"] as? Int ?? 0)$\(sub["formatSpecifier"] as? String ?? "")"
            out = out.flatMap { s in plural(sub).map { s.replacingOccurrences(of: "%#@\(name)@", with: $0.replacingOccurrences(of: "%arg", with: arg)) } }
        }
        return out
    }
    /// An English UI shows no Chinese bird name: English first, the Latin under it.
    func testEnglishNamesHaveNoChinese() throws {
        Catalogue.english = true; defer { Catalogue.english = Bundle.main.preferredLocalizations.first == "en" }
        let sp = try XCTUnwrap(Catalogue.shared.species("Tyrannus melancholicus"))
        XCTAssertEqual(sp.name, "Tropical Kingbird"); XCTAssertEqual(sp.alt, "")
        XCTAssertEqual(SpeciesName(key: sp.sci, size: .row).label, "Tropical Kingbird\(String(localized: "，"))Tyrannus melancholicus")
        XCTAssertFalse(Catalogue.shared.all.contains { $0.name.range(of: "\\p{Han}", options: .regularExpression) != nil })
    }

    func testAppBundleCarriesBothLanguages() throws {
        for (lang, rare, unknown, app) in [("en", "Rare", "Time unknown", "GuanYu"), ("zh-Hans", "罕见", "时间未知", "观羽")] {
            let bundle = try XCTUnwrap(Bundle.main.path(forResource: lang, ofType: "lproj").flatMap(Bundle.init(path:)), lang)
            XCTAssertEqual(bundle.localizedString(forKey: "罕见", value: nil, table: nil), rare)
            XCTAssertEqual(bundle.localizedString(forKey: "时间未知", value: nil, table: nil), unknown)  // a manual key (shown through loc)
            // Reference cards store these keys and show them through loc().
            for key in ["维基百科贡献者", "原文摘录", "原文摘录；简体由维基百科自动转换", "缩放为 640 px 宽"] {
                XCTAssertNotEqual(bundle.localizedString(forKey: key, value: "?", table: nil), "?", key)
                XCTAssertEqual(bundle.localizedString(forKey: key, value: nil, table: nil) == key, lang == "zh-Hans", key)
            }
            XCTAssertEqual(bundle.localizedString(forKey: "CFBundleDisplayName", value: nil, table: "InfoPlist"), app)
        }
        // The scheme runs tests in zh-Hans: Chinese stays exactly as before.
        XCTAssertEqual(loc("罕见"), "罕见")
        XCTAssertEqual(Place.display("美国 · 加利福尼亚州"), "美国 · 加利福尼亚州")
    }
}
