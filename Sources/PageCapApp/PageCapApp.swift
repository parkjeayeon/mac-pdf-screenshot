// PageCap GUI — PageCapCore 를 창에서 설정·실행한다.

import AppKit
import PageCapCore
import SwiftUI
import UniformTypeIdentifiers

@main
struct PageCapApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        WindowGroup("PageCap") {
            ContentView()
                .frame(minWidth: 700, minHeight: 600)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // swift build 산출물을 바로 실행해도 일반 앱처럼 Dock·메뉴 막대에 나타나게
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

// MARK: - 모델

/// 백그라운드 작업에 넘기는 취소 표시
final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}

enum Mode: String, CaseIterable, Identifiable {
    case macro, pdf
    var id: String { rawValue }
    var label: String {
        switch self {
        case .macro: return "화면 캡처"
        case .pdf: return "PDF 변환"
        }
    }
    var help: String {
        switch self {
        case .macro: return "뷰어 화면을 쪽마다 찍습니다. 보안이 걸린 PDF 용"
        case .pdf: return "PDF 파일에서 바로 PNG 로 변환합니다. 일반 PDF 용"
        }
    }
}

@MainActor
final class CaptureModel: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var outDir: URL {
        didSet { defaults.set(outDir.path, forKey: "outDir"); start = nextFreeIndex(in: outDir) }
    }
    @Published var twoPage: Bool {
        didSet { defaults.set(twoPage, forKey: "twoPage"); if regions.count != regionCount { regions = [] } }
    }
    @Published var regions: [Region] {
        didSet { defaults.set(Region.string(from: regions), forKey: "regions") }
    }
    @Published var next: NextAction {
        didSet { defaults.set(next.storage, forKey: "next") }
    }
    @Published var timeout: Double {
        didSet { defaults.set(timeout, forKey: "timeout") }
    }
    @Published var start: Int
    @Published var overwrite = false

    @Published var mode: Mode {
        didSet {
            defaults.set(mode.rawValue, forKey: "mode")
            if mode != oldValue { lastImage = nil; lastFile = "" }
        }
    }
    @Published var quality: PDFQuality {
        didSet { defaults.set(quality.rawValue, forKey: "quality"); estimate() }
    }
    @Published var pdfSupport: Result<String, Error>?
    @Published var pdfInfo: PDFInfo?
    @Published var pdfError: String?
    @Published var bytesPerPage: Int?
    @Published var estimating = false
    @Published var pdfThumbnail: NSImage?
    @Published var showLog: Bool {
        didSet { defaults.set(showLog, forKey: "showLog") }
    }
    private var estimateToken = CancelToken()

    @Published var running = false
    @Published var savedThisRun = 0
    @Published var lastImage: NSImage?
    @Published var lastFile = ""
    @Published var log: [String] = []
    @Published var recording = false
    @Published var testing = false
    @Published var screenOK = false
    @Published var accessibilityOK = false

    private var session: CaptureSession?
    private var pdfSession: PDFExportSession?

    init() {
        let dir = defaults.string(forKey: "outDir").map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/PageCap")
        outDir = dir
        twoPage = defaults.object(forKey: "twoPage") as? Bool ?? true
        regions = Region.list(from: defaults.string(forKey: "regions") ?? "")
        next = NextAction(storage: defaults.string(forKey: "next") ?? "") ?? .default
        timeout = defaults.object(forKey: "timeout") as? Double ?? 6
        start = nextFreeIndex(in: dir)
        mode = Mode(rawValue: defaults.string(forKey: "mode") ?? "") ?? .macro
        quality = PDFQuality(rawValue: defaults.integer(forKey: "quality")) ?? .high
        showLog = defaults.bool(forKey: "showLog")
        refreshPermissions()
        checkPDFSupport()
    }

    var regionCount: Int { twoPage ? 2 : 1 }
    var regionsReady: Bool { regions.count == regionCount }
    var canStart: Bool { !running && screenOK && accessibilityOK }
    var pdfSupportOK: Bool { if case .success = pdfSupport { return true } else { return false } }
    var canConvert: Bool { !running && pdfSupportOK && pdfInfo != nil }

    func refreshPermissions() {
        screenOK = Permissions.screenRecording(prompt: false)
        accessibilityOK = Permissions.accessibility(prompt: false)
    }

    func requestPermissions() {
        if !screenOK { _ = Permissions.screenRecording(prompt: true) }
        if !accessibilityOK { _ = Permissions.accessibility(prompt: true) }
        refreshPermissions()
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = outDir
        panel.prompt = "선택"
        if panel.runModal() == .OK, let url = panel.url { outDir = url }
    }

    // MARK: 일반 PDF

    func checkPDFSupport() {
        pdfSupport = PDFExport.checkSupport()
    }

    func choosePDF() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.prompt = "선택"
        if let url = pdfInfo?.url { panel.directoryURL = url.deletingLastPathComponent() }
        if panel.runModal() == .OK, let url = panel.url { setPDF(url) }
    }

    func setPDF(_ url: URL) {
        pdfInfo = nil
        bytesPerPage = nil
        pdfThumbnail = nil
        lastImage = nil
        lastFile = ""
        do {
            pdfInfo = try PDFExport.info(url)
            pdfError = nil
            append("PDF: \(url.lastPathComponent) — \(pdfInfo!.pageCount)쪽")
            estimate()
            Task.detached(priority: .userInitiated) { [weak self] in
                let doc = try? PDFExport.open(url)
                let data = doc?.page(at: 0).flatMap { PDFExport.renderPNG($0, dpi: 96) }
                await self?.finishThumbnail(data, for: url)
            }
        } catch {
            pdfError = error.localizedDescription
            append("PDF 열기 실패: \(error.localizedDescription)")
        }
    }

    /// 선명도나 파일이 바뀔 때마다 실제 렌더링으로 한 쪽당 용량을 다시 추정 (이전 추정은 버림)
    private func estimate() {
        estimateToken.cancel()
        let token = CancelToken()
        estimateToken = token
        bytesPerPage = nil
        guard let url = pdfInfo?.url else { estimating = false; return }
        estimating = true
        let dpi = quality.dpi
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = try? PDFExport.estimateBytesPerPage(url, dpi: dpi, isCancelled: { token.isCancelled })
            await self?.finishEstimate(result, token: token)
        }
    }

    private func finishThumbnail(_ data: Data?, for url: URL) {
        guard pdfInfo?.url == url, let data else { return }
        pdfThumbnail = NSImage(data: data)
    }

    private func finishEstimate(_ bytes: Int?, token: CancelToken) {
        guard !token.isCancelled else { return }
        estimating = false
        bytesPerPage = bytes
    }

    func startConvert() {
        guard canConvert, let info = pdfInfo else { return }
        start = min(max(start, 1), 9999)
        var config = PDFExportConfig(file: info.url, outDir: outDir)
        config.dpi = quality.dpi
        config.start = start
        config.overwrite = overwrite

        running = true
        savedThisRun = 0
        append("변환 시작 — \(fileName(for: start))부터")
        pdfSession = PDFExportSession(config: config) { [weak self] event in
            self?.handle(event)
        }
        pdfSession?.start()
    }

    // MARK: 화면 캡처

    func selectRegions(thenStart: Bool = false) {
        RegionSelector.select(count: regionCount) { [weak self] picked in
            guard let self else { return }
            guard let picked else { return self.append("영역 선택을 취소했습니다") }
            self.regions = picked
            self.append("영역: " + picked.map(\.arg).joined(separator: "  /  "))
            if thenStart { self.beginCapture() }
        }
    }

    /// 프리셋 + (등록한 신호가 프리셋에 없으면) 그 신호
    var nextOptions: [NextAction] {
        NextAction.presets.contains(next) ? NextAction.presets : NextAction.presets + [next]
    }

    func recordPageTurn() {
        if recording {
            PageTurnRecorder.cancel()
            recording = false
            return
        }
        recording = true
        append("뷰어 창 위에서 평소 페이지를 넘길 때 누르는 버튼이나 키를 한 번 누르세요")
        PageTurnRecorder.record { [weak self] result in
            guard let self else { return }
            self.recording = false
            let seen = PageTurnRecorder.lastDescriptions
            if !seen.isEmpty { self.append("감지된 신호: " + seen.joined(separator: ", ")) }
            switch result {
            case .success(let action):
                self.next = action
                self.append("페이지 넘기기 등록: \(action.label) — 방금 넘어간 페이지는 다시 앞으로 돌려 두세요")
            case .failure(let error):
                self.append("등록 실패: \(error.localizedDescription)")
            }
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func testPageTurn() {
        refreshPermissions()
        guard canStart, regionsReady else { return }
        testing = true
        append("넘기기 테스트: \(next.label)")
        PageCapCore.testPageTurn(regions: regions, action: next) { [weak self] result in
            guard let self else { return }
            self.testing = false
            switch result {
            case .success(true):
                self.append("✓ 페이지가 넘어갔습니다 (한 장 넘어갔으니 필요하면 되돌려 두세요)")
            case .success(false):
                self.append("✗ 화면이 바뀌지 않았습니다. 다른 넘기기 방식을 고르거나 '직접 눌러서 등록'을 써 보세요")
            case .failure(let error):
                self.append("오류: \(error.localizedDescription)")
            }
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func startCapture() {
        refreshPermissions()
        guard canStart else { return }
        if regionsReady { beginCapture() } else { selectRegions(thenStart: true) }
    }

    private func beginCapture() {
        start = min(max(start, 1), 9999)
        var config = CaptureConfig(outDir: outDir, regions: regions)
        config.next = next
        config.start = start
        config.timeout = timeout
        config.overwrite = overwrite

        running = true
        savedThisRun = 0
        append("캡처 시작 — \(fileName(for: start))부터")
        session = CaptureSession(config: config) { [weak self] event in
            self?.handle(event)
        }
        session?.start()
    }

    private func handle(_ event: CaptureSession.Event) {
        switch event {
        case .status(let msg):
            append(msg)
        case .saved(let url):
            savedThisRun += 1
            lastFile = url.lastPathComponent
            lastImage = NSImage(contentsOf: url)
        case .finished(let saved, let reason):
            append("\(reason) — \(saved)장 저장")
            finish()
        case .failed(let msg):
            append("오류: \(msg)")
            finish()
        }
    }

    func stopCapture() {
        session?.cancel()
        pdfSession?.cancel()
    }

    private func finish() {
        running = false
        session = nil
        pdfSession = nil
        start = nextFreeIndex(in: outDir)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func append(_ line: String) {
        let time = Date().formatted(date: .omitted, time: .standard)
        log.append("[\(time)] \(line)")
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }
}

// MARK: - 화면
//
// ┌ 툴바: [화면 캡처 | PDF 변환] ─────────────────┐
// │ 설정 (입력 → 옵션 → 저장)  │ 미리보기 · 진행 · 실행 │
// ├ (로그, 접을 수 있음) ─────────────────────────┤
// └ 상태줄: 권한/PDFKit 상태 · 마지막 로그 · 로그 토글 ┘

struct ContentView: View {
    @StateObject private var model = CaptureModel()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                settings
                    .frame(minWidth: 430, maxWidth: .infinity)
                Divider()
                OutputPane(model: model)
                    .frame(width: 260)
            }
            if model.showLog {
                Divider()
                logView
            }
            Divider()
            statusBar
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("방식", selection: $model.mode) {
                    ForEach(Mode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
                .disabled(model.running)
                .help(model.mode.help)
            }
        }
    }

    private var settings: some View {
        Form {
            switch model.mode {
            case .macro: macroSections
            case .pdf: pdfSections
            }
            saveSection
        }
        .formStyle(.grouped)
        .disabled(model.running)
    }

    // MARK: 화면 캡처 (보안 PDF)

    @ViewBuilder private var macroSections: some View {
        // 권한은 빠졌을 때만 맨 위에 띄운다. 평소 상태는 아래 상태줄에 있다.
        if !model.screenOK || !model.accessibilityOK {
            Section {
                Label("캡처하려면 권한이 필요합니다", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.headline)
                if !model.screenOK { permissionRow("화면 기록", screenRecording: true) }
                if !model.accessibilityOK { permissionRow("손쉬운 사용 (페이지 넘기기)", screenRecording: false) }
                HStack {
                    Button("권한 요청") { model.requestPermissions() }
                    Button("다시 확인") { model.refreshPermissions() }
                }
            } footer: {
                Text("화면 기록 권한은 켠 뒤 앱을 다시 실행해야 적용됩니다.")
            }
        }

        Section("캡처 영역") {
            Picker("화면 보기", selection: $model.twoPage) {
                Text("두 쪽 (왼쪽·오른쪽 따로 저장)").tag(true)
                Text("한 쪽").tag(false)
            }
            LabeledContent("영역") {
                HStack(spacing: 8) {
                    Text(model.regionsReady
                         ? model.regions.map { "\($0.w)×\($0.h)" }.joined(separator: " · ")
                         : "지정 안 됨")
                        .monospacedDigit()
                        .foregroundStyle(model.regionsReady ? .primary : .secondary)
                        .help(model.regions.map(\.arg).joined(separator: "  /  "))
                    Button(model.regionsReady ? "다시 지정…" : "영역 지정…") { model.selectRegions() }
                }
            }
        }

        Section {
            Picker("방식", selection: $model.next) {
                ForEach(model.nextOptions) { Text($0.label).tag($0) }
            }
            HStack {
                Button(model.recording ? "누르기를 기다리는 중… (취소)" : "직접 눌러서 등록") {
                    model.recordPageTurn()
                }
                Button("넘기기 테스트") { model.testPageTurn() }
                    .disabled(!model.regionsReady || !model.canStart || model.testing || model.recording)
                if model.testing { ProgressView().controlSize(.small) }
            }
            // 쪽 번호로 이동하는 Acrobat 스크립트는 화면 변화로 끝을 판정하지 않는다
            if model.next != .acrobat {
                LabeledContent("마지막 쪽 판정") {
                    HStack {
                        Slider(value: $model.timeout, in: 2...20, step: 1).frame(width: 140)
                        Text("\(Int(model.timeout))초 무변화").monospacedDigit().frame(width: 72, alignment: .trailing)
                    }
                }
            }
        } header: {
            Text("페이지 넘기기")
        } footer: {
            Text(model.next == .acrobat
                 ? "현재 쪽부터 마지막 쪽까지 쪽 번호로 이동하며 찍고, 마지막 쪽에서 자동으로 멈춥니다."
                 : "넘긴 뒤 화면이 정해진 시간 동안 바뀌지 않으면 마지막 쪽으로 보고 멈춥니다. Acrobat 이면 'Acrobat 스크립트'가 가장 확실합니다.")
        }
    }

    private func permissionRow(_ title: String, screenRecording: Bool) -> some View {
        LabeledContent {
            Button("설정 열기") { Permissions.openSettings(screenRecording: screenRecording) }
        } label: {
            Label(title, systemImage: "xmark.circle.fill").foregroundStyle(.red)
        }
    }

    // MARK: 일반 PDF

    @ViewBuilder private var pdfSections: some View {
        if case .failure(let error)? = model.pdfSupport {
            Section {
                Label("PDF 변환을 쓸 수 없습니다", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.headline)
                LabeledContent(error.localizedDescription) {
                    Button("다시 확인") { model.checkPDFSupport() }
                }
            }
        }

        Section {
            PDFDropZone(model: model)
        } header: {
            Text("PDF 파일")
        } footer: {
            Text("암호가 걸렸거나 복사·추출이 제한된 PDF 는 변환하지 않습니다. 그런 문서는 '화면 캡처'를 쓰세요.")
        }

        Section {
            Picker("해상도", selection: $model.quality) {
                ForEach(PDFQuality.allCases) { Text($0.label).tag($0) }
            }
            LabeledContent("이미지 크기") {
                if let info = model.pdfInfo {
                    let px = info.pixelSize(dpi: model.quality.dpi)
                    Text("\(px.width) × \(px.height) px").monospacedDigit()
                } else {
                    Text("—")
                }
            }
            LabeledContent("한 쪽당 예상 용량") {
                if model.estimating {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("계산 중…")
                    }
                } else if let bytes = model.bytesPerPage {
                    Text("약 \(formatBytes(bytes))").monospacedDigit().foregroundStyle(.primary)
                } else {
                    Text("—")
                }
            }
            if let bytes = model.bytesPerPage, let info = model.pdfInfo, !model.estimating {
                LabeledContent("전체 \(info.pageCount)쪽") {
                    Text("약 \(formatBytes(bytes * info.pageCount))").monospacedDigit()
                }
            }
        } header: {
            Text("선명도")
        } footer: {
            Text("예상 용량은 앞·가운데·마지막 쪽을 실제로 렌더링한 평균입니다. 그림이 많은 쪽은 더 클 수 있습니다.")
        }
    }

    // MARK: 공통

    private var saveSection: some View {
        Section {
            LabeledContent("폴더") {
                HStack(spacing: 6) {
                    Text(model.outDir.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .lineLimit(1).truncationMode(.head)
                        .help(model.outDir.path)
                    Button("변경…") { model.chooseFolder() }
                    Button { NSWorkspace.shared.open(model.outDir) } label: {
                        Image(systemName: "folder")
                    }
                    .help("Finder 에서 열기")
                }
            }
            LabeledContent("시작 번호") {
                HStack(spacing: 6) {
                    TextField("", value: $model.start, format: .number.grouping(.never))
                        .multilineTextAlignment(.trailing)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 56)
                        .onSubmit { model.start = min(max(model.start, 1), 9999) }
                    Stepper("", value: $model.start, in: 1...9999).labelsHidden()
                    Button("1부터") { model.start = 1 }
                    Button("이어서") { model.start = nextFreeIndex(in: model.outDir) }
                        .help("폴더의 마지막 번호 다음부터")
                }
            }
            Toggle("같은 이름의 파일 덮어쓰기", isOn: $model.overwrite)
        } header: {
            Text("저장")
        } footer: {
            Text("\(fileName(for: max(model.start, 1))) 부터 저장합니다.")
        }
    }

    // MARK: 하단

    private var statusBar: some View {
        HStack(spacing: 14) {
            switch model.mode {
            case .macro:
                StatusDot(ok: model.screenOK, title: "화면 기록")
                StatusDot(ok: model.accessibilityOK, title: "손쉬운 사용")
            case .pdf:
                Button { model.checkPDFSupport() } label: {
                    StatusDot(ok: model.pdfSupportOK, title: model.pdfSupportOK ? "PDFKit 사용 가능" : "PDFKit 사용 불가")
                }
                .buttonStyle(.plain)
                .help({ if case .success(let d)? = model.pdfSupport { return d + " — 눌러서 다시 확인" }; return "눌러서 다시 확인" }())
            }
            Divider().frame(height: 14)
            Text(model.log.last ?? "")
                .lineLimit(1).truncationMode(.tail)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button { model.showLog.toggle() } label: {
                Label("로그", systemImage: model.showLog ? "chevron.down" : "chevron.up")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("l", modifiers: [.command, .shift])
            .help("로그 보기/숨기기 (⇧⌘L)")
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .frame(height: 30)
        .background(.bar)
    }

    private var logView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(model.log.enumerated()), id: \.offset) { i, line in
                        Text(line).font(.system(.caption, design: .monospaced)).textSelection(.enabled).id(i)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            }
            .frame(height: 140)
            .background(Color(nsColor: .textBackgroundColor))
            .onAppear { proxy.scrollTo(model.log.count - 1, anchor: .bottom) }
            .onChange(of: model.log.count) { count in
                proxy.scrollTo(count - 1, anchor: .bottom)
            }
        }
    }
}

