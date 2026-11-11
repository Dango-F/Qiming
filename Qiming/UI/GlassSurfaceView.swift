import AppKit
import CoreImage.CIFilterBuiltins
import QuartzCore

enum GlassConfiguration {
    static let defaultTransparency = 0.75

    /// Changes actual background focus, without crossfading a sharp duplicate underneath.
    static func defocusRadius(for transparency: Double) -> Double {
        let value = transparency.isFinite ? min(1, max(0, transparency)) : defaultTransparency
        return 24 * pow(1 - value, 1.2)
    }
}

enum GlassAppearanceVariant: String, CaseIterable {
    case grayCards, grayUniform, backupBlack, optimized

    var titleKey: String { "glass.variant." + rawValue }
    var usesGrayBacking: Bool { self == .grayUniform || self == .grayCards }
    var usesCards: Bool { self == .grayCards }
    static var current: Self {
        Self(rawValue: UserDefaults.standard.string(forKey: "glassAppearanceVariant") ?? "") ?? .grayCards
    }
}

enum GlassFontColor: String, CaseIterable {
    case black, white

    var titleKey: String { "glass.fontColor." + rawValue }
    var ink: NSColor { self == .black ? .black : .white }
}

@MainActor protocol GlassTextStyling: AnyObject {
    func updateTextColor()
}

