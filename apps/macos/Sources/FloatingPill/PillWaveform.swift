// PillWaveform.swift — the pill's animated waveform dots, drawn with Core
// Animation. Split out of PillView.swift to keep that file under SwiftLint's
// length limit.
import AppKit
import SwiftUI

// MARK: - waveform (Core Animation, NOT TimelineView)

/// Three dots that scale in a staggered loop via CABasicAnimation on a
/// CAReplicatorLayer — Core Animation runs it on the render server, so
/// main-thread CPU stays ~0%. (TimelineView here once pegged a core at 99.5%.)
struct WaveformDots: NSViewRepresentable {
    let isPlaying: Bool

    func makeNSView(context: Context) -> WaveformDotsView {
        let view = WaveformDotsView()
        view.isPlaying = isPlaying
        return view
    }

    func updateNSView(_ nsView: WaveformDotsView, context: Context) {
        nsView.isPlaying = isPlaying
    }
}

final class WaveformDotsView: NSView {
    private let replicator = CAReplicatorLayer()
    private let dot = CALayer()
    private static let dotCount = PillStyle.waveformDotCount
    private static let dotSize = PillStyle.waveformDotSize
    private static let dotSpacing = PillStyle.waveformDotSpacing
    private static let cycleDuration: CFTimeInterval = 1.2

    var isPlaying: Bool = true {
        didSet { syncAnimation() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer = CALayer()
        dot.backgroundColor = NSColor.white.cgColor
        dot.frame = CGRect(x: 0, y: 0, width: Self.dotSize, height: Self.dotSize)
        dot.cornerRadius = Self.dotSize / 2
        dot.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        replicator.instanceCount = Self.dotCount
        replicator.instanceTransform = CATransform3DMakeTranslation(Self.dotSize + Self.dotSpacing, 0, 0)
        replicator.instanceDelay = Self.cycleDuration / Double(Self.dotCount * 2)
        replicator.addSublayer(dot)
        layer?.addSublayer(replicator)
    }

    override func layout() {
        super.layout()
        let centreY = bounds.midY
        let totalWidth = CGFloat(Self.dotCount) * Self.dotSize
            + CGFloat(Self.dotCount - 1) * Self.dotSpacing
        let originX = (bounds.width - totalWidth) / 2
        replicator.frame = bounds
        dot.position = CGPoint(x: originX + Self.dotSize / 2, y: centreY)
        syncAnimation()
    }

    private func syncAnimation() {
        dot.removeAnimation(forKey: "pulse")
        guard isPlaying else {
            dot.transform = CATransform3DMakeScale(0.8, 0.8, 1)
            return
        }
        let anim = CABasicAnimation(keyPath: "transform.scale")
        anim.fromValue = 0.5
        anim.toValue = 1.15
        anim.duration = Self.cycleDuration / 2
        anim.autoreverses = true
        anim.repeatCount = .infinity
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        dot.add(anim, forKey: "pulse")
    }

    override var isFlipped: Bool { false }
}
