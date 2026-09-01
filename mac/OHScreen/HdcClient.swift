import Foundation

enum HdcError: LocalizedError {
    case notFound
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "找不到 hdc。请安装 DevEco Studio，并把 sdk 下的 toolchains 加到 PATH。"
        case .failed(let msg):
            return msg
        }
    }
}

struct HdcResult {
    let status: Int32
    let stdout: String
    let stderr: String

    var combined: String {
        let a = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        return a + "\n" + b
    }
}

final class HdcClient {
    let path: String
    private let timeout: TimeInterval

    init(path: String, timeout: TimeInterval = 30) {
        self.path = path
        self.timeout = timeout
    }

    static func find() -> HdcClient? {
        if let env = ProcessInfo.processInfo.environment["HDC"], !env.isEmpty, FileManager.default.isExecutableFile(atPath: env) {
            return HdcClient(path: env)
        }
        if let which = which("hdc") {
            return HdcClient(path: which)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let roots = [
            "\(home)/Library/Huawei/Sdk",
            "\(home)/Huawei/Sdk",
            "\(home)/command-line-tools",
            "/Applications/DevEco-Studio.app",
            "/opt/homebrew/bin",
            "/usr/local/bin"
        ]
        for root in roots {
            if let found = findExecutable(named: "hdc", under: root, maxDepth: 8) {
                return HdcClient(path: found)
            }
        }
        return nil
    }

    func listTargets() throws -> [String] {
        let r = try run(["list", "targets"])
        let lines = r.stdout
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "[Empty]" }
        return lines.map { line in
            String(line.split(whereSeparator: { $0.isWhitespace }).first ?? Substring(line))
        }
    }

    func install(serial: String, hap: String) throws {
        let r = try run(["-t", serial, "install", "-r", hap])
        if r.status != 0 {
            throw HdcError.failed("install 失败：\(r.combined)")
        }
    }

    func resetForward(serial: String, port: Int) throws {
        _ = try? run(["-t", serial, "fport", "rm", "tcp:\(port)", "tcp:\(port)"])
        let r = try run(["-t", serial, "fport", "tcp:\(port)", "tcp:\(port)"])
        let text = r.combined.lowercased()
        if r.status != 0 && !text.contains("ok") && !text.contains("already") {
            throw HdcError.failed("fport 失败：\(r.combined)")
        }
    }

    func startAbility(serial: String) throws {
        var r = try run([
            "-t", serial, "shell", "aa", "start",
            "-b", "com.ohscreen.server",
            "-a", "EntryAbility",
            "-m", "entry"
        ])
        if r.status != 0 {
            r = try run([
                "-t", serial, "shell", "aa", "start",
                "-b", "com.ohscreen.server",
                "-a", "EntryAbility"
            ])
        }
        if r.status != 0 {
            throw HdcError.failed("aa start 失败：\(r.combined)")
        }
    }

    func snapshot(serial: String, to localPath: String) throws {
        let remote = "/data/local/tmp/ohscreen.jpg"
        let shot = try run(["-t", serial, "shell", "snapshot_display", "-f", remote])
        if shot.status != 0 {
            throw HdcError.failed("截图失败：\(shot.combined)")
        }
        let recv = try run(["-t", serial, "file", "recv", remote, localPath])
        if recv.status != 0 {
            throw HdcError.failed("拉取截图失败：\(recv.combined)")
        }
    }

    @discardableResult
    func run(_ args: [String]) throws -> HdcResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        try proc.run()

        let deadline = Date().addingTimeInterval(timeout)
        while proc.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if proc.isRunning {
            proc.terminate()
            throw HdcError.failed("hdc \(args.joined(separator: " ")) 超时")
        }
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return HdcResult(status: proc.terminationStatus, stdout: stdout, stderr: stderr)
    }

    private static func which(_ name: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        proc.arguments = [name]
        let extra = ProcessInfo.processInfo.environment["PATH"] ?? ""
        proc.environment = ProcessInfo.processInfo.environment.merging([
            "PATH": extra + ":/opt/homebrew/bin:/usr/local/bin"
        ]) { _, new in new }
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return nil
        }
        guard proc.terminationStatus == 0 else { return nil }
        let path = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let path, FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    private static func findExecutable(named name: String, under root: String, maxDepth: Int) -> String? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root, isDirectory: &isDir) else { return nil }
        if !isDir.boolValue {
            return (root as NSString).lastPathComponent == name && fm.isExecutableFile(atPath: root) ? root : nil
        }
        guard let enumerator = fm.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.isRegularFileKey, .isExecutableKey], options: [.skipsHiddenFiles]) else {
            return nil
        }
        while let url = enumerator.nextObject() as? URL {
            let depth = url.path.replacingOccurrences(of: root, with: "").split(separator: "/").count
            if depth > maxDepth {
                enumerator.skipDescendants()
                continue
            }
            if url.lastPathComponent == name && fm.isExecutableFile(atPath: url.path) {
                return url.path
            }
        }
        return nil
    }
}

enum HapLocator {
    static let defaultRelative = "phone/entry/build/default/outputs/default/entry-default-signed.hap"

    static func find(saved: String?) -> String? {
        if let saved, FileManager.default.fileExists(atPath: saved) {
            return saved
        }
        var url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for _ in 0..<10 {
            let candidate = url.appendingPathComponent(defaultRelative).path
            if FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
            url.deleteLastPathComponent()
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let extras = [
            home.appendingPathComponent("wj/harmonyOS _screen/\(defaultRelative)").path,
            home.appendingPathComponent("harmonyOS _screen/\(defaultRelative)").path
        ]
        return extras.first { FileManager.default.fileExists(atPath: $0) }
    }
}