struct StatusDot: View {
    let ok: Bool
    let title: String

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(ok ? Color.green : Color.red).frame(width: 7, height: 7)
            Text(title).foregroundStyle(ok ? .secondary : .primary)
        }
    }
}

// MARK: - 오른쪽: 미리보기 · 진행 · 실행

struct OutputPane: View {
    @ObservedObject var model: CaptureModel

    private var image: NSImage? {
        model.lastImage ?? (model.mode == .pdf ? model.pdfThumbnail : nil)
    }

    private var caption: String {
        if model.lastImage != nil { return model.lastFile }
        if model.mode == .pdf, model.pdfThumbnail != nil { return "1쪽 미리보기" }
        return " "
    }

    var body: some View {
        VStack(spacing: 14) {
            preview
            Text(caption)
                .font(.callout).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            progress
            action
        }
        .padding(20)
        .background(Color(nsColor: .stageBackground))
    }

    private var preview: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .background(.white)
                    .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: model.mode == .pdf ? "doc.richtext" : "camera.viewfinder")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text(model.mode == .pdf ? "PDF 를 고르면 1쪽이 여기에 표시됩니다" : "캡처한 쪽이 여기에 표시됩니다")
                        .font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 220, maxHeight: .infinity)
    }

    @ViewBuilder private var progress: some View {
        if model.running {
            VStack(alignment: .leading, spacing: 6) {
                if model.mode == .pdf, let total = model.pdfInfo?.pageCount {
                    ProgressView(value: Double(model.savedThisRun), total: Double(total))
                    Text("\(model.savedThisRun) / \(total)쪽").monospacedDigit()
                } else {
                    ProgressView().progressViewStyle(.linear)
                    Text("\(model.savedThisRun)장 저장 · 다른 앱을 클릭하면 멈춥니다").monospacedDigit()
                }
            }
            .font(.callout).foregroundStyle(.secondary)
        } else if let hint {
            Text(hint)
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
    }

    /// 실행 전 한 줄 요약, 또는 왜 시작할 수 없는지
    private var hint: String? {
        switch model.mode {
        case .pdf:
            guard model.pdfSupportOK else { return "PDFKit 을 쓸 수 없습니다" }
            guard let info = model.pdfInfo else { return "PDF 를 먼저 고르세요" }
            let first = max(model.start, 1)
            let size = model.bytesPerPage.map { " · 약 \(formatBytes($0 * info.pageCount))" } ?? ""
            return "\(info.pageCount)쪽\(size)\n\(String(format: "%03d", first)) ~ \(fileName(for: first + info.pageCount - 1))"
        case .macro:
            guard model.screenOK, model.accessibilityOK else { return "권한을 먼저 켜세요" }
            if model.savedThisRun > 0 { return "이번 실행: \(model.savedThisRun)장 저장" }
            return model.regionsReady ? nil : "시작하면 먼저 캡처 영역을 드래그로 지정합니다"
        }
    }

    @ViewBuilder private var action: some View {
        if model.running {
            Button(role: .destructive) { model.stopCapture() } label: {
                Label("중지", systemImage: "stop.fill").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .keyboardShortcut(".", modifiers: .command)
        } else if model.mode == .pdf {
            Button { model.startConvert() } label: {
                Label("PNG 로 변환", systemImage: "photo.on.rectangle.angled").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!model.canConvert)
        } else {
            Button { model.startCapture() } label: {
                Label("캡처 시작", systemImage: "camera.fill").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!model.canStart)
        }
    }
}

extension NSColor {
    /// 오른쪽 미리보기 바탕: 흰 쪽이 도드라지도록 설정 칸보다 살짝 어둡게
    static let stageBackground = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.13, alpha: 1)
            : NSColor(white: 0.90, alpha: 1)
    }
}

func formatBytes(_ bytes: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
}

/// PDF 를 끌어다 놓거나 버튼으로 고르는 영역
struct PDFDropZone: View {
    @ObservedObject var model: CaptureModel
    @State private var targeted = false

    var body: some View {
        Group {
            if let info = model.pdfInfo {
                HStack(spacing: 12) {
                    Image(systemName: "doc.richtext.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(info.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        Text("\(info.pageCount)쪽 · \(info.url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))")
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.head)
                    }
                    Spacer()
                    Button("변경…") { model.choosePDF() }
                }
                .padding(12)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(targeted ? Color.accentColor : Color.secondary)
                    Text("PDF 파일을 여기로 끌어다 놓으세요")
                    Button("파일 선택…") { model.choosePDF() }
                    if let error = model.pdfError {
                        Text(error).font(.caption).foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 12)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(targeted ? Color.accentColor.opacity(0.08) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(targeted ? Color.accentColor : Color.secondary.opacity(0.35),
                              style: StrokeStyle(lineWidth: targeted ? 2 : 1, dash: [6, 4]))
        )
        .contentShape(Rectangle())
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, !model.running else { return false }
            model.setPDF(url)
            return true
        } isTargeted: { targeted = $0 }
    }
}
