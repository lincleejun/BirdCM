import SwiftUI

/// 物种参考 on the species page (docs/design-species-search.md §4.4, §4.5, §8; web/src/Reference.tsx): the Wikipedia
/// summary and one Commons reference image, each card on its own with its attribution, cache date and retry. Its own
/// labelled block under the person's records: the reference image never takes the hero slot or enters records, grids
/// or stats (docs/design/polish/polish.md 物种 / 探索).
struct SpeciesReferenceSection: View {
    let sci: String
    /// The person has records of this species: the image is a 参考图, otherwise it says it is not their observation.
    let own: Bool
    @State private var summary: Reference.Card?
    @State private var image: Reference.Card?
    @State private var picture: UIImage?
    @State private var links = [(name: String, url: String)]()
    @State private var enabled = Reference.enabled
    @State private var disclosed = Reference.disclosed
    @State private var expanded = false
    private let service = Reference.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("物种参考").font(.headline).accessibilityAddTraits(.isHeader)
            Text("来自 Wikipedia / Wikimedia 的网络资料，不是你的观察。").font(.caption).foregroundStyle(Palette.secondary)
            if !disclosed { disclosure }
            if !enabled {
                HStack {
                    Text("在线资料已关闭：不会联网，只显示已经缓存的资料。").font(.footnote).foregroundStyle(Palette.secondary)
                    Button("打开") { set(enabled: true) }.accessibilityIdentifier("reference.enable")
                }
            }
            imageCard
            summaryCard
            if !links.isEmpty {
                Text("在浏览器里查").font(.subheadline.bold())
                ForEach(links, id: \.name) { l in if let u = URL(string: l.url) { Link(l.name, destination: u).frame(minHeight: 44, alignment: .leading) } }
            }
        }
        .task(id: sci) { await load() }
    }

    var disclosure: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Reference.disclosure).font(.footnote)
            HStack(spacing: 16) {
                Button("知道了") { Reference.disclosed = true; disclosed = true }.foregroundStyle(Palette.onAccent).buttonStyle(.borderedProminent).tint(Palette.accent).accessibilityIdentifier("reference.disclosed")
                Button("关闭在线资料") { Reference.disclosed = true; disclosed = true; set(enabled: false) }.accessibilityIdentifier("reference.disable")
            }
        }.padding(12).background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder var imageCard: some View {
        if let image, ["ok", "stale"].contains(image.state), image.licence != nil, let picture {
            VStack(alignment: .leading, spacing: 6) {
                Image(uiImage: picture).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 260).clipShape(RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel(own ? "网络参考图" : "网络参考图，不是你的观察").accessibilityIdentifier("reference.image")
                    .modifier(OptionalViewer(source: .reference(image)))
                Text(own ? "参考图" : "网络参考图，不是你的观察").font(.caption.bold())
                credit(image).font(.caption).foregroundStyle(Palette.secondary).accessibilityIdentifier("reference.imageCredit")
            }
        } else if let image {
            problem(image, what: String(localized: "可用的授权参考图")) { await refresh("image", force: true) }.accessibilityIdentifier("reference.imageState")
        } else {
            Text("正在读取…").font(.footnote).foregroundStyle(Palette.secondary)
        }
    }

    /// Author → its file page, the exact licence → its deed, NC labelled, the source's own credit line, the changes, the cache date.
    func credit(_ c: Reference.Card) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text("照片：")
                link(c.author ?? String(localized: "作者见 Commons 文件页"), c.sourceURL)
                Text("·")
                link(c.licence ?? "", c.licenceURL)
                if c.nc == true { Text("非商业许可（NC）").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2).overlay(Capsule().stroke(Palette.warning)).foregroundStyle(Palette.warning) }
            }
            if let credit = c.credit, !credit.isEmpty, credit != c.author, credit.lowercased() != "own work" { Text("出处 \(credit)") }
            HStack(spacing: 4) { Text("来源"); link(String(localized: "Wikimedia Commons 文件页"), c.sourceURL) }
            Text([c.changes, c.cachedAt.map { String(localized: "缓存于 \($0)") + (c.state == "stale" ? String(localized: "（离线显示缓存）") : "") }].compactMap { $0 }.joined(separator: " · "))
        }
    }

    @ViewBuilder var summaryCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("简介").font(.subheadline.bold())
                if summary?.lang == "en" { Text("英文资料").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2).background(Palette.surface, in: Capsule()) }
            }
            if let s = summary, ["ok", "stale"].contains(s.state), let text = s.text {
                Text(text).font(.callout).lineLimit(expanded ? nil : 6).environment(\.locale, Locale(identifier: s.lang == "zh" ? "zh-Hans" : "en")).accessibilityIdentifier("reference.summary")
                if text.count > 160 { Button(expanded ? "收起" : "展开") { expanded.toggle() }.font(.footnote) }
                VStack(alignment: .leading, spacing: 2) {
                    Text([s.credit, s.changes].compactMap { $0 }.joined(separator: " · "))
                    HStack(spacing: 4) {
                        link(s.licence ?? "", s.licenceURL); Text("·")
                        link(String(localized: "原文「\(s.title ?? "")」"), s.sourceURL)
                        if s.historyURL != nil { Text("/"); link(String(localized: "历史"), s.historyURL) }
                    }
                    Text([s.revision.map { String(localized: "修订 \($0)") }, s.cachedAt.map { String(localized: "缓存于 \($0)") + (s.state == "stale" ? String(localized: "（离线显示缓存）") : "") }].compactMap { $0 }.joined(separator: " · "))
                }.font(.caption).foregroundStyle(Palette.secondary).accessibilityIdentifier("reference.summaryCredit")
            } else if let s = summary {
                problem(s, what: String(localized: "简介")) { await refresh("summary", force: true) }.accessibilityIdentifier("reference.summaryState")
            } else {
                Text("正在读取…").font(.footnote).foregroundStyle(Palette.secondary)
            }
        }
    }

    @ViewBuilder func link(_ title: String, _ url: String?) -> some View {
        if let url, let u = URL(string: url) { Link(title, destination: u).foregroundStyle(Palette.accent) } else { Text(title) }
    }

    /// The same wording as the desktop page; a retry where asking again can help.
    func problem(_ c: Reference.Card, what: String, retry: @escaping () async -> Void) -> some View {
        let state = c.state == "missing" && !enabled ? "off" : c.state
        let text = switch state {
        case "unmapped": c.why ?? String(localized: "资料未对应")
        case "none": c.why ?? String(localized: "暂无\(what)")
        case "off": String(localized: "在线资料已关闭；打开后才会联网取")
        case "missing": String(localized: "正在取在线资料…")
        case "stale" where c.text == nil && c.licence == nil: c.why ?? String(localized: "在线资料暂不可用（可能离线）")
        default: state == "busy" || c.problem == "busy" ? String(localized: "来源请求较多，稍后可重试") : String(localized: "在线资料暂不可用（可能离线）")
        }
        let again = ["unavailable", "busy", "none"].contains(state) || c.problem != nil
        return HStack(alignment: .firstTextBaseline) {
            Text(text + (c.cachedAt != nil && state != "none" ? String(localized: "（显示 \(c.cachedAt!) 的缓存）") : "")).font(.footnote).foregroundStyle(Palette.secondary)
            if again && enabled { Button("重试") { Task { await retry() } }.font(.footnote) }
        }
    }

    func set(enabled on: Bool) {
        Reference.enabled = on; enabled = on
        if on { Task { await refresh("summary"); await refresh("image") } }
    }

    /// Cache first (no network), then the source for what is due, when online is on.
    func load() async {
        summary = nil; image = nil; picture = nil; expanded = false
        enabled = Reference.enabled; disclosed = Reference.disclosed
        links = await service.links(sci)
        async let s = service.card("summary", sci, network: false)
        async let i = service.card("image", sci, network: false)
        let (sc, ic) = await (s, i)
        guard !Task.isCancelled else { return }
        summary = sc; image = ic; await showPicture()
        guard enabled else { return }
        async let a: Void = sc.due == true ? refresh("summary") : ()
        async let b: Void = ic.due == true ? refresh("image") : ()
        _ = await (a, b)
    }
    func refresh(_ kind: String, force: Bool = false) async {
        let c = await service.card(kind, sci, network: Reference.enabled, force: force)
        guard !Task.isCancelled else { return }
        if kind == "summary" { summary = c } else { image = c; await showPicture() }
    }
    func showPicture() async {
        guard let url = service.cache.image(sci) else { picture = nil; return }
        picture = await Task.detached { UIImage(contentsOfFile: url.path)?.preparingForDisplay() }.value
    }
}

/// 设置 → 在线物种资料: the switch, the disclosure and 删除网络缓存.
struct ReferenceSettingsSection: View {
    @State private var enabled = Reference.enabled
    @State private var size: Int?
    var body: some View {
        Section {
            Toggle("在线物种资料（Wikipedia / Wikimedia / iNaturalist）", isOn: $enabled).accessibilityIdentifier("settings.referenceOnline")
                .onChange(of: enabled) { _, v in Reference.enabled = v; Reference.disclosed = true }
            Button(size.map { String(localized: "删除网络缓存（\(ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file))）") } ?? String(localized: "删除网络缓存")) {
                Reference.shared.cache.clear(); SpeciesThumb.memory.removeAllObjects(); size = 0
            }.disabled(size == 0).accessibilityIdentifier("settings.referenceClear")
        } header: { Text("物种参考") } footer: { Text(Reference.disclosure) }
        .task { let cache = Reference.shared.cache; size = await Task.detached { cache.size() }.value }
    }
}
