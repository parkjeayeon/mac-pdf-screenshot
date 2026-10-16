// PageCap GUI — PageCapCore 를 창에서 설정·실행한다.

import AppKit
import PageCapCore
import SwiftUI

@main
struct PageCapApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        WindowGroup("PageCap") {
            ContentView()
                .frame(minWidth: 560, minHeight: 640)
        }
        .windowResizability(.contentSize)
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

    init() {
        let dir = defaults.string(forKey: "outDir").map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/PageCap")
        outDir = dir
        twoPage = defaults.object(forKey: "twoPage") as? Bool ?? true
        regions = Region.list(from: defaults.string(forKey: "regions") ?? "")
        next = NextAction(storage: defaults.string(forKey: "next") ?? "") ?? .default
        timeout = defaults.object(forKey: "timeout") as? Double ?? 6
        start = nextFreeIndex(in: dir)
        refreshPermissions()
    }

    var regionCount: Int { twoPage ? 2 : 1 }
    var regionsReady: Bool { regions.count == regionCount }
    var canStart: Bool { !running && screenOK && accessibilityOK }

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
            guard let self else { return }
            switch event {
            case .status(let msg):
                self.append(msg)
            case .saved(let url):
                self.savedThisRun += 1
                self.lastFile = url.lastPathComponent
                self.lastImage = NSImage(contentsOf: url)
            case .finished(let saved, let reason):
                self.append("\(reason) — \(saved)장 저장")
                self.finish()
            case .failed(let msg):
                self.append("오류: \(msg)")
                self.finish()
            }
        }
        session?.start()
    }

    func stopCapture() {
        session?.cancel()
    }

    private func finish() {
        running = false
        session = nil
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

struct ContentView: View {
    @StateObject private var model = CaptureModel()

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("권한") {
                    permissionRow("화면 기록", ok: model.screenOK, screenRecording: true)
                    permissionRow("손쉬운 사용 (페이지 넘기기)", ok: model.accessibilityOK, screenRecording: false)
                    if !model.screenOK || !model.accessibilityOK {
                        HStack {
                            Button("권한 요청") { model.requestPermissions() }
                            Button("다시 확인") { model.refreshPermissions() }
                            Spacer()
                        }
                        Text("화면 기록 권한은 켠 뒤 앱을 다시 실행해야 적용됩니다.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section("저장") {
                    HStack {
                        Text(model.outDir.path)
                            .lineLimit(1).truncationMode(.head)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("변경…") { model.chooseFolder() }
                        Button("열기") { NSWorkspace.shared.open(model.outDir) }
                    }
                    HStack {
                        Text("시작 번호")
                        Spacer()
                        TextField("", value: $model.start, format: .number.grouping(.never))
                            .multilineTextAlignment(.trailing)
                            .frame(width: 70)
                            .onSubmit { model.start = min(max(model.start, 1), 9999) }
                        Stepper("", value: $model.start, in: 1...9999).labelsHidden()
                        Text(fileName(for: max(model.start, 1)))
                            .foregroundStyle(.secondary)
                            .font(.system(.body, design: .monospaced))
                        Button("1부터") { model.start = 1 }
                        Button("이어서") { model.start = nextFreeIndex(in: model.outDir) }
                            .help("폴더의 마지막 번호 다음부터")
                    }
                    Toggle("같은 이름의 파일 덮어쓰기", isOn: $model.overwrite)
                }

                Section("캡처 방식") {
                    Picker("화면 보기", selection: $model.twoPage) {
                        Text("두 쪽 보기 (왼쪽·오른쪽 따로 저장)").tag(true)
                        Text("한 쪽 보기").tag(false)
                    }
                    HStack {
                        Text("영역")
                        Spacer()
                        Text(model.regionsReady
                             ? model.regions.map(\.arg).joined(separator: "  /  ")
                             : "지정 안 됨")
                            .foregroundStyle(model.regionsReady ? .primary : .secondary)
                            .font(.system(.body, design: .monospaced))
                        Button("영역 지정…") { model.selectRegions() }
                            .disabled(model.running)
                    }
                    Picker("페이지 넘기기", selection: $model.next) {
                        ForEach(model.nextOptions) { Text($0.label).tag($0) }
                    }
                    HStack {
                        Button(model.recording ? "누르기를 기다리는 중… (취소)" : "직접 눌러서 등록") {
                            model.recordPageTurn()
                        }
                        Button("넘기기 테스트") { model.testPageTurn() }
                            .disabled(!model.regionsReady || !model.canStart || model.testing || model.recording)
                        if model.testing { ProgressView().controlSize(.small) }
                        Spacer()
                    }
                    Text("Acrobat 이면 'Acrobat 스크립트'가 가장 확실합니다. 현재 쪽부터 마지막 쪽까지 쪽 번호로 이동하며 찍고, 마지막 쪽에서 자동으로 멈춥니다. 다른 뷰어면 → 키 등을 고르거나 '직접 눌러서 등록'을 쓰세요.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Text("마지막 페이지 판정")
                        Slider(value: $model.timeout, in: 2...20, step: 1)
                        Text("\(Int(model.timeout))초 무변화").monospacedDigit().frame(width: 80, alignment: .trailing)
                    }
                }
                .disabled(model.running)
            }
            .formStyle(.grouped)

            Divider()

            HStack(alignment: .top, spacing: 12) {
                preview
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        if model.running {
                            Button(role: .destructive) { model.stopCapture() } label: {
                                Label("중지", systemImage: "stop.fill")
                            }
                            .keyboardShortcut(".", modifiers: .command)
                            ProgressView().controlSize(.small)
                        } else {
                            Button { model.startCapture() } label: {
                                Label("캡처 시작", systemImage: "camera.fill")
                            }
                            .keyboardShortcut(.return, modifiers: .command)
                            .buttonStyle(.borderedProminent)
                            .disabled(!model.canStart)
                        }
                        Spacer()
                        Text("이번 실행: \(model.savedThisRun)장").monospacedDigit()
                    }
                    logView
                }
            }
            .padding(12)
        }
    }

    private func permissionRow(_ title: String, ok: Bool, screenRecording: Bool) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? .green : .red)
            Text(title)
            Spacer()
            if !ok {
                Button("설정 열기") { Permissions.openSettings(screenRecording: screenRecording) }
            }
        }
    }

    private var preview: some View {
        VStack(spacing: 4) {
            Group {
                if let image = model.lastImage {
                    Image(nsImage: image).resizable().scaledToFit()
                } else {
                    Image(systemName: "doc.richtext").font(.largeTitle).foregroundStyle(.tertiary)
                }
            }
            .frame(width: 110, height: 140)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            Text(model.lastFile.isEmpty ? "미리보기" : model.lastFile)
                .font(.caption).foregroundStyle(.secondary)
        }
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
            }
            .frame(height: 120)
            .padding(6)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .onChange(of: model.log.count) { count in
                proxy.scrollTo(count - 1, anchor: .bottom)
            }
        }
    }
}