/// Shared host for the appearance variants. Switching replaces the optical surface,
/// keeping the same foreground, transparency value and production power model.
@MainActor final class GlassSurfaceView: NSView {
    private let content: NSView
    private let corner: CGFloat
    private let blending: NSVisualEffectView.BlendingMode
    private var surface: NSView?
    var variant = GlassAppearanceVariant.current {
        didSet { if variant != oldValue { rebuild() } }
    }
    var fontColor: GlassFontColor = .white {
        didSet {
            guard fontColor != oldValue else { return }
            func refreshText(in view: NSView) {
                (view as? GlassTextStyling)?.updateTextColor()
                view.subviews.forEach(refreshText)
            }
            refreshText(in: content)
        }
    }
    var transparency = GlassConfiguration.defaultTransparency {
        didSet { updateTransparency() }
    }
    init(content: NSView, cornerRadius: CGFloat = 28,
         backgroundBlendingMode: NSVisualEffectView.BlendingMode = .behindWindow) {
        self.content = content; corner = cornerRadius; blending = backgroundBlendingMode
        super.init(frame: .zero)
        rebuild()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:") }
    override var isOpaque: Bool { false }
    private func rebuild() {
        content.removeFromSuperview()
        surface?.removeFromSuperview()
        let next: NSView = variant == .optimized
            ? OptimizedGlassSurfaceView(content: content, cornerRadius: corner, backgroundBlendingMode: blending)
            : BackupGlassSurfaceView(content: content, cornerRadius: corner, backgroundBlendingMode: blending, variant: variant)
        surface = next
        UI.pin(next, to: self)
        updateTransparency()
    }
    private func updateTransparency() {
        (surface as? BackupGlassSurfaceView)?.transparency = transparency
        (surface as? OptimizedGlassSurfaceView)?.transparency = transparency
    }
}

/// The filter samples a larger sibling backdrop; its output alone is rounded and clipped.
/// Keeping this in the lens's backing group is necessary for cross-window sampling.
@MainActor final class GlassBackdropFocusView: NSView {
    var samplingView: NSView { self }
    private let edgeMask = CAShapeLayer()
    private let radius: CGFloat
    static let samplingPadding: CGFloat = 26
    init(cornerRadius: CGFloat) {
        radius = cornerRadius
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("qiming.glass.focus.sample")
        wantsLayer = true
        layer?.masksToBounds = true
        edgeMask.fillColor = NSColor.white.cgColor
        layer?.mask = edgeMask
    }
    required init?(coder: NSCoder) { fatalError("init(coder:") }
    override var isOpaque: Bool { false }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); needsLayout = true }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); needsLayout = true }
    override func layout() {
        super.layout()
        let edge = 1 / (window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2)
        let visible = bounds.insetBy(dx: Self.samplingPadding + edge, dy: Self.samplingPadding + edge)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        edgeMask.frame = bounds
        edgeMask.path = visible.isEmpty ? nil : CGPath(roundedRect: visible,
            cornerWidth: max(0, radius - edge), cornerHeight: max(0, radius - edge), transform: nil)
        CATransaction.commit()
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// One native Clear lens, followed by a background-only Core Image focus pass.
/// Text and controls are later siblings and never enter the background filter chain.
@MainActor private final class BackupGlassSurfaceView: NSView {
    private let variant: GlassAppearanceVariant
    private let material: NSView
    private let diffusion: GlassBackdropFocusView
    private let readability = NSView()
    private let color = CIFilter.colorControls()
    private weak var focusSurface: NSView?
    private let usesNativeGlass: Bool
    private let radius: CGFloat
    private var ready = false
    private var lastFocusKey = -1
    var transparency = GlassConfiguration.defaultTransparency {
        didSet { if transparency != oldValue { updateMaterial() } }
    }

    init(content: NSView, cornerRadius: CGFloat = 28,
         backgroundBlendingMode: NSVisualEffectView.BlendingMode = .behindWindow,
         variant: GlassAppearanceVariant) {
        self.variant = variant
        radius = cornerRadius
        diffusion = GlassBackdropFocusView(cornerRadius: cornerRadius)
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .clear
            glass.cornerRadius = cornerRadius
            glass.tintColor = nil
            // These views contain the optical background only. Foreground is placed once,
            // above the focus pass, so it cannot be softened along with the background.
            glass.contentView = NSView()
            material = glass
            usesNativeGlass = true
        } else {
            let fallback = NSVisualEffectView()
            fallback.material = .hudWindow
            fallback.blendingMode = backgroundBlendingMode
            fallback.state = .active
            material = fallback
            usesNativeGlass = false
        }
        super.init(frame: .zero)
        // The background filter needs the same backing hierarchy as the lens and foreground.
        // In particular, an independently promoted NSScrollView can bypass an empty sibling.
        wantsLayer = true
        appearance = NSAppearance(named: .darkAqua)
        UI.pin(material, to: self)
        UI.pin(diffusion, to: self, inset: -GlassBackdropFocusView.samplingPadding)
        focusSurface = diffusion.samplingView
        color.saturation = 1.14
        color.contrast = 1.06
        color.brightness = -0.025
        readability.wantsLayer = true
        readability.layer?.cornerRadius = cornerRadius
        UI.pin(readability, to: self)
        UI.pin(content, to: self)
        ready = true
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(accessibilityChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        updateMaterial()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:") }
    override var isOpaque: Bool { false }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if ready { updateMaterial() }
    }
    @objc private func accessibilityChanged() { updateMaterial() }
    private func updateMaterial() {
        guard ready else { return }
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let increasedContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let desiredAppearance: NSAppearance.Name = increasedContrast ? .accessibilityHighContrastDarkAqua : .darkAqua
        if appearance?.name != desiredAppearance { appearance = NSAppearance(named: desiredAppearance) }
        material.isHidden = reduceTransparency
        diffusion.isHidden = reduceTransparency || !usesNativeGlass
        let key = Int((GlassConfiguration.defocusRadius(for: transparency) * 20).rounded())
        if reduceTransparency || !usesNativeGlass {
            focusSurface?.backgroundFilters = []
            lastFocusKey = -1
        } else if key != lastFocusKey {
            lastFocusKey = key
            // Core Animation may retain/copy the submitted chain. Mutating the same CIFilter
            // and assigning an equal array can leave the old render result cached. Submit a
            // fresh filter instance for every new radius instead of relying on input mutation.
            let focus = CIFilter.discBlur()
            focus.radius = Float(key) / 20
            // Public NSView backgroundFilters, not contentFilters: only the already-rendered
            // backdrop is processed. No images are captured, replaced or read back from GPU.
            focusSurface?.backgroundFilters = key == 0 ? [color] : [focus, color]
        }
        // Constant contrast treatment; the slider controls focus radius only.
        if variant.usesGrayBacking {
            // Cards supply their own gray backing. Keep the shared surface
            // nearly clear so the two layers do not hide the backdrop.
            let opacity = reduceTransparency ? 1 : increasedContrast ? 0.96 : variant.usesCards ? 0.10 : 0.39
            let gray: CGFloat = reduceTransparency || increasedContrast ? 0.23 : 0.32
            readability.layer?.backgroundColor = NSColor(srgbRed: gray, green: gray, blue: gray, alpha: opacity).cgColor
        } else {
            let opacity = reduceTransparency ? 1.0 : increasedContrast ? 0.82 : 0.08
            readability.layer?.backgroundColor = NSColor(white: 0, alpha: opacity).cgColor
        }
        if let fallback = material as? NSVisualEffectView {
            let value = transparency.isFinite ? min(1, max(0, transparency)) : GlassConfiguration.defaultTransparency
            let coverage = 1 - value * value * value
            fallback.isHidden = reduceTransparency || coverage < 0.0001
            let size = NSSize(width: radius * 2 + 1, height: radius * 2 + 1)
            let corner = radius
            let mask = NSImage(size: size, flipped: false) { rect in
                NSColor.white.withAlphaComponent(coverage).setFill()
                NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner).fill()
                return true
            }
            mask.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
            mask.resizingMode = .stretch
            fallback.maskImage = mask
        }
    }
}

