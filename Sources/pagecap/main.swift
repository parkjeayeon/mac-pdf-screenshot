// pagecap CLI — PageCapCore 를 명령줄에서 실행한다. GUI 는 PageCapApp.

import AppKit
import Foundation
import PageCapCore

struct Options {
    var outDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    var regions: [Region] = []
    var selectCount = 1
    var next = NextAction.default
    var start = 1
    var max = 2000
    var timeout = 6.0
    var overwrite = false
    var selectOnly = false
    var pdf: URL?
    var dpi = PDFQuality.high.dpi
}

let usage = """
사용법:
  pagecap [옵션]            영역을 드래그로 지정한 뒤 자동 캡처 시작
  pagecap select [옵션]     영역만 지정하고 --region 인자를 출력
  pagecap pdf FILE [옵션]   일반 PDF 의 각 쪽을 화면 캡처 없이 바로 PNG 로 저장
                            (--out, --start, --overwrite, --dpi 만 사용. 권한 필요 없음)

옵션:
  --out DIR           저장 폴더 (기본: 현재 폴더). 파일명은 001_capture.png 형식
  --regions N         드래그로 지정할 영역 수 (기본 1). 두 쪽 보기면 2 → 왼쪽, 오른쪽 순서
  --region x,y,w,h    영역을 직접 지정 (여러 번 사용 가능, 저장 순서대로)
  --next ACTION       페이지 넘기기: \(NextAction.cliNames.keys.sorted().joined(separator: " | "))
                      (기본 acrobat = Acrobat 스크립트로 현재 쪽부터 마지막 쪽까지)
  --start N           시작 번호 (기본 1)
  --max N             최대 페이지 넘김 횟수 (기본 2000)
  --timeout SEC       넘긴 뒤 화면이 이만큼 안 바뀌면 마지막 페이지로 보고 종료 (기본 6)
  --overwrite         같은 이름의 파일이 있으면 덮어쓰기
  --dpi N             pdf 명령의 해상도 (기본 200. 100/150/200/300/600 권장)

중단: 다른 앱을 클릭해 포커스를 옮기면 멈춥니다 (또는 터미널에서 Ctrl+C).
권한: 터미널 앱에 '화면 기록'과 '손쉬운 사용' 권한이 필요합니다.
"""

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(("오류: " + msg + "\n").data(using: .utf8)!)
    exit(1)
}

func parseOptions() -> Options {
    var o = Options()
    var args = Array(CommandLine.arguments.dropFirst())
    if args.first == "select" { o.selectOnly = true; args.removeFirst() }
    if args.first == "pdf" {
        args.removeFirst()
        guard let path = args.first, !path.hasPrefix("-") else { fail("pdf 명령에 PDF 파일 경로가 필요합니다") }
        o.pdf = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        args.removeFirst()
    }
    var i = 0
    func value() -> String {
        i += 1
        guard i < args.count else { fail("\(args[i - 1]) 에 값이 필요합니다") }
        return args[i]
    }
    while i < args.count {
        switch args[i] {
        case "-h", "--help": print(usage); exit(0)
        case "--out": o.outDir = URL(fileURLWithPath: (value() as NSString).expandingTildeInPath)
        case "--regions": o.selectCount = Int(value()) ?? 0
        case "--region":
            let v = value()
            guard let r = Region(v) else { fail("잘못된 영역: \(v) (x,y,w,h 형식)") }
            o.regions.append(r)
        case "--next":
            let v = value()
            guard let n = NextAction.cliNames[v.lowercased()] else { fail("알 수 없는 --next 값: \(v)") }
            o.next = n
        case "--start": o.start = Int(value()) ?? 1
        case "--max": o.max = Int(value()) ?? 2000
        case "--timeout": o.timeout = Double(value()) ?? 6
        case "--overwrite": o.overwrite = true
        case "--dpi":
            let v = value()
            guard let d = Double(v), (36...1200).contains(d) else { fail("--dpi 는 36~1200 사이 숫자여야 합니다") }
            o.dpi = CGFloat(d)
        default: fail("알 수 없는 옵션: \(args[i])\n\n\(usage)")
        }
        i += 1
    }
    guard (1...8).contains(o.selectCount) else { fail("--regions 는 1~8 사이여야 합니다") }
    return o
}

let opts = parseOptions()

if let pdf = opts.pdf {
    if case .failure(let error) = PDFExport.checkSupport() { fail(error.localizedDescription) }
    var config = PDFExportConfig(file: pdf, outDir: opts.outDir)
    config.dpi = opts.dpi
    config.start = opts.start
    config.overwrite = opts.overwrite
    let session = PDFExportSession(config: config) { event in
        switch event {
        case .status(let msg): print(msg)
        case .saved(let url): print("저장: \(url.lastPathComponent)")
        case .finished(let saved, let reason):
            print(reason)
            print("완료: \(saved)장 → \(opts.outDir.path)")
            exit(0)
        case .failed(let msg): fail(msg)
        }
    }
    session.start()
    dispatchMain()
}

if !opts.selectOnly {
    if !Permissions.screenRecording(prompt: true) {
        fail("'화면 기록' 권한이 없습니다. 시스템 설정 → 개인정보 보호 및 보안 → 화면 기록에서 터미널 앱을 켠 뒤 터미널을 재시작하세요")
    }
    if !Permissions.accessibility(prompt: true) {
        fail("'손쉬운 사용' 권한이 없습니다. 시스템 설정 → 개인정보 보호 및 보안 → 손쉬운 사용에서 터미널 앱을 켠 뒤 다시 실행하세요")
    }
}

var session: CaptureSession?

func begin(_ regions: [Region]) {
    print("영역: " + regions.map { "--region \($0.arg)" }.joined(separator: " "))
    if opts.selectOnly { exit(0) }

    var config = CaptureConfig(outDir: opts.outDir, regions: regions)
    config.next = opts.next
    config.start = opts.start
    config.max = opts.max
    config.timeout = opts.timeout
    config.overwrite = opts.overwrite

    session = CaptureSession(config: config) { event in
        switch event {
        case .status(let msg): print(msg)
        case .saved(let url): print("저장: \(url.lastPathComponent)")
        case .finished(let saved, let reason):
            print(reason)
            print("완료: \(saved)장 → \(opts.outDir.path)")
            exit(0)
        case .failed(let msg): fail(msg)
        }
    }
    session?.start()
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
DispatchQueue.main.async {
    if opts.regions.isEmpty {
        RegionSelector.select(count: opts.selectCount) { regions in
            guard let regions else { fail("영역 선택을 취소했습니다") }
            begin(regions)
        }
    } else {
        begin(opts.regions)
    }
}
app.run()
