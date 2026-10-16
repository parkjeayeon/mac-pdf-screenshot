// PageCapCore — 뷰어 화면을 "다음 페이지 → 영역 캡처 → 저장" 반복으로 자동 캡처하는 공용 로직.
// 화면에 보이는 그대로를 찍을 뿐, 뷰어나 문서 보호 기능에는 관여하지 않는다.

import AppKit
import ApplicationServices
import Foundation

// MARK: - 설정 값

public struct Region: Equatable, Hashable {
    // 전역 좌표(포인트), 주 모니터 좌상단 원점 — screencapture -R / CGEvent 와 같은 좌표계
    public var x: Int, y: Int, w: Int, h: Int

    public var arg: String { "\(x),\(y),\(w),\(h)" }
    public var center: CGPoint { CGPoint(x: Double(x) + Double(w) / 2, y: Double(y) + Double(h) / 2) }

    public init(x: Int, y: Int, w: Int, h: Int) { (self.x, self.y, self.w, self.h) = (x, y, w, h) }

    public init?(_ s: String) {
        let p = s.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard p.count == 4, p[2] > 0, p[3] > 0 else { return nil }
        self.init(x: p[0], y: p[1], w: p[2], h: p[3])
    }

    /// "x,y,w,h;x,y,w,h" 형식 (설정 저장용)
    public static func list(from s: String) -> [Region] {
        s.split(separator: ";").compactMap { Region(String($0)) }
    }

    public static func string(from regions: [Region]) -> String {
        regions.map(\.arg).joined(separator: ";")
    }
}

/// 페이지 넘기기 신호. 프리셋 또는 사용자가 직접 눌러 등록한 신호(PageTurnRecorder)
public enum NextAction: Hashable, Identifiable {
    case mouse(button: Int64)                 // 3 = 뒤로, 4 = 앞으로 (마우스 사이드 버튼)
    case key(code: UInt16, modifiers: UInt64) // modifiers = CGEventFlags rawValue (⌘⌥⌃⇧ 만)
    case recorded(events: [Data], label: String) // 직접 눌러 등록한 원본 이벤트(CGEvent 직렬화)를 그대로 재생
    case acrobat                              // Adobe Acrobat AppleScript 로 페이지 이동 (가장 확실)

    public static let forward = NextAction.mouse(button: 4)
    public static let `default` = NextAction.acrobat

    public static let presets: [NextAction] = [
        .acrobat,
        .mouse(button: 4), .mouse(button: 3),
        .key(code: 124, modifiers: 0), .key(code: 123, modifiers: 0), .key(code: 125, modifiers: 0),
        .key(code: 121, modifiers: 0), .key(code: 49, modifiers: 0),
    ]

    /// CLI 이름: forward, back, right, left, down, pagedown, space
    public static let cliNames: [String: NextAction] = [
        "acrobat": .acrobat, "forward": .mouse(button: 4), "back": .mouse(button: 3),
        "right": .key(code: 124, modifiers: 0), "left": .key(code: 123, modifiers: 0),
        "down": .key(code: 125, modifiers: 0), "pagedown": .key(code: 121, modifiers: 0),
        "space": .key(code: 49, modifiers: 0),
    ]

    public var id: String { storage }

    /// 설정 저장용 문자열: "mouse:4", "key:124:0"
    public var storage: String {
        switch self {
        case .acrobat: return "acrobat"
        case .mouse(let b): return "mouse:\(b)"
        case .key(let c, let m): return "key:\(c):\(m)"
        case .recorded(let events, let label):
            return "rec:" + Data(label.utf8).base64EncodedString() + ":"
                + events.map { $0.base64EncodedString() }.joined(separator: ",")
        }
    }

