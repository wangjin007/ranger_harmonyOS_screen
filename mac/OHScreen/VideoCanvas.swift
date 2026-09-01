import SwiftUI
import AppKit
import QuartzCore

struct VideoCanvas: NSViewRepresentable {
    let layer: CALayer

    func makeNSView(context: Context) -> LayerHostView {
        LayerHostView(videoLayer: layer)
    }

    func updateNSView(_ nsView: LayerHostView, context: Context) {
        nsView.needsLayout = true
    }
}

final class LayerHostView: NSView {
    private let videoLayer: CALayer

    init(videoLayer: CALayer) {
        self.videoLayer = videoLayer
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = .black
        videoLayer.removeFromSuperlayer()
        videoLayer.contentsGravity = .resizeAspect
        videoLayer.backgroundColor = CGColor(gray: 0.07, alpha: 1)
        layer?.addSublayer(videoLayer)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer.frame = bounds
        CATransaction.commit()
    }
}
