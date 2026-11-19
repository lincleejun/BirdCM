import SwiftUI
import ImageIO

/// What a tapped picture shows full screen (owner 2026-11-19: every image opens one viewer).
enum ImageViewerSource: Hashable, Identifiable {
    /// A record's local original, opened zoomed onto bird `index` (nil: the whole photo). `record`: offer 查看原图记录
    /// (false where that record's page is already showing, e.g. the result hero).
    case photo(id: UUID, boxes: [[Double]], crops: [[Double]]?, index: Int?, record: Bool = true)
    /// A reference image: `url` is the larger rendition (https on a Reference host, fetched through Reference.shared,
    /// or a cached file URL); the credit as the species page shows it, NC labelled, and the source (file) page.
    case web(url: URL, author: String, licence: String, licenceURL: URL?, nc: Bool, page: URL?)
    var id: Self { self }
}

extension View {
    /// Only the picture opens the viewer (a tap gesture on it wins over the row's button), so a row's own tap keeps navigating.
    /// `before` runs before a record opens from the viewer (e.g. dismiss the sheet the picture sits in).
    func opensImageViewer(_ source: ImageViewerSource, before: (() -> Void)? = nil) -> some View {
        modifier(OpensImageViewer(source: source, before: before))
    }
}

struct OpensImageViewer: ViewModifier {
    @Environment(AppModel.self) var model
    let source: ImageViewerSource
    var before: (() -> Void)?
    @State private var shown: ImageViewerSource?
    @State private var opening: (UUID, Int?)?
    func body(content: Content) -> some View {
        // A gesture hidden from accessibility, not a nested Button: a nested element in a row takes the row's identifier and
        // activation (VoiceOver's double tap would open the viewer, not the record). ponytail: VoiceOver opens the viewer
        // from the result hero (its 查看大图 action), not from lists.
        content.contentShape(Rectangle()).onTapGesture { shown = source }.accessibilityHidden(true)
        .fullScreenCover(item: $shown, onDismiss: {
            guard let (id, index) = opening else { return }
            opening = nil; before?(); model.open(id, subject: index)
        }) { ImageViewer(source: $0) { opening = ($0, $1) }.tint(Palette.accent).debugAppearance() }
    }
}

/// Full-screen, zoomable (PhotoView: pinch, double tap). A photo is the original via ImageIO, downsampled to at most
/// `maxEdge` px and EXIF-upright, never a full decode; it opens on the bird's display crop.
struct ImageViewer: View {
    @Environment(AppModel.self) var model
    @Environment(\.dismiss) var dismiss
    let source: ImageViewerSource
    /// 查看原图记录: the viewer closes, then the caller opens the record (after the cover is gone).
    var openRecord: ((UUID, Int?) -> Void)?
    @State private var image: UIImage?
    @State private var focus: [Double]?
    @State private var failed = false
    /// PhotoView needs a record; a fixed blank one keeps the zoom across updates.
    @State private var blank = Record(boxes: [], selected: 0, result: nil, shooting: Shooting(data: Data()), place: nil)