    public init?(storage: String) {
        let p = storage.split(separator: ":").map(String.init)
        if storage == "acrobat" { self = .acrobat; return }
        if p.count == 2, p[0] == "mouse", let b = Int64(p[1]) { self = .mouse(button: b); return }
        if p.count == 3, p[0] == "key", let c = UInt16(p[1]), let m = UInt64(p[2]) {
            self = .key(code: c, modifiers: m); return
        }
        if p.count == 3, p[0] == "rec", let l = Data(base64Encoded: p[1]), let label = String(data: l, encoding: .utf8) {
            let events = p[2].split(separator: ",").compactMap { Data(base64Encoded: String($0)) }
            if !events.isEmpty { self = .recorded(events: events, label: label); return }
        }
        return nil
    }

    public var label: String {
        switch self {
        case .acrobat: return "Acrobat 스크립트 (권장)"
        case .mouse(4): return "마우스 앞으로 버튼"
        case .mouse(3): return "마우스 뒤로 버튼"
        case .mouse(let b): return "마우스 \(b + 1)번 버튼"
        case .key(let code, let mods):
            let f = CGEventFlags(rawValue: mods)
            var s = ""
            if f.contains(.maskControl) { s += "⌃" }
            if f.contains(.maskAlternate) { s += "⌥" }
            if f.contains(.maskShift) { s += "⇧" }
            if f.contains(.maskCommand) { s += "⌘" }
            let names: [UInt16: String] = [124: "→ 키", 123: "← 키", 125: "↓ 키", 126: "↑ 키",
                                           121: "Page Down 키", 116: "Page Up 키", 49: "스페이스바",
                                           36: "Return 키", 48: "Tab 키", 119: "End 키", 115: "Home 키"]
            return s + (names[code] ?? "키코드 \(code)")
        case .recorded(_, let label):
            return "등록: \(label)"
        }
    }
}

/// 사용자가 다음 페이지로 넘길 때 실제로 누르는 신호를 이벤트 탭으로 한 번 기록한다.
/// 마우스 버튼·키·시스템 이벤트 등 종류와 상관없이 원본을 저장해 그대로 재생한다.
public final class PageTurnRecorder {
    private static var tap: CFMachPort?
    private static var source: CFRunLoopSource?
    private static var captured: [Data] = []
    private static var descriptions: [String] = []
    private static var completion: ((Result<NextAction, Error>) -> Void)?
    private static var timeoutWork: DispatchWorkItem?

    // 기록 대상: 마우스(왼쪽 제외) 버튼, 키, 시스템 정의 이벤트(미디어/특수 버튼), 제스처
    private static let systemDefined: UInt32 = 14
    private static let gestureTypes: Set<UInt32> = [29, 30, 31]
    private static let startTypes: Set<UInt32> = [CGEventType.otherMouseDown.rawValue, CGEventType.keyDown.rawValue, systemDefined]
    private static let followTypes: Set<UInt32> = [CGEventType.otherMouseUp.rawValue, CGEventType.keyUp.rawValue, systemDefined]

    static func describe(_ type: UInt32, _ e: CGEvent) -> String {
        switch type {
        case CGEventType.otherMouseDown.rawValue, CGEventType.otherMouseUp.rawValue:
            let b = e.getIntegerValueField(.mouseEventButtonNumber)
            return (b == 4 ? "마우스 앞으로 버튼" : b == 3 ? "마우스 뒤로 버튼" : "마우스 \(b + 1)번 버튼")
                + (type == CGEventType.otherMouseDown.rawValue ? " 누름" : " 뗌")
        case CGEventType.keyDown.rawValue, CGEventType.keyUp.rawValue:
            let code = UInt16(e.getIntegerValueField(.keyboardEventKeycode))
            let relevant: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
            return NextAction.key(code: code, modifiers: e.flags.intersection(relevant).rawValue).label
                + (type == CGEventType.keyDown.rawValue ? " 누름" : " 뗌")
        case systemDefined:
            let ns = NSEvent(cgEvent: e)
            return "시스템 이벤트(subtype \(ns?.subtype.rawValue ?? -1), data1 \(ns?.data1 ?? 0))"
        default:
            return "이벤트 타입 \(type)"
        }
    }

