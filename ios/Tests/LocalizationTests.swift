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
                let l = entry["localizations"] as? [String: [String: [String: String]]] ?? [:]
                guard let zh = l["zh-Hans"]?["stringUnit"]?["value"], let en = l["en"]?["stringUnit"]?["value"] else { XCTFail("\(name): \(key) lacks zh-Hans or en"); continue }
                if !Self.chineseInEnglish.contains(key) {
                    XCTAssertNil(chinese.firstMatch(in: en, range: NSRange(en.startIndex..., in: en)), "\(name): en of \(key) has Chinese: \(en)")
                }
                XCTAssertEqual(specs(en), specs(key), "\(name): \(key) → \(en)")
                XCTAssertEqual(specs(zh), specs(key), "\(name): \(key) → \(zh)")
            }
        }
    }

    func testAppBundleCarriesBothLanguages() throws {
        for (lang, rare, unknown, app) in [("en", "Rare", "Time unknown", "GuanYu"), ("zh-Hans", "罕见", "时间未知", "观羽")] {
            let bundle = try XCTUnwrap(Bundle.main.path(forResource: lang, ofType: "lproj").flatMap(Bundle.init(path:)), lang)
            XCTAssertEqual(bundle.localizedString(forKey: "罕见", value: nil, table: nil), rare)
            XCTAssertEqual(bundle.localizedString(forKey: "时间未知", value: nil, table: nil), unknown)  // a manual key (shown through loc)
            XCTAssertEqual(bundle.localizedString(forKey: "CFBundleDisplayName", value: nil, table: "InfoPlist"), app)
        }
        // The scheme runs tests in zh-Hans: Chinese stays exactly as before.
        XCTAssertEqual(loc("罕见"), "罕见")
        XCTAssertEqual(Place.display("美国 · 加利福尼亚州"), "美国 · 加利福尼亚州")
    }
}