/// One native Clear lens, followed by a background-only Core Image focus pass.
/// Text and controls are later siblings and never enter the background filter chain.
@MainActor private final class OptimizedGlassSurfaceView: NSView {
    private let material: NSView
    private let diffusion: GlassBackdropFocusView
    private let readability = NSView()
    private let contentBacking = ContentReadabilityView()
    private let color = CIFilter.colorControls()
    private weak var focusSurface: NSView?
    private weak var foreground: NSView?
    private let usesNativeGlass: Bool
    private let radius: CGFloat
    private var ready = false
    private var lastFocusKey = -1
    var transparency = GlassConfiguration.defaultTransparency {
        didSet { if transparency != oldValue { updateMaterial() } }
    }

    init(content: NSView, cornerRadius: CGFloat = 28,
         backgroundBlendingMode: NSVisualEffectView.BlendingMode = .behindWindow) {
        radius = cornerRadius
        diffusion = GlassBackdropFocusView(cornerRadius: cornerRadius)
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .clear
            glass.cornerRadius = cornerRadius
            glass.tintColor = nil
            // These views contain the optical background only. Foreground is placed once,
            // above the focus pass, so it cannot be softened along with the background.
            glass.contentView = NSView()
            material = glass
            usesNativeGlass = true
        } else {
            let fallback = NSVisualEffectView()
            fallback.material = .hudWindow
            fallback.blendingMode = backgroundBlendingMode
            fallback.state = .active
            material = fallback
            usesNativeGlass = false
        }
        super.init(frame: .zero)
        // The background filter needs the same backing hierarchy as the lens and foreground.
        // In particular, an independently promoted NSScrollView can bypass an empty sibling.
        wantsLayer = true
        // Keep the approved clear lens treatment local to the optical layer. Foreground
        // inherits the system/app appearance, so native controls and text agree in both modes.
        material.appearance = NSAppearance(named: .darkAqua)
        UI.pin(material, to: self)
        UI.pin(diffusion, to: self, inset: -GlassBackdropFocusView.samplingPadding)
        focusSurface = diffusion.samplingView
        color.saturation = 1.14
        color.contrast = 1.06
        color.brightness = -0.025
        readability.wantsLayer = true
        readability.layer?.cornerRadius = cornerRadius
        UI.pin(readability, to: self)
        UI.pin(contentBacking, to: self, inset: 6)
        UI.pin(content, to: self)
        foreground = content
        if let scroll = content as? NSScrollView {
            scroll.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(foregroundMoved),
                name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        }
        ready = true
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(accessibilityChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        updateMaterial()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:") }
    override var isOpaque: Bool { false }
    override func layout() {
        super.layout()
        foreground?.layoutSubtreeIfNeeded()
        if let foreground { contentBacking.updateReadingMask(in: foreground) }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if ready { updateMaterial() }
    }
    @objc private func accessibilityChanged() { updateMaterial() }
    @objc private func foregroundMoved() {
        if let foreground { contentBacking.updateReadingMask(in: foreground) }
    }
    private func updateMaterial() {
        guard ready else { return }
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let increasedContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let desiredAppearance: NSAppearance.Name = increasedContrast ? .accessibilityHighContrastDarkAqua : .darkAqua
        if material.appearance?.name != desiredAppearance { material.appearance = NSAppearance(named: desiredAppearance) }
        material.isHidden = reduceTransparency
        diffusion.isHidden = reduceTransparency || !usesNativeGlass
        let key = Int((GlassConfiguration.defocusRadius(for: transparency) * 20).rounded())
        if reduceTransparency || !usesNativeGlass {
            focusSurface?.backgroundFilters = []
            lastFocusKey = -1
        } else if key != lastFocusKey {
            lastFocusKey = key
            // Core Animation may retain/copy the submitted chain. Mutating the same CIFilter
            // and assigning an equal array can leave the old render result cached. Submit a
            // fresh filter instance for every new radius instead of relying on input mutation.
            let focus = CIFilter.discBlur()
            focus.radius = Float(key) / 20
            // Public NSView backgroundFilters, not contentFilters: only the already-rendered
            // backdrop is processed. No images are captured, replaced or read back from GPU.
            focusSurface?.backgroundFilters = key == 0 ? [color] : [focus, color]
        }
        // Constant contrast treatment; the slider controls focus radius only.
        let dark = UI.isDark(effectiveAppearance)
        let opacity = reduceTransparency ? 1.0 : increasedContrast ? 0.94 : dark ? 0.32 : 0.08
        let base = reduceTransparency || increasedContrast ? NSColor(white: dark ? 0.10 : 0.98, alpha: opacity) : NSColor.black.withAlphaComponent(opacity)
        readability.layer?.backgroundColor = base.cgColor
        contentBacking.isHidden = reduceTransparency || increasedContrast
        contentBacking.updateSurface()
        if let fallback = material as? NSVisualEffectView {
            let value = transparency.isFinite ? min(1, max(0, transparency)) : GlassConfiguration.defaultTransparency
            let coverage = 1 - value * value * value
            fallback.isHidden = reduceTransparency || coverage < 0.0001
            let size = NSSize(width: radius * 2 + 1, height: radius * 2 + 1)
            let corner = radius
            let mask = NSImage(size: size, flipped: false) { rect in
                NSColor.white.withAlphaComponent(coverage).setFill()
                NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner).fill()
                return true
            }
            mask.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
            mask.resizingMode = .stretch
            fallback.maskImage = mask
        }
    }
}