    /// 메인 스레드에서 호출. 처음 감지된 신호와 0.4초 안의 짝(뗌) 이벤트를 묶어 completion 으로 넘긴다.
    public static func record(timeout: TimeInterval = 15, completion: @escaping (Result<NextAction, Error>) -> Void) {
        cancel()
        self.completion = completion
        captured = []
        descriptions = []

        var mask: CGEventMask = 0
        for t in startTypes.union(followTypes).union(gestureTypes) { mask |= CGEventMask(1) << CGEventMask(t) }
        let callback: CGEventTapCallBack = { _, type, event, _ in
            PageTurnRecorder.handle(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                          eventsOfInterest: mask, callback: callback, userInfo: nil) else {
            CGRequestListenEventAccess()
            return finish(.failure(PageCapError("입력 감시를 시작하지 못했습니다. 시스템 설정 → 개인정보 보호 및 보안 → 입력 모니터링에서 PageCap 을 켠 뒤 다시 시도하세요")))
        }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        let work = DispatchWorkItem {
            finish(.failure(PageCapError("\(Int(timeout))초 동안 아무 신호도 감지되지 않았습니다")))
        }
        timeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)
    }

    private static func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        let t = type.rawValue
        if captured.isEmpty {
            if gestureTypes.contains(t) {
                descriptions.append("제스처 이벤트(타입 \(t))")
                return
            }
            guard startTypes.contains(t) else { return }
            if t == CGEventType.otherMouseDown.rawValue && event.getIntegerValueField(.mouseEventButtonNumber) < 2 { return }
            guard let data = event.data as Data? else { return }
            captured.append(data)
            descriptions.append(describe(t, event))
            timeoutWork?.cancel()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                let label = descriptions.first?.replacingOccurrences(of: " 누름", with: "") ?? "신호"
                finish(.success(.recorded(events: captured, label: label)))
            }
        } else if followTypes.contains(t) || startTypes.contains(t), let data = event.data as Data? {
            captured.append(data)
            descriptions.append(describe(t, event))
        }
    }

    /// 마지막 기록에서 감지된 이벤트 설명 (진단용)
    public static var lastDescriptions: [String] { descriptions }

    private static func finish(_ result: Result<NextAction, Error>) {
        let done = completion
        cancel()
        done?(result)
    }

    public static func cancel() {
        timeoutWork?.cancel()
        timeoutWork = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        completion = nil
    }
}

public struct CaptureConfig {
    public var outDir: URL
    public var regions: [Region]
    public var next: NextAction = .forward
    public var start = 1
    public var max = 2000
    public var timeout = 6.0
    public var poll = 0.4
    public var overwrite = false

    public init(outDir: URL, regions: [Region]) {
        self.outDir = outDir
        self.regions = regions
    }
}

public struct PageCapError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public func fileName(for index: Int) -> String {
    String(format: "%03d_capture.png", index)
}

/// 폴더에 있는 NNN_capture.png 중 가장 큰 번호 + 1
public func nextFreeIndex(in dir: URL) -> Int {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    let numbers = names.compactMap { name -> Int? in
        guard name.hasSuffix("_capture.png") else { return nil }
        return Int(name.prefix { $0.isNumber })
    }
    return (numbers.max() ?? 0) + 1
}

// MARK: - 권한

public enum Permissions {
    public static func screenRecording(prompt: Bool) -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        if prompt { CGRequestScreenCaptureAccess() }
        return false
    }

    public static func accessibility(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    public static func openSettings(screenRecording: Bool) {
        let pane = screenRecording ? "Privacy_ScreenCapture" : "Privacy_Accessibility"
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }
}

// MARK: - 영역 선택 오버레이

final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

final class SelectView: NSView {
    let prompt: String
    let onDone: (NSRect?) -> Void
    private var start: NSPoint?
    private var current: NSPoint?

