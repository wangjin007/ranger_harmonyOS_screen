import CoreImage
import CoreMedia
import Foundation
import QuartzCore
import VideoToolbox

final class VideoRenderer {
    let displayLayer: CALayer
    var onEvent: ((String) -> Void)?

    private var formatDesc: CMVideoFormatDescription?
    private var decompressionSession: VTDecompressionSession?
    private var sps: Data?
    private var pps: Data?
    private var loggedReady = false
    private var loggedFrame = false
    private let lock = NSLock()
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var decodedFrameCount = 0
    private var displayRotation = 0
    private let rotationLock = NSLock()

    init() {
        let layer = CALayer()
        layer.contentsGravity = .resizeAspect
        layer.backgroundColor = CGColor(gray: 0.07, alpha: 1)
        displayLayer = layer
    }

    func reset() {
        lock.lock()
        if let decompressionSession {
            VTDecompressionSessionWaitForAsynchronousFrames(decompressionSession)
            VTDecompressionSessionInvalidate(decompressionSession)
        }
        decompressionSession = nil
        formatDesc = nil
        sps = nil
        pps = nil
        loggedReady = false
        loggedFrame = false
        decodedFrameCount = 0
        lock.unlock()
        rotationLock.lock()
        displayRotation = 0
        rotationLock.unlock()
        DispatchQueue.main.async {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.displayLayer.contents = nil
            CATransaction.commit()
        }
    }

    private func invalidateFormatLocked() {
        formatDesc = nil
        if let decompressionSession {
            VTDecompressionSessionWaitForAsynchronousFrames(decompressionSession)
            VTDecompressionSessionInvalidate(decompressionSession)
        }
        decompressionSession = nil
        loggedReady = false
    }

    func setDisplayRotation(_ degrees: Int) {
        rotationLock.lock()
        displayRotation = degrees
        rotationLock.unlock()
    }

    func decode(annexB: Data, ptsUs: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        let nals = NAL.split(annexB)
        guard !nals.isEmpty else { return }

        for nal in nals {
            let type = NAL.type(nal)
            if type == 7, sps != nal {
                sps = nal
                invalidateFormatLocked()
            } else if type == 8, pps != nal {
                pps = nal
                invalidateFormatLocked()
            }
        }

        if formatDesc == nil, let sps, let pps {
            guard let desc = NAL.makeFormatDescription(sps: sps, pps: pps) else {
                emit("SPS/PPS 无法创建解码格式")
                return
            }
            formatDesc = desc
            if !loggedReady {
                loggedReady = true
                emit("已收到 SPS/PPS，开始出画")
            }
        }
        guard let formatDesc else { return }
        guard ensureDecompressionSession(format: formatDesc), let decompressionSession else { return }

        let vcl = nals.filter { nal in
            let t = NAL.type(nal)
            return t != 7 && t != 8 && t != 9
        }
        guard !vcl.isEmpty else { return }

        let isIDR = vcl.contains { NAL.type($0) == 5 }
        decodedFrameCount += 1
        if decodedFrameCount == 1 || decodedFrameCount == 15 || decodedFrameCount % 60 == 0 {
            let types = nals.map { String(NAL.type($0)) }.joined(separator: ",")
            emit("已解析视频帧 #\(decodedFrameCount)，NAL 类型 [\(types)]，\(annexB.count) 字节")
        }
        var payload = vcl
        if isIDR, let sps, let pps {
            payload = [sps, pps] + vcl
        }
        guard let sample = NAL.makeSampleBuffer(nals: payload, format: formatDesc, ptsUs: ptsUs) else { return }
        CMSetAttachment(
            sample,
            key: kCMSampleAttachmentKey_NotSync,
            value: isIDR ? kCFBooleanFalse : kCFBooleanTrue,
            attachmentMode: kCMAttachmentMode_ShouldPropagate
        )
        var infoFlags = VTDecodeInfoFlags()
        let status = VTDecompressionSessionDecodeFrame(
            decompressionSession,
            sampleBuffer: sample,
            flags: VTDecodeFrameFlags(rawValue: 1 << 0),
            frameRefcon: nil,
            infoFlagsOut: &infoFlags
        )
        if status != noErr {
            emit("VideoToolbox 提交解码失败：\(status)")
        }
    }

    private func ensureDecompressionSession(format: CMVideoFormatDescription) -> Bool {
        if decompressionSession != nil {
            return true
        }
        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { refCon, _, status, _, imageBuffer, pts, duration in
                guard let refCon else { return }
                let renderer = Unmanaged<VideoRenderer>.fromOpaque(refCon).takeUnretainedValue()
                guard status == noErr, let imageBuffer else {
                    renderer.emit("VideoToolbox 解码失败：\(status)")
                    return
                }
                renderer.enqueueDecoded(imageBuffer: imageBuffer, pts: pts, duration: duration)
            },
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: format,
            decoderSpecification: nil,
            imageBufferAttributes: nil,
            outputCallback: &callback,
            decompressionSessionOut: &decompressionSession
        )
        if status != noErr {
            emit("VideoToolbox 初始化失败：\(status)")
            return false
        }
        emit("VideoToolbox 解码器已就绪")
        return true
    }

    private func enqueueDecoded(imageBuffer: CVImageBuffer, pts: CMTime, duration: CMTime) {
        rotationLock.lock()
        let rotation = displayRotation
        rotationLock.unlock()
        var image = CIImage(cvImageBuffer: imageBuffer)
        switch rotation {
        case 90:
            image = image.oriented(.right)
        case 180:
            image = image.oriented(.down)
        case 270:
            image = image.oriented(.left)
        default:
            break
        }
        guard let frame = ciContext.createCGImage(image, from: image.extent) else {
            emit("无法把解码帧转换为显示图像")
            return
        }
        DispatchQueue.main.async {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.displayLayer.contents = frame
            CATransaction.commit()
            if !self.loggedFrame {
                self.loggedFrame = true
                self.emit("已绘制第一帧")
            }
        }
    }

    private func emit(_ msg: String) {
        if Thread.isMainThread {
            onEvent?(msg)
        } else {
            DispatchQueue.main.async { self.onEvent?(msg) }
        }
    }
}