/// Soft, local contrast support follows the actual label/control frames. Empty regions
/// and the glass perimeter remain clear; this does not change the optical filter chain.
@MainActor private final class ContentReadabilityView: NSView {
    private let readingMask = CAShapeLayer()
    private var previousRects: [NSRect] = []
    private var previousSize = NSSize.zero
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        readingMask.fillColor = NSColor.white.cgColor
        let feather = CIFilter.gaussianBlur()
        feather.radius = 10
        // This softens only the contrast mask's edges, never the foreground or backdrop.
        readingMask.filters = [feather]
        layer?.mask = readingMask
        updateSurface()
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:") }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateSurface() }
    func updateSurface() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer?.backgroundColor = UI.isDark(effectiveAppearance)
            ? NSColor(white: 0.035, alpha: 0.30).cgColor
            : NSColor(white: 1, alpha: 0.34).cgColor
        CATransaction.commit()
    }
    func updateReadingMask(in content: NSView) {
        var rects: [NSRect] = []
        func collect(_ view: NSView) {
            guard !view.isHidden else { return }
            if view is NSTextField || view is NSButton {
                let rect = convert(view.bounds, from: view).insetBy(dx: -3, dy: -2)
                if rect.width > 1 && rect.height > 1 { rects.append(rect) }
                return
            }
            view.subviews.forEach(collect)
        }
        collect(content)
        guard rects != previousRects || bounds.size != previousSize else { return }
        previousRects = rects; previousSize = bounds.size
        let path = CGMutablePath()
        for rect in rects { path.addRoundedRect(in: rect, cornerWidth: 5, cornerHeight: 5) }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        readingMask.frame = bounds
        readingMask.path = path
        CATransaction.commit()
    }
}

/// A static, inexpensive color backdrop makes the material setting visible without a photo asset.
@MainActor final class GlassPreviewView: NSView {
    private let sample: GlassSurfaceView
    private let plain: NSView
    private let cards: NSView