    init(frame: NSRect, prompt: String, onDone: @escaping (NSRect?) -> Void) {
        self.prompt = prompt
        self.onDone = onDone
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var selection: NSRect? {
        guard let s = start, let c = current else { return nil }
        return NSRect(x: min(s.x, c.x), y: min(s.y, c.y), width: abs(s.x - c.x), height: abs(s.y - c.y))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.3).setFill()
        bounds.fill()
        if let r = selection {
            NSColor.clear.setFill()
            r.fill(using: .copy)
            NSColor.systemRed.setStroke()
            let path = NSBezierPath(rect: r)
            path.lineWidth = 2
            path.stroke()
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 22),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black.withAlphaComponent(0.7),
        ]
        let text = NSAttributedString(string: "  \(prompt)  (ESC 취소)  ", attributes: attrs)
        let size = text.size()
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: bounds.height - size.height - 80))
    }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        current = start
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        guard let r = selection, r.width >= 20, r.height >= 20 else {
            start = nil; current = nil; needsDisplay = true
            return
        }
        onDone(window!.convertToScreen(r))
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onDone(nil) }
    }
}

/// 화면 전체에 반투명 오버레이를 띄워 영역을 count 개 드래그로 받는다. 메인 스레드에서 호출.
public final class RegionSelector {
    private static var active: RegionSelector?

    private let count: Int
    private let completion: ([Region]?) -> Void
    private var results: [Region] = []
    private var overlays: [NSWindow] = []
    private var hiddenWindows: [NSWindow] = []

    public static func select(count: Int, completion: @escaping ([Region]?) -> Void) {
        let s = RegionSelector(count: count, completion: completion)
        active = s
        // 자기 앱 창이 페이지를 가리지 않도록 선택하는 동안 숨긴다
        s.hiddenWindows = NSApp.windows.filter { $0.isVisible && !($0 is OverlayWindow) }
        s.hiddenWindows.forEach { $0.orderOut(nil) }
        s.show()
    }

    private init(count: Int, completion: @escaping ([Region]?) -> Void) {
        self.count = count
        self.completion = completion
    }

    private var prompt: String {
        let n = results.count
        if count == 1 { return "캡처할 페이지 영역을 드래그하세요" }
        if count == 2 { return n == 0 ? "왼쪽 페이지 영역을 드래그하세요" : "오른쪽 페이지 영역을 드래그하세요" }
        return "\(n + 1)/\(count)번째 영역을 드래그하세요"
    }

    private func show() {
        let mainHeight = NSScreen.screens[0].frame.height
        for screen in NSScreen.screens {
            let w = OverlayWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.level = .screenSaver
            w.isOpaque = false
            w.backgroundColor = .clear
            w.isReleasedWhenClosed = false
            w.contentView = SelectView(frame: NSRect(origin: .zero, size: screen.frame.size), prompt: prompt) { [weak self] r in
                guard let self else { return }
                guard let r else { return self.finish(nil) }
                // AppKit 좌하단 원점 → 주 모니터 좌상단 원점
                self.results.append(Region(x: Int(r.minX.rounded()), y: Int((mainHeight - r.maxY).rounded()),
                                           w: Int(r.width.rounded()), h: Int(r.height.rounded())))
                self.closeOverlays()
                if self.results.count < self.count { self.show() } else { self.finish(self.results) }
            }
            w.makeKeyAndOrderFront(nil)
            overlays.append(w)
        }
        NSCursor.crosshair.set()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func closeOverlays() {
        overlays.forEach { $0.orderOut(nil) }
        overlays.removeAll()
    }

    private func finish(_ regions: [Region]?) {
        closeOverlays()
        NSCursor.arrow.set()
        hiddenWindows.forEach { $0.orderFront(nil) }
        RegionSelector.active = nil
        completion(regions)
    }
}

// MARK: - 캡처 / 페이지 넘기기

/// 저장용 PNG 와 비교용 픽셀 데이터 (PNG 메타데이터 차이에 흔들리지 않도록 픽셀로 비교)
struct Shot: Equatable {
    let png: Data
    let pixels: Data
    static func == (a: Shot, b: Shot) -> Bool { a.pixels == b.pixels }
}

func capture(_ regions: [Region], tmpDir: URL) throws -> [Shot] {
    try regions.enumerated().map { i, r in
        let url = tmpDir.appendingPathComponent("r\(i).png")
        try? FileManager.default.removeItem(at: url)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-t", "png", "-R", r.arg, url.path]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0, let data = try? Data(contentsOf: url),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let pixels = image.dataProvider?.data as Data? else {
            throw PageCapError("화면 캡처 실패 (영역 \(r.arg)). '화면 기록' 권한을 확인하세요")
        }
        return Shot(png: data, pixels: pixels)
    }
}