enum NAL {
    static func split(_ data: Data) -> [Data] {
        if data.count >= 4, data.starts(with: [0, 0, 0, 1]) || data.starts(with: [0, 0, 1]) {
            return splitAnnexB(data)
        }
        if data.count >= 7, data[0] == 1 {
            return splitAvcDecoderConfig(data)
        }
        let avcc = splitAvcc(data)
        if !avcc.isEmpty {
            return avcc
        }

        // Some HarmonyOS hardware encoders emit each non-IDR access unit as
        // one bare NAL buffer: no Annex-B start code and no AVCC length.
        // Treating that buffer as AVCC returns no NALs and silently freezes
        // AVSampleBufferDisplayLayer on the first IDR frame.
        if let first = data.first {
            let nalType = first & 0x1f
            if first & 0x80 == 0, (1...23).contains(nalType) {
                return [data]
            }
        }
        return []
    }

    static func type(_ nal: Data) -> UInt8 {
        guard let first = nal.first else { return 0 }
        return first & 0x1f
    }

    static func makeFormatDescription(sps: Data, pps: Data) -> CMVideoFormatDescription? {
        var desc: CMFormatDescription?
        let status: OSStatus = sps.withUnsafeBytes { spsRaw in
            pps.withUnsafeBytes { ppsRaw in
                guard let spsPtr = spsRaw.bindMemory(to: UInt8.self).baseAddress,
                      let ppsPtr = ppsRaw.bindMemory(to: UInt8.self).baseAddress else {
                    return -1
                }
                let pointers: [UnsafePointer<UInt8>] = [spsPtr, ppsPtr]
                let sizes: [Int] = [sps.count, pps.count]
                return pointers.withUnsafeBufferPointer { ptrs in
                    sizes.withUnsafeBufferPointer { szs in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: ptrs.baseAddress!,
                            parameterSetSizes: szs.baseAddress!,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &desc
                        )
                    }
                }
            }
        }
        guard status == noErr else { return nil }
        return desc
    }

    static func makeSampleBuffer(nals: [Data], format: CMVideoFormatDescription, ptsUs: UInt64) -> CMSampleBuffer? {
        var avcc = Data()
        for nal in nals {
            var len = UInt32(nal.count).bigEndian
            avcc.append(Data(bytes: &len, count: 4))
            avcc.append(nal)
        }
        var block: CMBlockBuffer?
        let total = avcc.count
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: total,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: total,
            flags: 0,
            blockBufferOut: &block
        ) == noErr, let block else { return nil }
        _ = avcc.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: total)
        }
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: Int64(ptsUs), timescale: 1_000_000),
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        var size = total
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &size,
            sampleBufferOut: &sample
        ) == noErr else { return nil }
        return sample
    }

    private static func splitAnnexB(_ data: Data) -> [Data] {
        var starts: [Int] = []
        var i = 0
        let bytes = [UInt8](data)
        while i + 3 <= bytes.count {
            if i + 4 <= bytes.count && bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] == 0 && bytes[i + 3] == 1 {
                starts.append(i)
                i += 4
                continue
            }
            if bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] == 1 {
                starts.append(i)
                i += 3
                continue
            }
            i += 1
        }
        var nals: [Data] = []
        for (idx, start) in starts.enumerated() {
            let sc = (start + 4 <= bytes.count && bytes[start] == 0 && bytes[start + 1] == 0 && bytes[start + 2] == 0 && bytes[start + 3] == 1) ? 4 : 3
            let nalStart = start + sc
            let nalEnd = idx + 1 < starts.count ? starts[idx + 1] : bytes.count
            if nalEnd > nalStart {
                nals.append(Data(bytes[nalStart..<nalEnd]))
            }
        }
        return nals
    }

    private static func splitAvcc(_ data: Data) -> [Data] {
        var nals: [Data] = []
        var offset = 0
        let bytes = [UInt8](data)
        while offset + 4 <= bytes.count {
            let len = (Int(bytes[offset]) << 24) | (Int(bytes[offset + 1]) << 16) | (Int(bytes[offset + 2]) << 8) | Int(bytes[offset + 3])
            offset += 4
            guard len > 0, offset + len <= bytes.count else { break }
            nals.append(Data(bytes[offset..<(offset + len)]))
            offset += len
        }
        return nals
    }

    private static func splitAvcDecoderConfig(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        guard bytes.count >= 7 else { return [] }
        var nals: [Data] = []
        var pos = 6
        let numSps = Int(bytes[5] & 0x1f)
        for _ in 0..<numSps {
            guard pos + 2 <= bytes.count else { return nals }
            let len = (Int(bytes[pos]) << 8) | Int(bytes[pos + 1])
            pos += 2
            guard len > 0, pos + len <= bytes.count else { return nals }
            nals.append(Data(bytes[pos..<(pos + len)]))
            pos += len
        }
        guard pos < bytes.count else { return nals }
        let numPps = Int(bytes[pos])
        pos += 1
        for _ in 0..<numPps {
            guard pos + 2 <= bytes.count else { return nals }
            let len = (Int(bytes[pos]) << 8) | Int(bytes[pos + 1])
            pos += 2
            guard len > 0, pos + len <= bytes.count else { return nals }
            nals.append(Data(bytes[pos..<(pos + len)]))
            pos += len
        }
        return nals
    }
}