    init() {
        func previewRow(symbol: String, title: String, detail: String? = nil) -> NSView {
            let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!)
            icon.widthAnchor.constraint(equalToConstant: 20).isActive = true
            let text = UI.column([UI.label(title, size: 15, weight: .semibold)], spacing: 3)
            if let detail { text.addArrangedSubview(UI.label(detail, size: 11, secondary: true)) }
            let row = UI.row([icon, text, UI.spacer()], spacing: 10)
            row.distribution = .fill
            return row
        }
        plain = previewRow(symbol: "sparkles", title: ServiceIdentity.displayName, detail: L("glass.preview.subtitle"))
        let policies = UI.column(spacing: 4)
        for (index, mode) in DisplayMode.allCases.enumerated() {
            if index > 0 {
                let divider = UI.divider()
                policies.addArrangedSubview(divider); UI.fillWidth(divider, in: policies)
            }
            let row = previewRow(symbol: index == 0 ? "checkmark.circle.fill" : "circle",
                                 title: L(mode.titleKey))
            policies.addArrangedSubview(row); UI.fillWidth(row, in: policies)
        }
        cards = UI.glassCard(policies, horizontal: 12, vertical: 8)
        let content = NSView()
        UI.pin(plain, to: content, inset: 14)
        UI.pin(cards, to: content, inset: 14)
        sample = GlassSurfaceView(content: content, cornerRadius: 22, backgroundBlendingMode: .withinWindow)
        plain.isHidden = sample.variant.usesCards
        cards.isHidden = !sample.variant.usesCards
        super.init(frame: .zero)
        wantsLayer = true; layer?.cornerRadius = 14; layer?.masksToBounds = true
        // Keep detail on an independent sibling backdrop, just like content behind the panel.
        UI.pin(GlassPreviewBackdrop(), to: self)
        sample.translatesAutoresizingMaskIntoConstraints = false
        addSubview(sample)
        NSLayoutConstraint.activate([
            sample.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            sample.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            sample.centerYAnchor.constraint(equalTo: centerYAnchor),
            // Compact glass receives different system optical treatment. A larger sample
            // demonstrates the actual diffusion of the panel instead of mostly edge refraction.
            sample.heightAnchor.constraint(equalToConstant: 152),
            heightAnchor.constraint(equalToConstant: 188)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }
    var variant: GlassAppearanceVariant {
        get { sample.variant }
        set {
            plain.isHidden = newValue.usesCards
            cards.isHidden = !newValue.usesCards
            sample.variant = newValue
        }
    }
    var transparency: Double {
        get { sample.transparency }
        set { sample.transparency = newValue }
    }
    var fontColor: GlassFontColor {
        get { sample.fontColor }
        set { sample.fontColor = newValue }
    }
}

@MainActor private final class GlassPreviewBackdrop: NSImageView {
    init() {
        let size = NSSize(width: 524, height: 188)
        let image = NSImage(size: size, flipped: false) { _ in
            let bounds = NSRect(origin: .zero, size: size)
            let gradient = NSGradient(colors: [
                NSColor(srgbRed: 0.20, green: 0.46, blue: 0.68, alpha: 1),
                NSColor(srgbRed: 0.48, green: 0.70, blue: 0.75, alpha: 1),
                NSColor(srgbRed: 0.85, green: 0.72, blue: 0.48, alpha: 1)
            ])!
            gradient.draw(in: bounds, angle: 18)
            // Fine detail makes diffusion visible. All shapes remain app-native and static;
            // no reference screenshot, photo asset or custom blur renderer is shipped.
            for (index, x) in [0.16, 0.44, 0.72].enumerated() {
                let origin = bounds.width * x
                NSColor(srgbRed: 0.23, green: 0.70, blue: 0.92, alpha: 1).setFill()
                NSBezierPath(roundedRect: NSRect(x: origin, y: 70, width: 48, height: 42),
                             xRadius: 6, yRadius: 6).fill()
                NSBezierPath(roundedRect: NSRect(x: origin + 3, y: 107, width: 20, height: 10),
                             xRadius: 3, yRadius: 3).fill()
                let label = ["Work", "Notes", "Qiming"][index]
                label.draw(at: NSPoint(x: origin, y: 55), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: NSColor.white
                ])
            }
            NSColor(srgbRed: 0.74, green: 0.38, blue: 0.22, alpha: 0.8).setStroke()
            for index in 0..<12 {
                let line = NSBezierPath(); line.lineWidth = 1
                let x = CGFloat(index) * 17 + bounds.width * 0.42
                line.move(to: NSPoint(x: x, y: 0)); line.line(to: NSPoint(x: x + 28, y: bounds.height))
                line.stroke()
            }
            return true
        }
        super.init(frame: .zero)
        self.image = image
        imageScaling = .scaleAxesIndependently
        for axis in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            setContentHuggingPriority(.init(1), for: axis)
            setContentCompressionResistancePriority(.init(1), for: axis)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }
}