/// Adobe Acrobat 을 AppleScript 로 조작한다 (자동화 권한 필요)
enum Acrobat {
    static let bundleID = "com.adobe.Acrobat.Pro"

    static func run(_ body: String) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "tell application id \"\(bundleID)\" to \(body)"]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard p.terminationStatus == 0 else {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw PageCapError("Acrobat 스크립트 실패: \(msg.trimmingCharacters(in: .whitespacesAndNewlines)). "
                + "Acrobat 에 문서가 열려 있는지, 시스템 설정 → 개인정보 보호 및 보안 → 자동화에서 PageCap 의 Adobe Acrobat 항목이 켜져 있는지 확인하세요")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 앞쪽 문서 창의 현재 쪽과 전체 쪽수
    static func pageInfo() throws -> (current: Int, count: Int) {
        let r = try run("return ((page number of PDF Window 1) as text) & \",\" & ((count of pages of active doc) as text)")
        let p = r.split(separator: ",").compactMap { Int($0) }
        guard p.count == 2 else { throw PageCapError("Acrobat 쪽 정보를 읽지 못했습니다: \(r)") }
        return (p[0], p[1])
    }

    static func goto(page: Int) throws {
        _ = try run("goto PDF Window 1 page \(page)")
    }

    static func gotoNext() throws {
        _ = try run("goto next PDF Window 1")
    }
}

func turnPage(_ action: NextAction, at point: CGPoint) throws {
    let src = CGEventSource(stateID: .hidSystemState)
    switch action {
    case .acrobat:
        try Acrobat.gotoNext()
    case .mouse(let n):
        CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        usleep(50_000)
        for type in [CGEventType.otherMouseDown, .otherMouseUp] {
            guard let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: point,
                                  mouseButton: CGMouseButton(rawValue: UInt32(n)) ?? .center) else { continue }
            e.setIntegerValueField(.mouseEventButtonNumber, value: n)
            e.setIntegerValueField(.mouseEventClickState, value: 1)
            e.post(tap: .cghidEventTap)
            usleep(50_000)
        }
    case .key(let code, let mods):
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)
            e?.flags = CGEventFlags(rawValue: mods)
            e?.post(tap: .cghidEventTap)
            usleep(50_000)
        }
    case .recorded(let events, _):
        CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        usleep(50_000)
        for data in events {
            guard let e = CGEvent(withDataAllocator: nil, data: data as CFData) else { continue }
            if e.type == .otherMouseDown || e.type == .otherMouseUp { e.location = point }
            e.timestamp = CGEventTimestamp(clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
            e.post(tap: .cghidEventTap)
            usleep(50_000)
        }
    }
}

/// 뷰어를 맨 앞으로 가져오고 실제로 맨 앞이 될 때까지 기다린 뒤, 페이지를 한 번 클릭해 문서 영역에 포커스를 준다.
/// 백그라운드 스레드에서 호출.
func focusViewer(_ viewer: NSRunningApplication, clickAt point: CGPoint) throws {
    DispatchQueue.main.sync {
        if #available(macOS 14.0, *) {
            NSApp.yieldActivation(to: viewer)
            viewer.activate()
        } else {
            viewer.activate(options: [.activateIgnoringOtherApps])
        }
    }
    let deadline = Date().addingTimeInterval(3)
    while DispatchQueue.main.sync(execute: { NSWorkspace.shared.frontmostApplication?.processIdentifier }) != viewer.processIdentifier {
        guard Date() < deadline else {
            throw PageCapError("\(viewer.localizedName ?? "뷰어") 을(를) 맨 앞으로 가져오지 못했습니다. 뷰어 창을 한 번 클릭한 뒤 다시 시도하세요")
        }
        Thread.sleep(forTimeInterval: 0.1)
    }
    Thread.sleep(forTimeInterval: 0.4)
    let src = CGEventSource(stateID: .hidSystemState)
    for type in [CGEventType.leftMouseDown, .leftMouseUp] {
        let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
        e?.setIntegerValueField(.mouseEventClickState, value: 1)
        e?.post(tap: .cghidEventTap)
        usleep(50_000)
    }
    Thread.sleep(forTimeInterval: 0.6)
}

