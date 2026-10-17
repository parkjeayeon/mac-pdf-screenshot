// 일반 PDF: 화면을 찍지 않고 PDF 파일의 각 쪽을 PDFKit 으로 직접 PNG 렌더링한다.
// 암호가 걸렸거나 복사·추출이 제한된 문서는 열지 않는다 (그런 문서는 화면 캡처 방식을 쓴다).

import AppKit
import Foundation
import PDFKit
import UniformTypeIdentifiers

/// 선명도 프리셋 (DPI)
public enum PDFQuality: Int, CaseIterable, Identifiable {
    case screen = 100
    case standard = 150
    case high = 200
    case print = 300
    case max = 600

    public var id: Int { rawValue }
    public var dpi: CGFloat { CGFloat(rawValue) }

    public var label: String {
        switch self {
        case .screen: return "화면용 (100 DPI)"
        case .standard: return "표준 (150 DPI)"
        case .high: return "고화질 (200 DPI)"
        case .print: return "인쇄용 (300 DPI)"
        case .max: return "최고 (600 DPI)"
        }
    }
}

public struct PDFInfo {
    public let url: URL
    public let pageCount: Int
    /// 첫 쪽의 크기 (포인트, 회전 반영)
    public let pageSize: CGSize

    /// 첫 쪽을 이 DPI 로 렌더링했을 때의 픽셀 크기
    public func pixelSize(dpi: CGFloat) -> (width: Int, height: Int) {
        renderSize(pageSize, dpi: dpi)
    }
}

/// 한 변이 이보다 크면 줄인다 (A0 를 600 DPI 로 그리면 수 GB 비트맵이 되므로)
let maxRenderSide: CGFloat = 16384

func renderSize(_ points: CGSize, dpi: CGFloat) -> (width: Int, height: Int) {
    var scale = dpi / 72
    let longest = max(points.width, points.height) * scale
    if longest > maxRenderSide { scale *= maxRenderSide / longest }
    return (max(1, Int((points.width * scale).rounded())), max(1, Int((points.height * scale).rounded())))
}

public enum PDFExport {
    /// PDFKit(macOS 내장)을 쓸 수 있는지: 클래스가 로드되고, 메모리에서 1쪽짜리 PDF 를 만들어 렌더링까지 되는지 확인
    public static func checkSupport() -> Result<String, Error> {
        guard NSClassFromString("PDFDocument") != nil else {
            return .failure(PageCapError("PDFKit 프레임워크를 불러오지 못했습니다"))
        }
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 72, height: 72)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            return .failure(PageCapError("테스트 PDF 를 만들지 못했습니다"))
        }
        ctx.beginPDFPage(nil)
        ctx.setFillColor(.black)
        ctx.fill(CGRect(x: 10, y: 10, width: 20, height: 20))
        ctx.endPDFPage()
        ctx.closePDF()
        // 문서를 붙잡아 둬야 한다 (쪽만 남기면 PDFKit 이 그리지 못함)
        let doc = PDFDocument(data: data as Data)
        guard let page = doc?.page(at: 0),
              let png = renderPNG(page, dpi: 72), !png.isEmpty else {
            return .failure(PageCapError("PDFKit 렌더링 테스트에 실패했습니다"))
        }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return .success("PDFKit (macOS \(os.majorVersion).\(os.minorVersion) 내장)")
    }

    /// 변환할 수 있는 PDF 인지 확인하고 연다
    public static func open(_ url: URL) throws -> PDFDocument {
        guard url.pathExtension.lowercased() == "pdf" || (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType?.conforms(to: .pdf)) == true else {
            throw PageCapError("\(url.lastPathComponent) 은(는) PDF 파일이 아닙니다")
        }
        guard let doc = PDFDocument(url: url) else {
            throw PageCapError("\(url.lastPathComponent) 을(를) 열지 못했습니다. 손상되었거나 전용 뷰어(DRM)가 필요한 문서일 수 있습니다 — 화면 캡처 방식을 쓰세요")
        }
        if doc.isLocked {
            throw PageCapError("암호가 걸린 PDF 입니다 — 화면 캡처 방식을 쓰세요")
        }
        if !doc.allowsCopying {
            throw PageCapError("복사·추출이 제한된 PDF 입니다 — 화면 캡처 방식을 쓰세요")
        }
        guard doc.pageCount > 0 else { throw PageCapError("쪽이 없는 PDF 입니다") }
        return doc
    }

    public static func info(_ url: URL) throws -> PDFInfo {
        let doc = try open(url)
        return PDFInfo(url: url, pageCount: doc.pageCount, pageSize: displaySize(doc.page(at: 0)!))
    }

    /// 화면에 보이는 크기 (cropBox, 회전 반영)
    static func displaySize(_ page: PDFPage) -> CGSize {
        let b = page.bounds(for: .cropBox)
        return page.rotation % 180 == 0 ? b.size : CGSize(width: b.height, height: b.width)
    }

    /// 한 쪽을 흰 배경 RGB PNG 로 렌더링
    public static func renderPNG(_ page: PDFPage, dpi: CGFloat) -> Data? {
        let size = displaySize(page)
        let (w, h) = renderSize(size, dpi: dpi)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: CGFloat(w) / size.width, y: CGFloat(h) / size.height)
        page.draw(with: .cropBox, to: ctx)
        guard let image = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    /// 앞·가운데·뒤 쪽을 실제로 렌더링해서 한 쪽당 평균 PNG 크기(바이트)를 추정한다. 오래 걸릴 수 있으니 백그라운드에서 호출.
    public static func estimateBytesPerPage(_ url: URL, dpi: CGFloat, isCancelled: () -> Bool = { false }) throws -> Int {
        let doc = try open(url)
        let n = doc.pageCount
        let samples = Array(Set([0, n / 2, n - 1])).sorted()
        var total = 0
        for i in samples {
            if isCancelled() { throw CancellationError() }
            let bytes = autoreleasepool { doc.page(at: i).flatMap { renderPNG($0, dpi: dpi) }?.count }
            guard let bytes else { throw PageCapError("\(i + 1)쪽 렌더링에 실패했습니다") }
            total += bytes
        }
        return total / samples.count
    }
}

