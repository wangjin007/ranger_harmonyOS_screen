import AVFoundation
import Darwin
import Foundation

final class AudioPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var wired = false
    private var sampleRate: Double = 0
    private var channels: AVAudioChannelCount = 0
    private var videoPts: UInt64 = 0
    private var videoHostUs: UInt64 = 0
    private var volume: Float = 1

    func reset() {
        node.stop()
        videoPts = 0
        videoHostUs = 0
    }

    func setVolume(percent: Int) {
        volume = Float(max(0, min(percent, 100))) / 100
        engine.mainMixerNode.outputVolume = volume
    }

    func noteVideo(ptsUs: UInt64) {
        videoPts = ptsUs
        videoHostUs = Self.hostUs()
    }

    func play(pcm: Data, ptsUs: UInt64, sampleRate: Double, channels: Int) {
        if videoHostUs != 0 {
            let now = Self.hostUs()
            let videoNow = videoPts &+ (now &- videoHostUs)
            if videoNow > ptsUs, videoNow &- ptsUs > 250_000 {
                return
            }
        }
        let ch = AVAudioChannelCount(max(1, min(channels, 2)))
        let rate = sampleRate > 0 ? sampleRate : 48_000
        ensureStarted(sampleRate: rate, channels: ch)
        let bytesPerFrame = 2 * Int(ch)
        guard bytesPerFrame > 0 else { return }
        let frames = pcm.count / bytesPerFrame
        guard frames > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: rate, channels: ch, interleaved: true),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
            return
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        pcm.withUnsafeBytes { raw in
            guard let src = raw.baseAddress, let dst = buffer.audioBufferList.pointee.mBuffers.mData else { return }
            memcpy(dst, src, frames * bytesPerFrame)
        }
        node.scheduleBuffer(buffer, completionHandler: nil)
        if !node.isPlaying {
            node.play()
        }
    }

    private func ensureStarted(sampleRate: Double, channels: AVAudioChannelCount) {
        if wired, self.sampleRate == sampleRate, self.channels == channels {
            if !engine.isRunning {
                try? engine.start()
            }
            return
        }
        if wired {
            engine.disconnectNodeOutput(node)
        } else {
            engine.attach(node)
            wired = true
        }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: channels, interleaved: true) else {
            return
        }
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = volume
        self.sampleRate = sampleRate
        self.channels = channels
        if !engine.isRunning {
            try? engine.start()
        }
        node.play()
    }

    private static func hostUs() -> UInt64 {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let ticks = mach_absolute_time()
        return ticks * UInt64(info.numer) / UInt64(info.denom) / 1_000
    }
}
