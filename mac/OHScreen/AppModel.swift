import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

final class AppModel: ObservableObject {
    @Published var devices: [String] = []
    @Published var selectedDevice: String = ""
    @Published var hapPath: String = UserDefaults.standard.string(forKey: "hapPath") ?? ""
    @Published var logs: [String] = []
    @Published var status: String = "未连接"
    @Published var videoSize: CGSize = CGSize(width: 9, height: 16)
    @Published var busy: Bool = false
    @Published var connected: Bool = false
    @Published var hdcPath: String = ""

    let renderer = VideoRenderer()
    private let stream = StreamSession()
    private let port = 27183
    private var frameCount = 0

    init() {
        renderer.onEvent = { [weak self] msg in
            self?.log(msg)
        }
    }

    func log(_ msg: String) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.log(msg)
            }
            return
        }
        let line = "\(Self.stamp())  \(msg)"
        logs.append(line)
        if logs.count > 400 {
            logs.removeFirst(logs.count - 400)
        }
        print(line)
    }

    func refreshDevices() {
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            defer {
                DispatchQueue.main.async { self.busy = false }
            }
            guard let hdc = HdcClient.find() else {
                DispatchQueue.main.async {
                    self.hdcPath = ""
                    self.log("找不到 hdc。安装 DevEco Studio 后把 toolchains 加到 PATH，或设置环境变量 HDC。")
                    self.status = "hdc 不可用"
                }
                return
            }
            do {
                let list = try hdc.listTargets()
                DispatchQueue.main.async {
                    self.hdcPath = hdc.path
                    self.devices = list
                    if self.selectedDevice.isEmpty || !list.contains(self.selectedDevice) {
                        self.selectedDevice = list.first ?? ""
                    }
                    if list.isEmpty {
                        self.log("hdc 在 \(hdc.path)，但没有设备。请打开 USB 调试并授权这台电脑。")
                        self.status = "未发现设备"
                    } else {
                        self.log("发现设备：\(list.joined(separator: ", "))")
                        self.status = "已发现 \(list.count) 台设备"
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.hdcPath = hdc.path
                    self.log("list targets 失败：\(error.localizedDescription)")
                }
            }
        }
    }

    func pickHap() {
        let panel = NSOpenPanel()
        if let hapType = UTType(filenameExtension: "hap") {
            panel.allowedContentTypes = [hapType]
        }
        panel.allowsOtherFileTypes = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.message = "选择 DevEco 编出的 Debug HAP（entry-default-signed.hap）"
        if panel.runModal() == .OK, let url = panel.url {
            hapPath = url.path
            UserDefaults.standard.set(hapPath, forKey: "hapPath")
            log("HAP：\(hapPath)")
        }
    }

    func connect() {
        guard !selectedDevice.isEmpty else {
            log("请先刷新并选择设备")
            return
        }
        busy = true
        connected = false
        status = "正在连接…"
        frameCount = 0
        renderer.reset()
        stream.stop()
        let serial = selectedDevice
        let hapHint = hapPath
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                guard let hdc = HdcClient.find() else { throw HdcError.notFound }
                DispatchQueue.main.async {
                    self.hdcPath = hdc.path
                    self.log("hdc：\(hdc.path)")
                }
                try hdc.resetForward(serial: serial, port: self.port)
                DispatchQueue.main.async { self.log("已转发 tcp:\(self.port)") }

                let hap = HapLocator.find(saved: hapHint.isEmpty ? nil : hapHint)
                if let hap {
                    DispatchQueue.main.async {
                        self.hapPath = hap
                        UserDefaults.standard.set(hap, forKey: "hapPath")
                        self.log("安装 \(hap)")
                    }
                    try hdc.install(serial: serial, hap: hap)
                    DispatchQueue.main.async { self.log("HAP 已安装") }
                } else {
                    DispatchQueue.main.async {
                        self.log("未找到 signed hap，改为启动已安装的 com.ohscreen.server（请先用 DevEco Run 过一次）")
                    }
                }
                try hdc.startAbility(serial: serial)
                DispatchQueue.main.async { self.log("已拉起手机端，等待监听。连接后请在手机上允许录屏。") }

                DispatchQueue.main.async {
                    self.stream.start(
                        host: "127.0.0.1",
                        port: UInt16(self.port),
                        retries: 40,
                        onHeader: { header in
                            self.videoSize = CGSize(width: header.width, height: header.height)
                            self.connected = true
                            self.busy = false
                            self.status = "投屏中 \(header.width)×\(header.height)@\(header.fps)"
                            self.log("收到视频头 \(header.width)×\(header.height) @\(header.fps)")
                        },
                        onFrame: { data, pts in
                            self.renderer.decode(annexB: data, ptsUs: pts)
                            let bytes = data.count
                            DispatchQueue.main.async {
                                self.frameCount += 1
                                if self.frameCount == 1 || self.frameCount == 15 || self.frameCount == 60 {
                                    self.log("收到画面帧 #\(self.frameCount)，\(bytes) 字节")
                                }
                            }
                        },
                        onClose: { err in
                            self.connected = false
                            self.busy = false
                            self.status = "已断开"
                            if let err {
                                self.log("连接结束：\(err.localizedDescription)")
                            } else {
                                self.log("连接结束：手机端关闭了投屏")
                            }
                            self.log("手机端停了、拒绝录屏、或没选出「屏幕」，Mac 这边就会断开。请用 DevEco 重新 Run 平板，再点连接。")
                        }
                    )
                }
            } catch {
                DispatchQueue.main.async {
                    self.busy = false
                    self.connected = false
                    self.status = "连接失败"
                    self.log(error.localizedDescription)
                }
            }
        }
    }

    func disconnect() {
        stream.stop()
        renderer.reset()
        connected = false
        status = "已断开"
        log("已断开")
    }

    func snapshot() {
        guard !selectedDevice.isEmpty else { return }
        busy = true
        let serial = selectedDevice
        DispatchQueue.global(qos: .userInitiated).async {
            defer { DispatchQueue.main.async { self.busy = false } }
            do {
                guard let hdc = HdcClient.find() else { throw HdcError.notFound }
                let dir = NSTemporaryDirectory() + "ohscreen-diag.jpg"
                try hdc.snapshot(serial: serial, to: dir)
                DispatchQueue.main.async {
                    self.log("诊断截图：\(dir)")
                    NSWorkspace.shared.open(URL(fileURLWithPath: dir))
                }
            } catch {
                DispatchQueue.main.async { self.log(error.localizedDescription) }
            }
        }
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
    }
}