public struct PDFExportConfig {
    public var file: URL
    public var outDir: URL
    public var dpi: CGFloat = PDFQuality.high.dpi
    public var start = 1
    public var overwrite = false

    public init(file: URL, outDir: URL) {
        self.file = file
        self.outDir = outDir
    }
}

/// PDF 의 모든 쪽을 순서대로 PNG 로 저장한다. 이벤트는 CaptureSession 과 같은 형식.
public final class PDFExportSession {
    private let config: PDFExportConfig
    private let onEvent: (CaptureSession.Event) -> Void
    private let lock = NSLock()
    private var cancelled = false

    /// onEvent 는 항상 메인 스레드에서 호출된다
    public init(config: PDFExportConfig, onEvent: @escaping (CaptureSession.Event) -> Void) {
        self.config = config
        self.onEvent = onEvent
    }

    public func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    private var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    private func emit(_ e: CaptureSession.Event) {
        DispatchQueue.main.async { self.onEvent(e) }
    }

    public func start() {
        Thread.detachNewThread { [self] in
            do { try run() } catch { emit(.failed(error.localizedDescription)) }
        }
    }

    private func run() throws {
        let fm = FileManager.default
        let doc = try PDFExport.open(config.file)
        try fm.createDirectory(at: config.outDir, withIntermediateDirectories: true)
        let count = doc.pageCount

        // 덮어쓰기 꺼져 있으면 시작 전에 겹치는 파일이 있는지 먼저 확인 (중간에 멈추지 않게)
        if !config.overwrite {
            for i in 0..<count {
                let name = fileName(for: config.start + i)
                if fm.fileExists(atPath: config.outDir.appendingPathComponent(name).path) {
                    throw PageCapError("\(name) 이(가) 이미 있습니다. 시작 번호를 바꾸거나 덮어쓰기를 켜세요")
                }
            }
        }

        emit(.status("\(config.file.lastPathComponent): \(count)쪽을 \(Int(config.dpi)) DPI 로 변환합니다"))
        var saved = 0
        for i in 0..<count {
            if isCancelled { return emit(.finished(saved: saved, reason: "중지했습니다")) }
            let url = config.outDir.appendingPathComponent(fileName(for: config.start + i))
            try autoreleasepool {
                guard let png = doc.page(at: i).flatMap({ PDFExport.renderPNG($0, dpi: config.dpi) }) else {
                    throw PageCapError("\(i + 1)쪽 렌더링에 실패했습니다")
                }
                try png.write(to: url)
            }
            saved += 1
            emit(.saved(url))
        }
        emit(.finished(saved: saved, reason: "마지막 쪽(\(count)쪽)까지 변환했습니다"))
    }
}
