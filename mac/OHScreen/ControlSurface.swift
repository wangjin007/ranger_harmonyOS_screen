import AppKit
import SwiftUI

struct ControlSurface: NSViewRepresentable {
    var onTouch: (UInt8, CGFloat, CGFloat, CGSize) -> Void
    var onKey: (NSEvent, Bool) -> Void

    func makeNSView(context: Context) -> ControlNSView {
        let view = ControlNSView()
        view.onTouch = onTouch
        view.onKey = onKey
        return view
    }

    func updateNSView(_ nsView: ControlNSView, context: Context) {
        nsView.onTouch = onTouch
        nsView.onKey = onKey
    }
}

final class ControlNSView: NSView {
    var onTouch: ((UInt8, CGFloat, CGFloat, CGSize) -> Void)?
    var onKey: ((NSEvent, Bool) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        emit(1, event)
    }

    override func mouseDragged(with event: NSEvent) {
        emit(2, event)
    }

    override func mouseUp(with event: NSEvent) {
        emit(3, event)
    }

    override func keyDown(with event: NSEvent) {
        onKey?(event, true)
    }

    override func keyUp(with event: NSEvent) {
        onKey?(event, false)
    }

    private func emit(_ action: UInt8, _ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let x = point.x
        let y = bounds.height - point.y
        onTouch?(action, x, y, bounds.size)
    }
}

enum HarmonyKey {
    static let shiftLeft: UInt16 = 2047

    static func code(for event: NSEvent) -> UInt16? {
        switch event.keyCode {
        case 0: return 2017
        case 1: return 2035
        case 2: return 2020
        case 3: return 2022
        case 4: return 2024
        case 5: return 2023
        case 6: return 2042
        case 7: return 2040
        case 8: return 2019
        case 9: return 2038
        case 11: return 2018
        case 12: return 2033
        case 13: return 2039
        case 14: return 2021
        case 15: return 2034
        case 16: return 2041
        case 17: return 2036
        case 31: return 2031
        case 32: return 2037
        case 34: return 2025
        case 35: return 2032
        case 37: return 2028
        case 38: return 2026
        case 40: return 2027
        case 45: return 2030
        case 46: return 2029
        case 18: return 2001
        case 19: return 2002
        case 20: return 2003
        case 21: return 2004
        case 23: return 2005
        case 22: return 2006
        case 26: return 2007
        case 28: return 2008
        case 25: return 2009
        case 29: return 2000
        case 36: return 2054
        case 48: return 2049
        case 49: return 2050
        case 51: return 2055
        case 53: return 2070
        case 117: return 2071
        case 123: return 2014
        case 124: return 2015
        case 125: return 2013
        case 126: return 2012
        case 43: return 2043
        case 47: return 2044
        case 44: return 2064
        case 41: return 2062
        case 39: return 2063
        case 33: return 2059
        case 30: return 2060
        case 42: return 2061
        case 27: return 2057
        case 24: return 2058
        case 50: return 2056
        default: return nil
        }
    }
}
