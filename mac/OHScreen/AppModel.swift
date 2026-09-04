import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

enum LinkMode: String, CaseIterable, Identifiable {
    case usb
    case wireless

    var id: String { rawValue }

    var title: String {
        switch self {
        case .usb: return "USB"
        case .wireless: return "无线"
        }
    }
}

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
    @Published var linkMode: LinkMode = .usb
    @Published var wirelessPinText: String = ""
    @Published var wirelessQR: NSImage?
    @Published var wirelessIPs: String = ""

    let renderer = VideoRenderer()
    private let stream = StreamSession()
    private let usbPort = 27183
    private var frameCount = 0
    private var sessionEpoch = 0
    private var wirelessPin: UInt32 = 0

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
                        if !self.connected {
                            self.status = "未发现设备"
                        }
                    } else {
                        self.log("发现设备：\(list.joined(separator: ", "))")
                        if !self.connected {
                            self.status = "已发现 \(list.count) 台设备"
                        }
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

    func setLinkMode(_ mode: LinkMode) {
        if mode == linkMode, mode != .wireless || wirelessQR != nil {
            return
        }
        sessionEpoch += 1
        stream.stop()
        renderer.reset()
        connected = false
        busy = false
        linkMode = mode
        if mode == .wireless {
            startWirelessListen()
        } else {
            wirelessQR = nil
            wirelessPinText = ""
            wirelessIPs = ""
            status = "未连接"
            refreshDevices()
        }
    }

    func startWirelessListen() {
        sessionEpoch += 1
        let epoch = sessionEpoch
        let serial = selectedDevice
        let known = devices
        stream.stop()
        renderer.reset()
        connected = false
        busy = false
        frameCount = 0

        DispatchQueue.global(qos: .userInitiated).async {
            if let hdc = HdcClient.find() {
                hdc.removeAllForwards(port: self.usbPort)
                if !serial.isEmpty {
                    hdc.removeForward(serial: serial, port: self.usbPort)
                }
                for id in known where id != serial {
                    hdc.removeForward(serial: id, port: self.usbPort)
                }
            }
            Thread.sleep(forTimeInterval: 0.2)
            DispatchQueue.main.async {
                guard epoch == self.sessionEpoch, self.linkMode == .wireless else { return }
                self.beginWirelessListen(epoch: epoch, rotatePin: true)
            }
        }
    }

    private func beginWirelessListen(epoch: Int, rotatePin: Bool) {
        if rotatePin || wirelessPin == 0 {
            wirelessPin = WirelessPairing.randomPin()
            wirelessPinText = String(format: "%06d", Int(wirelessPin))
            guard let payload = WirelessPairing.qrPayload(pin: wirelessPin) else {
                wirelessQR = nil
                status = "没有局域网 IP"
                log("本机没有可用的 IPv4。请先连 Wi-Fi，或让电脑加入手机热点。")
                return
            }
            wirelessQR = WirelessPairing.qrImage(from: payload)
            wirelessIPs = WirelessPairing.ipv4Addresses().joined(separator: ", ")
            log("无线等待扫码 \(payload)")
        } else {
            log("无线继续等待扫码，配对码 \(wirelessPinText)")
        }
        status = "等待手机扫码"
        stream.listen(
            port: WirelessPairing.port,
            pin: wirelessPin,
            onHeader: { [weak self] header in self?.handleHeader(header) },
            onSizeChange: { [weak self] header in self?.handleSizeChange(header) },
            onFrame: { [weak self] data, pts in self?.handleFrame(data, pts: pts) },
            onClose: { [weak self] err in self?.handleClose(err, epoch: epoch) },
            onReject: { [weak self] in
                self?.log("已有设备在投屏，已拒绝另一台手机。换机请先点断开，或让当前手机点停止后再扫。")
            }
        )
    }

    func connect() {
        guard linkMode == .usb else {
            startWirelessListen()
            return
        }
        guard !selectedDevice.isEmpty else {
            log("请先刷新并选择设备")
            return
        }
        sessionEpoch += 1
        let epoch = sessionEpoch
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
                let live = try hdc.listTargets()
                DispatchQueue.main.async {
                    self.hdcPath = hdc.path
                    self.devices = live
                    if self.selectedDevice.isEmpty || !live.contains(self.selectedDevice) {
                        self.selectedDevice = live.first ?? ""
                    }
                    self.log("hdc：\(hdc.path)")
                }
                if !live.contains(serial) {
                    throw HdcError.failed("设备 \(serial) 已不在线。请点「刷新设备」，选中新插入的设备后再连接。")
                }
                try hdc.resetForward(serial: serial, port: self.usbPort)
                DispatchQueue.main.async { self.log("已转发 tcp:\(self.usbPort)") }

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
                    guard epoch == self.sessionEpoch, self.linkMode == .usb else { return }
                    self.stream.start(
                        host: "127.0.0.1",
                        port: UInt16(self.usbPort),
                        retries: 40,
                        onHeader: { [weak self] header in self?.handleHeader(header) },
                        onSizeChange: { [weak self] header in self?.handleSizeChange(header) },
                        onFrame: { [weak self] data, pts in self?.handleFrame(data, pts: pts) },
                        onClose: { [weak self] err in self?.handleClose(err, epoch: epoch) }
                    )
                }
            } catch {
                DispatchQueue.main.async {
                    guard epoch == self.sessionEpoch else { return }
                    self.busy = false
                    self.connected = false
                    self.status = "连接失败"
                    self.log(error.localizedDescription)
                    self.refreshDevices()
                }
            }
        }
    }

    func disconnect() {
        sessionEpoch += 1
        stream.stop()
        renderer.reset()
        connected = false
        busy = false
        if linkMode == .wireless {
            startWirelessListen()
        } else {
            status = "已断开"
            log("已断开")
            clearUsbForward()
            refreshDevices()
        }
    }

    private func handleHeader(_ header: StreamHeader) {
        videoSize = CGSize(width: header.width, height: header.height)
        connected = true
        busy = false
        status = "投屏中 \(header.width)×\(header.height)@\(header.fps)"
        log("收到视频头 \(header.width)×\(header.height) @\(header.fps)")
    }

    private func handleSizeChange(_ header: StreamHeader) {
        renderer.setDisplayRotation(header.rotation)
        videoSize = CGSize(width: header.width, height: header.height)
        status = "投屏中 \(header.width)×\(header.height)@\(header.fps)"
        log("方向切换 \(header.rotation)° \(header.width)×\(header.height)")
    }

    private func handleFrame(_ data: Data, pts: UInt64) {
        renderer.decode(annexB: data, ptsUs: pts)
        let bytes = data.count
        DispatchQueue.main.async {
            self.frameCount += 1
            if self.frameCount == 1 || self.frameCount == 15 || self.frameCount == 60 {
                self.log("收到画面帧 #\(self.frameCount)，\(bytes) 字节")
            }
        }
    }

    private func handleClose(_ err: Error?, epoch: Int) {
        guard epoch == sessionEpoch else { return }
        connected = false
        busy = false
        renderer.reset()
        if let err {
            log("连接结束：\(err.localizedDescription)")
        } else {
            log("连接结束：手机端关闭了投屏")
        }
        if linkMode == .wireless {
            if let streamErr = err as? StreamError, streamErr == .listen {
                status = "无线监听失败"
                return
            }
            status = "等待手机扫码"
            log("无线会话结束，可继续扫当前二维码换机。")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self, epoch == self.sessionEpoch, self.linkMode == .wireless, !self.connected else { return }
                self.beginWirelessListen(epoch: epoch, rotatePin: false)
            }
        } else {
            if let streamErr = err as? StreamError, streamErr == .timeout {
                status = "连接超时"
            } else {
                status = "USB 已断开"
            }
            log("请点「刷新设备」。同一台或换机插入后，选中设备再点连接。")
            clearUsbForward()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self, self.linkMode == .usb, !self.connected else { return }
                self.refreshDevices()
            }
        }
    }

    private func clearUsbForward() {
        let serial = selectedDevice
        let known = devices
        DispatchQueue.global(qos: .utility).async {
            guard let hdc = HdcClient.find() else { return }
            hdc.removeAllForwards(port: self.usbPort)
            if !serial.isEmpty {
                hdc.removeForward(serial: serial, port: self.usbPort)
            }
            for id in known where id != serial {
                hdc.removeForward(serial: id, port: self.usbPort)
            }
        }
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