    nonisolated static let maxEdge = 4096
    /// Decode size: the long side, capped (4096 px is past 1:1 at the 5× zoom limit on any phone screen).
    nonisolated static func edge(_ size: CGSize) -> Int { max(1, min(maxEdge, Int(max(size.width, size.height)))) }
    /// The bird's window, normalized upright: the stored display crop, else the one DisplayCrop makes now.
    nonisolated static func focus(size: CGSize, boxes: [[Double]], crops: [[Double]]?, index: Int?) -> [Double]? {
        guard let i = index, boxes.indices.contains(i) else { return nil }
        return crops?[safe: i] ?? DisplayCrop.make(size: size, box: boxes[i]).normalized(in: size)
    }
    nonisolated static func zoomRect(_ w: [Double], in canvas: CGSize) -> CGRect {
        CGRect(x: w[0] * canvas.width, y: w[1] * canvas.height, width: (w[2] - w[0]) * canvas.width, height: (w[3] - w[1]) * canvas.height)
    }
    nonisolated static func fit(_ image: CGSize, in bounds: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0 else { return bounds }
        let k = min(bounds.width / image.width, bounds.height / image.height)
        return CGSize(width: image.width * k, height: image.height * k)
    }
    nonisolated static func original(_ url: URL, boxes: [[Double]], crops: [[Double]]?, index: Int?) -> (CGImage, [Double]?)? {
        guard let s = CropSource(url), let img = s.image(window: [0, 0, 1, 1], edge: edge(s.size)) else { return nil }
        return (img, focus(size: s.size, boxes: boxes, crops: crops, index: index))
    }
    nonisolated static func decode(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                                           kCGImageSourceThumbnailMaxPixelSize: maxEdge] as CFDictionary)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark").font(.body.weight(.semibold)).frame(width: 44, height: 44) }
                    .accessibilityLabel("关闭").accessibilityIdentifier("viewer.close")
            }.padding(.horizontal, 8)
            Group {
                if let image {
                    PhotoView(image: image, record: blank, marks: false, drawing: false, neutral: true, focus: focus, onSelect: { _ in }, onDraw: { _ in })
                        .accessibilityIdentifier("viewer.photo")
                } else if failed {
                    ContentUnavailableView("图片不可用", systemImage: "photo")
                } else { ProgressView() }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            footer.padding(16)
        }
        .background(Color(uiColor: .secondarySystemBackground))
        .task { await load() }
    }

    @ViewBuilder var footer: some View {
        switch source {
        case let .photo(id, _, _, index, record):
            if record {
                Button { openRecord?(id, index); dismiss() } label: { Label("查看原图记录", systemImage: "doc.text.image").frame(maxWidth: .infinity) }
                    .buttonStyle(PrimaryActionStyle(height: 44)).accessibilityIdentifier("viewer.record")
            }
        case let .web(_, author, licence, licenceURL, nc, page):
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text("照片：\(author)")
                    Text("·")
                    if let licenceURL { Link(licence, destination: licenceURL) } else { Text(licence) }
                    if nc { Text("非商业许可（NC）").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2).overlay(Capsule().stroke(Palette.warning)).foregroundStyle(Palette.warning) }
                }
                if let page { Link("来源页面", destination: page).frame(minHeight: 44).accessibilityIdentifier("viewer.source") }
            }.font(.footnote).foregroundStyle(Palette.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    func load() async {
        let out: (CGImage, [Double]?)?
        switch source {
        case let .photo(id, boxes, crops, index, _):
            guard let url = model.url(id) else { failed = true; return }
            out = await Task.detached { ImageViewer.original(url, boxes: boxes, crops: crops, index: index) }.value
        case let .web(url, _, _, _, _, _):
            var data: Data?
            if url.isFileURL { data = try? Data(contentsOf: url) }
            // ponytail: 4× the 640 px cap for the larger rendition; raise if Commons' size choice grows.
            else if Reference.enabled { data = try? await Reference.shared.net.get(url.absoluteString, limit: 4 * Reference.maxImage, accept: "image/*").0 }
            out = await Task.detached { data.flatMap(ImageViewer.decode).map { ($0, nil) } }.value
        }
        guard !Task.isCancelled else { return }
        if let out { focus = out.1; image = UIImage(cgImage: out.0) } else { failed = true }
    }
}

extension ImageViewerSource {
    /// The viewer for a reference card: iNaturalist photos at their "large" (1024 px) size, Commons files at 1280 px
    /// via Special:FilePath (redirects stay on the Reference hosts). nil when the card has no licensed picture.
    static func reference(_ c: Reference.Card) -> ImageViewerSource? {
        guard ["ok", "stale"].contains(c.state), let licence = c.licence, let file = c.file else { return nil }
        let big: String? = file.hasPrefix("https://") ? Thumb.photoURL(file, "large")
            : file.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed).map { "https://commons.wikimedia.org/wiki/Special:FilePath/\($0)?width=1280" }
        guard let s = big, let url = URL(string: s) else { return nil }
        return .web(url: url, author: c.author ?? c.attribution ?? "", licence: licence, licenceURL: c.licenceURL.flatMap(URL.init(string:)),
                    nc: c.nc == true, page: c.sourceURL.flatMap(URL.init(string:)))
    }
}

/// `opensImageViewer` only when there is something to open (a placeholder thumbnail stays a plain row tap).
struct OptionalViewer: ViewModifier {
    let source: ImageViewerSource?
    func body(content: Content) -> some View {
        if let source { content.opensImageViewer(source) } else { content }
    }
}