/// 영역 아래 뷰어를 앞으로 가져와 한 번 넘겨 보고, 화면이 바뀌었는지 알려준다. 메인 스레드에서 호출.
public func testPageTurn(regions: [Region], action: NextAction, completion: @escaping (Result<Bool, Error>) -> Void) {
    guard let first = regions.first else { return completion(.failure(PageCapError("캡처 영역이 없습니다"))) }
    guard let viewer = appOwningWindow(at: first.center) else {
        return completion(.failure(PageCapError("선택한 영역 아래에서 뷰어 창을 찾지 못했습니다")))
    }
    Thread.detachNewThread {
        let result = Result<Bool, Error> {
            try focusViewer(viewer, clickAt: first.center)
            let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("pagecap-test-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmpDir) }
            let before = try capture(regions, tmpDir: tmpDir)
            try turnPage(action, at: first.center)
            Thread.sleep(forTimeInterval: 1.5)
            return try capture(regions, tmpDir: tmpDir) != before
        }
        DispatchQueue.main.async { completion(result) }
    }
}

/// 영역 중심 아래에 있는 일반 창의 소유 앱 (자기 자신 제외)
func appOwningWindow(at point: CGPoint) -> NSRunningApplication? {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return nil }
    for w in list {
        guard (w[kCGWindowLayer as String] as? Int) == 0,
              let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != getpid(),
              let dict = w[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: dict),
              bounds.contains(point) else { continue }
        return NSRunningApplication(processIdentifier: pid)
    }
    return nil
}

// MARK: - 캡처 세션

public final class CaptureSession {
    public enum Event {
        case status(String)
        case saved(URL)
        case finished(saved: Int, reason: String)
        case failed(String)
    }

    private let config: CaptureConfig
    private let onEvent: (Event) -> Void
    private let lock = NSLock()
    private var cancelled = false

