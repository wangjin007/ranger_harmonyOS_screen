import Foundation
import Network

enum StreamError: Error, Equatable, LocalizedError {
    case header
    case closed
    case timeout
    case auth
    case listen

    var errorDescription: String? {
        switch self {
        case .header: return "协议头无效。请用 DevEco 重新 Run 平板后再点连接（不要只开着旧进程）。"
        case .closed: return "连接已断开"
        case .timeout: return "连接手机超时。请看平板上 OHScreen 是否还在跑；弹出录屏/共享内容时选「屏幕」并允许。"
        case .auth: return "配对码不对，或手机不是扫的当前二维码。"
        case .listen: return "无法监听无线端口。请允许防火墙访问 OHScreen。"
        }
    }
}

struct StreamHeader {
    let width: Int
    let height: Int
    let fps: Int
    var rotation: Int = 0
}

final class StreamSession {
    private var connection: NWConnection?
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.ohscreen.stream")
    private var buffer = Data()
    private var header: StreamHeader?
    private var onHeader: ((StreamHeader) -> Void)?
    private var onSizeChange: ((StreamHeader) -> Void)?
    private var onFrame: ((Data, UInt64) -> Void)?
    private var onClose: ((Error?) -> Void)?
    private var onReject: (() -> Void)?
    private var closed = false
    private var requireAuth = false
    private var authenticated = true
    private var expectedPin: UInt32 = 0

    func stop() {
        closed = true
        listener?.cancel()
        listener = nil
        connection?.cancel()
        connection = nil
        buffer.removeAll()
        header = nil
        requireAuth = false
        authenticated = true
        onReject = nil
    }

    func start(
        host: String,
        port: UInt16,
        retries: Int,
        onHeader: @escaping (StreamHeader) -> Void,
        onSizeChange: @escaping (StreamHeader) -> Void,
        onFrame: @escaping (Data, UInt64) -> Void,
        onClose: @escaping (Error?) -> Void
    ) {
        self.onHeader = onHeader
        self.onSizeChange = onSizeChange
        self.onFrame = onFrame
        self.onClose = onClose
        closed = false
        requireAuth = false
        authenticated = true
        expectedPin = 0
        attempt(host: host, port: port, left: retries)
    }

    func listen(
        port: UInt16,
        pin: UInt32,
        onHeader: @escaping (StreamHeader) -> Void,
        onSizeChange: @escaping (StreamHeader) -> Void,
        onFrame: @escaping (Data, UInt64) -> Void,
        onClose: @escaping (Error?) -> Void,
        onReject: (() -> Void)? = nil
    ) {
        stop()
        self.onHeader = onHeader
        self.onSizeChange = onSizeChange
        self.onFrame = onFrame
        self.onClose = onClose
        self.onReject = onReject
        closed = false
        requireAuth = true
        authenticated = false
        expectedPin = pin
        do {
            let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
            self.listener = listener
            listener.newConnectionHandler = { [weak self] conn in
                guard let self else { return }
                self.queue.async {
                    if self.closed { conn.cancel(); return }
                    if self.connection != nil {
                        conn.cancel()
                        DispatchQueue.main.async { self.onReject?() }
                        return
                    }
                    self.connection = conn
                    conn.stateUpdateHandler = { [weak self] state in
                        guard let self else { return }
                        switch state {
                        case .ready:
                            self.receiveMore()
                        case .failed, .cancelled:
                            conn.cancel()
                            if self.closed { return }
                            if self.header != nil || self.authenticated {
                                self.finish(StreamError.closed)
                            }
                        default:
                            break
                        }
                    }
                    conn.start(queue: self.queue)
                }
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                if case .failed = state {
                    self.finish(StreamError.listen)
                }
            }
            listener.start(queue: queue)
        } catch {
            finish(StreamError.listen)
        }
    }

    private func attempt(host: String, port: UInt16, left: Int) {
        if closed { return }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        connection = conn
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.receiveMore()
            case .failed, .cancelled:
                conn.cancel()
                if self.closed { return }
                if self.header != nil {
                    self.finish(StreamError.closed)
                    return
                }
                if left <= 1 {
                    self.finish(StreamError.timeout)
                    return
                }
                self.queue.asyncAfter(deadline: .now() + 0.4) {
                    self.attempt(host: host, port: port, left: left - 1)
                }
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    private func receiveMore() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if self.closed { return }
            if let error {
                self.finish(error)
                return
            }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                do {
                    try self.drain()
                } catch {
                    self.finish(error)
                    return
                }
            }
            if isComplete {
                self.finish(StreamError.closed)
                return
            }
            self.receiveMore()
        }
    }

    private func drain() throws {
        if requireAuth && !authenticated {
            guard buffer.count >= 8 else { return }
            let magic = String(bytes: buffer.prefix(4), encoding: .ascii) ?? ""
            let pin = be32(buffer, 4)
            buffer.removeSubrange(0..<8)
            guard magic == "OHPN", pin == expectedPin else {
                throw StreamError.auth
            }
            authenticated = true
        }
        if header == nil {
            guard buffer.count >= 12 else { return }
            let magic = String(bytes: buffer.prefix(4), encoding: .ascii) ?? ""
            guard magic == "OHSC", buffer[4] == 1 else {
                throw StreamError.header
            }
            let width = Int(buffer[6]) << 8 | Int(buffer[7])
            let height = Int(buffer[8]) << 8 | Int(buffer[9])
            let fps = Int(buffer[10])
            buffer.removeSubrange(0..<12)
            let h = StreamHeader(width: width, height: height, fps: fps)
            header = h
            DispatchQueue.main.async { self.onHeader?(h) }
        }
        while buffer.count >= 12 {
            let length = Int(be32(buffer, 0))
            if length == 0xFFFFFFFF {
                let type = Int(buffer[4]) << 8 | Int(buffer[5])
                let width = Int(buffer[6]) << 8 | Int(buffer[7])
                let height = Int(buffer[8]) << 8 | Int(buffer[9])
                let rotation = Int(buffer[10]) << 8 | Int(buffer[11])
                buffer.removeSubrange(0..<12)
                if type == 1, width > 0, height > 0 {
                    let fps = header?.fps ?? 30
                    let h = StreamHeader(width: width, height: height, fps: fps, rotation: rotation)
                    header = h
                    DispatchQueue.main.async { self.onSizeChange?(h) }
                }
                continue
            }
            if length <= 0 || length > 8 * 1024 * 1024 {
                throw StreamError.header
            }
            guard buffer.count >= 12 + length else { return }
            let pts = be64(buffer, 4)
            let payload = Data(buffer[12..<(12 + length)])
            buffer.removeSubrange(0..<(12 + length))
            onFrame?(payload, pts)
        }
    }

    private func finish(_ error: Error?) {
        if closed { return }
        closed = true
        listener?.cancel()
        listener = nil
        connection?.cancel()
        connection = nil
        DispatchQueue.main.async { self.onClose?(error) }
    }

    private func be32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset]) << 24 | UInt32(data[offset + 1]) << 16 | UInt32(data[offset + 2]) << 8 | UInt32(data[offset + 3])
    }

    private func be64(_ data: Data, _ offset: Int) -> UInt64 {
        (UInt64(be32(data, offset)) << 32) | UInt64(be32(data, offset + 4))
    }
}