    /// onEvent 는 항상 메인 스레드에서 호출된다
    public init(config: CaptureConfig, onEvent: @escaping (Event) -> Void) {
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

    private func emit(_ e: Event) {
        DispatchQueue.main.async { self.onEvent(e) }
    }

    /// 메인 스레드에서 호출. 뷰어 앱을 앞으로 가져온 뒤 백그라운드에서 캡처를 돈다.
    public func start() {
        guard let first = config.regions.first else { return emit(.failed("캡처 영역이 없습니다")) }
        guard let viewer = appOwningWindow(at: first.center) else {
            return emit(.failed("선택한 영역 아래에서 뷰어 창을 찾지 못했습니다"))
        }
        emit(.status("대상 앱: \(viewer.localizedName ?? "?") — 다른 앱을 클릭하면 중단됩니다"))
        Thread.detachNewThread { [self] in
            do {
                try focusViewer(viewer, clickAt: first.center)
                emit(.status("\(viewer.localizedName ?? "뷰어") 포커스 확인 — 넘기기 시작: \(config.next.label)"))
                try run(viewerPID: viewer.processIdentifier)
            } catch {
                emit(.failed(error.localizedDescription))
            }
        }
    }

    private func frontmostPID() -> pid_t? {
        DispatchQueue.main.sync { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    }

    private func run(viewerPID: pid_t) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: config.outDir, withIntermediateDirectories: true)
        let tmpDir = fm.temporaryDirectory.appendingPathComponent("pagecap-\(UUID().uuidString)")
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmpDir) }

        var index = config.start
        func save(_ pages: [Shot]) throws {
            for png in pages.map(\.png) {
                let url = config.outDir.appendingPathComponent(fileName(for: index))
                if !config.overwrite && fm.fileExists(atPath: url.path) {
                    throw PageCapError("\(url.lastPathComponent) 이(가) 이미 있습니다. 시작 번호를 \(index + 1) 이상으로 바꾸거나 덮어쓰기를 켜세요")
                }
                try png.write(to: url)
                emit(.saved(url))
                index += 1
            }
        }

        if config.next == .acrobat {
            return try runAcrobat(viewerPID: viewerPID, tmpDir: tmpDir, save: save, saved: { index - self.config.start })
        }

        var previous = try capture(config.regions, tmpDir: tmpDir)
        try save(previous)

        let target = config.regions[0].center
        var reason = "최대 넘김 횟수(\(config.max))에 도달했습니다"
        for _ in 0..<config.max {
            if isCancelled { reason = "중지했습니다"; break }
            if frontmostPID() != viewerPID { reason = "포커스가 다른 앱으로 이동해 중단했습니다"; break }
            try turnPage(config.next, at: target)

            // 화면이 바뀐 뒤 두 번 연속 같은 모습(렌더링 완료)일 때 저장
            var last = previous
            var settled: [Shot]?
            let deadline = Date().addingTimeInterval(config.timeout)
            while Date() < deadline && !isCancelled {
                Thread.sleep(forTimeInterval: config.poll)
                let current = try capture(config.regions, tmpDir: tmpDir)
                if current != previous && current == last { settled = current; break }
                last = current
            }
            if isCancelled { reason = "중지했습니다"; break }
            guard let pages = settled ?? (last != previous ? last : nil) else {
                reason = "\(Int(config.timeout))초 동안 화면 변화가 없어 마지막 페이지로 보고 종료했습니다"
                break
            }
            try save(pages)
            previous = pages
        }
        emit(.finished(saved: index - config.start, reason: reason))
    }

    /// Acrobat 모드: 현재 쪽부터 마지막 쪽까지 쪽 번호로 이동하며 캡처. 영역이 2개(두 쪽 보기)면 2쪽씩 이동.
    private func runAcrobat(viewerPID: pid_t, tmpDir: URL, save: ([Shot]) throws -> Void, saved: () -> Int) throws {
        let (first, count) = try Acrobat.pageInfo()
        let step = config.regions.count
        emit(.status("Acrobat: \(first)쪽부터 \(count)쪽까지 캡처합니다"))

        // 첫 화면도 렌더링이 끝날 때까지 기다린다
        var previous = try waitForStable(after: nil, tmpDir: tmpDir)
        try save(previous)

        var page = first
        var reason = "마지막 쪽(\(count)쪽)까지 캡처했습니다"
        var turns = 0
        while page + step <= count {
            if isCancelled { reason = "중지했습니다"; break }
            if frontmostPID() != viewerPID { reason = "포커스가 다른 앱으로 이동해 중단했습니다"; break }
            if turns >= config.max { reason = "최대 넘김 횟수(\(config.max))에 도달했습니다"; break }
            page += step
            turns += 1
            try Acrobat.goto(page: page)
            previous = try waitForStable(after: previous, tmpDir: tmpDir)
            if isCancelled { reason = "중지했습니다"; break }
            try save(previous)
        }
        emit(.finished(saved: saved(), reason: reason))
    }

    /// 화면이 (previous 와 달라진 뒤) 두 번 연속 같은 모습이 될 때까지 기다린다.
    /// 쪽이 바뀌어도 모습이 같을 수 있으므로(빈 쪽 등) 시간이 지나면 마지막 화면을 그대로 쓴다.
    private func waitForStable(after previous: [Shot]?, tmpDir: URL) throws -> [Shot] {
        var last = try capture(config.regions, tmpDir: tmpDir)
        let deadline = Date().addingTimeInterval(min(config.timeout, 3))
        while Date() < deadline && !isCancelled {
            Thread.sleep(forTimeInterval: config.poll)
            let current = try capture(config.regions, tmpDir: tmpDir)
            if current == last && current != previous { return current }
            last = current
        }
        return last
    }
}
