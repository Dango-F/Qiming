import AppKit
import QuartzCore

@MainActor protocol PanelStatusPresenting: AnyObject {
    var onShowDetails: (() -> Void)? { get set }
    func update(_ state: PanelIndicatorState, details: String)
    func setPresented(_ value: Bool)
}

enum PanelIndicatorState: CaseIterable {
    case system, running, displayOnly, alwaysOn, waiting, screenOff, warm, protected, attention

    var titleKey: String {
        switch self {
        case .system: "state.system"
        case .running: "state.active"
        case .displayOnly: "state.displayOnly"
        case .alwaysOn: "state.always"
        case .waiting: "state.waiting"
        case .screenOff: "state.screenOff"
        case .warm: "thermal.warm"
        case .protected: "indicator.protected"
        case .attention: "state.unverified"
        }
    }
    // Four visual meanings; the detailed policy remains available in the tooltip.
    var color: NSColor {
        switch self {
        case .system: .secondaryLabelColor
        case .running, .displayOnly, .alwaysOn, .screenOff: .systemGreen
        case .waiting, .warm, .protected: .systemOrange
        case .attention: .systemRed
        }
    }
    var breathes: Bool { self == .system || self == .running || self == .displayOnly || self == .alwaysOn || self == .screenOff }
}

/// The status light opens diagnostics independently of the session controls.
@MainActor final class PanelStatusIndicator: NSButton, PanelStatusPresenting {
    private let light = CAShapeLayer()
    private var visualState: PanelIndicatorState = .system
    private var renderedState: PanelIndicatorState?
    private var presented = false
    var onShowDetails: (() -> Void)?
    init() {
        super.init(frame: .zero)
        title = ""; isBordered = false; target = self; action = #selector(showDetails)
        wantsLayer = true
        light.name = "qiming.status.light"
        light.lineWidth = 0
        light.shadowRadius = 2.5; light.shadowOffset = .zero
        layer?.addSublayer(light)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 26), heightAnchor.constraint(equalToConstant: 26)
        ])
        update(.system, details: L("state.noOverrides"))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:") }
    @objc private func showDetails() { onShowDetails?() }
    func update(_ state: PanelIndicatorState, details: String) {
        let previous = visualState
        visualState = state
        toolTip = L(state.titleKey) + "\n" + details + "\n" + L("indicator.details")
        setAccessibilityLabel(L("indicator.label") + " · " + L(state.titleKey))
        setAccessibilityHelp(details + "\n" + L("indicator.details"))
        if renderedState != state {
            let needsColor = renderedState == nil || previous.color != state.color
            renderedState = state
            if previous.breathes != state.breathes || (previous == .system) != (state == .system) {
                light.removeAnimation(forKey: "qiming.breathe")
            }
            if needsColor { updateColors() }
        }
        updateAnimation()
    }
    func setPresented(_ value: Bool) { presented = value; updateAnimation() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateColors(); updateAnimation() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateColors() }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // The breathing transform is centered on the light, rather than on the button.
        light.bounds = CGRect(x: 0, y: 0, width: 11, height: 11)
        light.position = CGPoint(x: 13, y: bounds.midY)
        light.path = CGPath(ellipseIn: light.bounds.insetBy(dx: 1, dy: 1), transform: nil)
        CATransaction.commit()
    }
    private func updateColors() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            light.strokeColor = nil
            light.fillColor = visualState.color.withAlphaComponent(1).cgColor
            light.shadowColor = visualState.color.cgColor
            light.shadowOpacity = 0
        }
        CATransaction.commit()
    }
    private func updateAnimation() {
        let active = presented && window?.isVisible == true && visualState.breathes
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if active {
            guard light.animation(forKey: "qiming.breathe") == nil else { return }
            let duration = visualState == .system ? 1.6 : 1.15
            let alpha = CABasicAnimation(keyPath: "opacity")
            // Keep the solid core legible at its dimmest; let the soft halo do
            // most of the breathing, with only a small change in core size.
            alpha.fromValue = 0.40; alpha.toValue = 1
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.90; scale.toValue = 1.08
            let glow = CABasicAnimation(keyPath: "shadowOpacity")
            glow.fromValue = 0; glow.toValue = visualState == .system ? 0.45 : 0.75
            let spread = CABasicAnimation(keyPath: "shadowRadius")
            spread.fromValue = 1; spread.toValue = 4
            for animation in [alpha, scale, glow, spread] { animation.duration = duration }
            let pulse = CAAnimationGroup()
            pulse.animations = [alpha, scale, glow, spread]; pulse.duration = duration
            pulse.beginTime = light.convertTime(CACurrentMediaTime(), from: nil)
            pulse.autoreverses = true; pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            light.add(pulse, forKey: "qiming.breathe")
        } else { light.removeAnimation(forKey: "qiming.breathe") }
    }
}

/// A shared outline for status, reset, quit and settings.
@MainActor final class PanelHeaderControls: NSView {
    let indicator = PanelStatusIndicator()
    private let reset: ActionButton
    private let power: ActionButton
    init(hasSession: Bool, busy: Bool, confirming: Bool, showDetails: @escaping () -> Void,
         resetSession: @escaping () -> Void, quit: @escaping () -> Void, showSettings: @escaping () -> Void) {
        reset = Self.iconButton("arrow.counterclockwise", id: "qiming.reset", label: "stop", help: "power.stop",
                                action: resetSession)
        power = Self.iconButton("power", id: "qiming.quit", label: "quit", help: "quit.restore", action: quit)
        super.init(frame: .zero)
        wantsLayer = true; layer?.cornerRadius = 15; layer?.borderWidth = 0.5
        indicator.onShowDetails = showDetails
        reset.isEnabled = hasSession || confirming
        update(hasSession: hasSession, busy: busy, confirming: confirming)
        let settings = Self.iconButton("gearshape", id: "qiming.settings", label: "settings", help: "settings",
                                       action: showSettings)
        let row = UI.row([indicator, reset, power, settings], spacing: 2)
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            row.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        updateSurface()
    }
    func update(hasSession: Bool, busy: Bool, confirming: Bool) {
        if !busy {
            let canReset = hasSession || confirming
            if reset.isEnabled != canReset { reset.isEnabled = canReset }
            reset.setAccessibilityLabel(L(hasSession || !confirming ? "stop" : "cancel"))
            reset.toolTip = L(hasSession || !confirming ? "power.stop" : "power.cancel")
        }
        reset.blocksActions = busy
        power.blocksActions = busy
    }
    private static func iconButton(_ symbol: String, id: String, label: String, help: String,
                                   action: @escaping () -> Void) -> ActionButton {
        let button = ActionButton("", action: action)
        button.identifier = NSUserInterfaceItemIdentifier(id)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
        button.isBordered = false; button.imagePosition = .imageOnly
        button.contentTintColor = .labelColor
        button.setAccessibilityLabel(L(label)); button.toolTip = L(help)
        button.widthAnchor.constraint(equalToConstant: 26).isActive = true
        button.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return button
    }
    required init?(coder: NSCoder) { fatalError("init(coder:") }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateSurface() }
    private func updateSurface() {
        let dark = UI.isDark(effectiveAppearance)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer?.backgroundColor = NSColor.black.withAlphaComponent(dark ? 0.16 : 0.035).cgColor
        layer?.borderColor = (dark ? NSColor.white : NSColor.black)
            .withAlphaComponent(NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 0.70 : 0.16).cgColor
        CATransaction.commit()
    }
}

@MainActor final class ActionButton: NSButton {
    var actionBlock: (() -> Void)?
    var blocksActions = false
    init(_ title: String, symbol: String? = nil, action: @escaping () -> Void) {
        super.init(frame: .zero)
        self.title = title
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: title); imagePosition = .imageLeading }
        bezelStyle = .rounded
        target = self; self.action = #selector(invoke)
        actionBlock = action
        setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }
    @objc private func invoke() { if !blocksActions { actionBlock?() } }
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); updateComparisonText() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateComparisonText() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateComparisonText() }
    private func updateComparisonText() {
        guard let variant = UI.glassVariant(for: self), !title.isEmpty else { return }
        guard variant == .backupBlack || variant.usesWhiteInk else { return }
        let ink: NSColor = variant.usesWhiteInk
            ? NSColor.white.withAlphaComponent(isEnabled ? 1 : 0.48)
            : NSColor.black.withAlphaComponent(!isBordered && font?.pointSize == 11 ? 0.82 : 1)
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: ink
        ])
    }
}

/// The timing section and the full-width display sleep action.
@MainActor final class PanelFooterView: NSView {
    private let summary: NSView
    private let summaryDivider: NSBox
    init(duration: NSPopUpButton, sessionSummary: NSView, variant: GlassAppearanceVariant,
         screenOff: @escaping () -> Void) {
        summary = sessionSummary
        summaryDivider = UI.divider()
        super.init(frame: .zero)
        let section = UI.column(spacing: variant.usesCards ? 8 : 12)
        UI.pin(section, to: self)
        if !variant.usesCards {
            let separator = UI.divider()
            section.addArrangedSubview(separator); UI.fillWidth(separator, in: section)
        }

        duration.controlSize = .regular
        duration.font = .systemFont(ofSize: 13)
        duration.setContentHuggingPriority(.required, for: .horizontal)
        duration.setContentCompressionResistancePriority(.required, for: .horizontal)
        duration.heightAnchor.constraint(equalToConstant: 28).isActive = true
        let durationRow = UI.row([UI.label(L("duration"), size: 12, secondary: true), UI.spacer(), duration])
        durationRow.distribution = .fill
        durationRow.heightAnchor.constraint(equalToConstant: 32).isActive = true
        let timingRows = UI.column([sessionSummary, summaryDivider, durationRow], spacing: 0)
        for row in timingRows.arrangedSubviews { UI.fillWidth(row, in: timingRows) }
        let durationModule = variant.usesCards
            ? UI.glassCard(timingRows, horizontal: 10, vertical: 4) : timingRows
        section.addArrangedSubview(durationModule); UI.fillWidth(durationModule, in: section)

        let off = ActionButton(L("screen.off"), symbol: "display", action: screenOff)
        off.identifier = NSUserInterfaceItemIdentifier("qiming.screenOff")
        off.controlSize = .regular
        off.font = .systemFont(ofSize: 13, weight: .medium)
        off.image = off.image?.withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        off.alignment = .center; off.imageHugsTitle = true
        off.heightAnchor.constraint(equalToConstant: 32).isActive = true
        if variant.usesCards { off.isBordered = false }
        let action = variant.usesCards ? UI.glassCard(off, horizontal: 0, vertical: 0, radius: 14) : off
        section.addArrangedSubview(action); UI.fillWidth(action, in: section)
    }
    func showSummary(_ visible: Bool) {
        if summary.isHidden == visible { summary.isHidden = !visible }
        if summaryDivider.isHidden == visible { summaryDivider.isHidden = !visible }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:") }
}

@MainActor final class PanelDurationPopup: NSPopUpButton {
    var blocksInteraction = false
    override func mouseDown(with event: NSEvent) {
        if !blocksInteraction { super.mouseDown(with: event) }
    }
    override func keyDown(with event: NSEvent) {
        if !blocksInteraction { super.keyDown(with: event) }
    }
    override func performClick(_ sender: Any?) {
        if !blocksInteraction { super.performClick(sender) }
    }
    override func accessibilityPerformPress() -> Bool {
        !blocksInteraction && super.accessibilityPerformPress()
    }
    func showSelection(at index: Int, customSeconds: TimeInterval) {
        if index == 4 {
            selectItem(at: index)
            showCustomDuration(seconds: customSeconds)
        } else {
            if let popupCell = cell as? NSPopUpButtonCell { popupCell.usesItemFromMenu = true }
            selectItem(at: index)
            setAccessibilityValue(title)
            updateComparisonText()
            invalidateIntrinsicContentSize()
        }
    }
    static func customTitle(seconds: TimeInterval) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Localization.locale
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 2
        let minutes = formatter.string(from: NSNumber(value: seconds / 60)) ?? "\(seconds / 60)"
        return minutes + " " + L("duration.minutes")
    }
    func showCustomDuration(seconds: TimeInterval) {
        guard let popupCell = cell as? NSPopUpButtonCell else { return }
        // A separate display item keeps the selected menu command named Custom Duration.
        popupCell.usesItemFromMenu = false
        popupCell.menuItem = NSMenuItem(title: Self.customTitle(seconds: seconds), action: nil, keyEquivalent: "")
        setAccessibilityValue(Self.customTitle(seconds: seconds))
        updateComparisonText()
        invalidateIntrinsicContentSize()
    }
    override var intrinsicContentSize: NSSize {
        let ink = (title as NSString).size(withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 13)]).width
        return NSSize(width: max(80, ceil(ink) + 36), height: super.intrinsicContentSize.height)
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateComparisonText() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateComparisonText() }
    private func updateComparisonText() {
        guard UI.glassVariant(for: self) == .backupBlack else { return }
        let ink = NSAttributedString(string: title, attributes: [
            .font: font ?? NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.black
        ])
        if let selectedItem {
            selectedItem.attributedTitle = NSAttributedString(string: selectedItem.title, attributes: [
                .font: font ?? NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.black
            ])
        }
        // NSPopUpButton draws its display menu item directly. Style that item,
        // rather than only NSButton's title, so menu tracking preserves black ink.
        if let popupCell = cell as? NSPopUpButtonCell { popupCell.menuItem?.attributedTitle = ink }
        attributedTitle = ink
    }
}

/// A visible unit survives both the default value and any subsequent editing.
@MainActor final class PanelCustomDurationInput: NSView {
    let field = NSTextField(string: "120")
    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 230, height: 28))
        field.placeholderString = L("duration.minutes")
        field.setAccessibilityLabel(L("duration") + " · " + L("duration.minutes"))
        field.toolTip = L("duration.minutes")
        let unit = UI.label(L("duration.minutes"), size: 12, secondary: true)
        unit.maximumNumberOfLines = 1
        unit.setContentHuggingPriority(.required, for: .horizontal)
        for item in [field, unit] { item.translatesAutoresizingMaskIntoConstraints = false; addSubview(item) }
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor),
            field.trailingAnchor.constraint(equalTo: unit.leadingAnchor, constant: -8),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.heightAnchor.constraint(equalToConstant: 26),
            unit.trailingAnchor.constraint(equalTo: trailingAnchor),
            unit.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:") }
}

@MainActor enum UI {
    static func glassVariant(for view: NSView) -> GlassAppearanceVariant? {
        var ancestor = view.superview
        while let current = ancestor {
            if let glass = current as? GlassSurfaceView { return glass.variant }
            ancestor = current.superview
        }
        return nil
    }
    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
    static let panelSecondary = NSColor(name: "QimingPanelSecondary") { appearance in
        NSColor(white: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? 0.88 : 0.18, alpha: 1)
    }
    static let panelPrimary = NSColor(name: "QimingPanelPrimary") { appearance in
        NSColor(white: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? 0.97 : 0.06, alpha: 1)
    }
    static func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular,
                      secondary: Bool = false, width: CGFloat? = nil) -> NSTextField {
        let label = ReadableLabel(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.secondary = secondary
        label.maximumNumberOfLines = 0
        label.isSelectable = false
        if let width { label.preferredMaxLayoutWidth = width }
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        return label
    }
    static func column(_ views: [NSView] = [], spacing: CGFloat = 12) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = spacing
        return stack
    }
    static func row(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal; stack.alignment = .centerY; stack.spacing = spacing
        return stack
    }
    static func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.init(1), for: .horizontal)
        return view
    }
    static func pin(_ child: NSView, to parent: NSView, inset: CGFloat = 0) {
        child.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset),
            child.topAnchor.constraint(equalTo: parent.topAnchor, constant: inset),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset)
        ])
    }
    static func styleGlassCard(_ view: NSView, radius: CGFloat = 16) {
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        layer.cornerRadius = radius
        layer.cornerCurve = .continuous
        if #available(macOS 26.0, *), !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            let lens = GlassCardLens()
            lens.style = .clear
            lens.cornerRadius = radius
            // Keep the system's clear optics. A recessed reading surface
            // leaves the rounded refracting edge exposed.
            let interior = NSView()
            let tint = NSView()
            tint.wantsLayer = true
            tint.layer?.cornerRadius = radius - 1
            tint.layer?.cornerCurve = .continuous
            tint.layer?.backgroundColor = NSColor(srgbRed: 0.32, green: 0.32, blue: 0.32, alpha: 0.34).cgColor
            UI.pin(tint, to: interior, inset: 1)
            lens.contentView = interior
            UI.pin(lens, to: view)
            layer.borderWidth = 0.5
            layer.borderColor = NSColor.white.withAlphaComponent(0.36).cgColor
            return
        }
        layer.borderWidth = 0.5
        layer.borderColor = NSColor.white.withAlphaComponent(0.48).cgColor
        layer.backgroundColor = NSColor(srgbRed: 0.32, green: 0.32, blue: 0.32, alpha: 0.31).cgColor
        let highlight = CAGradientLayer()
        highlight.frame = layer.bounds
        highlight.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        highlight.cornerRadius = radius
        highlight.cornerCurve = .continuous
        highlight.colors = [NSColor.white.withAlphaComponent(0.05).cgColor,
                            NSColor.white.withAlphaComponent(0).cgColor]
        layer.insertSublayer(highlight, at: 0)
    }
    static func glassCard(_ content: NSView, horizontal: CGFloat = 10, vertical: CGFloat = 8,
                          radius: CGFloat = 16) -> NSView {
        let card = NSView()
        styleGlassCard(card, radius: radius)
        content.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: horizontal),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -horizontal),
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: vertical),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -vertical)
        ])
        return card
    }
    static func divider() -> NSBox { let box = NSBox(); box.boxType = .separator; return box }
    static func fillWidth(_ view: NSView, in stack: NSStackView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
    static func brandImage(mode: DisplayMode, size: CGFloat, badge: IconBadge = .none) -> NSImage {
        let extra: CGFloat = badge == .none ? 0 : 8
        let image = NSImage(size: NSSize(width: size + extra, height: size), flipped: false) { _ in
            NSColor.labelColor.setStroke(); NSColor.labelColor.setFill()
            let wings = WingGeometry.paths(size: size)
            if mode.keepsSystemAwake { wings.outer.fill() }
            if mode == .always || mode == .displayOnly { wings.inner.fill() }
            wings.outer.stroke(); wings.inner.stroke()
            if badge != .none {
                let mark = NSBezierPath(); mark.lineWidth = 1.2; mark.lineCapStyle = .round
                if badge == .paused {
                    for x in [size + 2, size + 5] {
                        mark.move(to: NSPoint(x: x, y: size * 0.38))
                        mark.line(to: NSPoint(x: x, y: size * 0.64))
                    }
                } else {
                    mark.move(to: NSPoint(x: size + 3.5, y: size * 0.42))
                    mark.line(to: NSPoint(x: size + 3.5, y: size * 0.68))
                    NSBezierPath(ovalIn: NSRect(x: size + 2.8, y: size * 0.26, width: 1.4, height: 1.4)).fill()
                }
                mark.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

@available(macOS 26.0, *)
@MainActor private final class GlassCardLens: NSGlassEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Semantic foregrounds follow the app appearance. The content backing supplies contrast;
/// labels themselves remain flat and sharp instead of relying on a halo or drop shadow.
@MainActor private final class ReadableLabel: NSTextField {
    private static let whiteInkShadow: NSShadow = {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.48)
        shadow.shadowBlurRadius = 1
        shadow.shadowOffset = NSSize(width: 0, height: -0.5)
        return shadow
    }()

    var secondary = false { didSet { updateTextColor() } }
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); updateTextColor() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateTextColor() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateTextColor() }
    private func updateTextColor() {
        let variant = UI.glassVariant(for: self)
        shadow = variant?.usesWhiteInk == true ? Self.whiteInkShadow : nil
        if variant == .backupBlack {
            textColor = NSColor.black.withAlphaComponent(secondary ? 0.92 : 1)
        } else if variant?.usesWhiteInk == true {
            textColor = NSColor.white.withAlphaComponent(secondary ? 0.94 : 1)
        } else if variant == .optimized {
            textColor = secondary ? UI.panelSecondary : UI.panelPrimary
        } else {
            textColor = secondary ? .secondaryLabelColor : .labelColor
        }
        needsDisplay = true
    }
}

/// Newer macOS keeps NSSwitch's intrinsic size unchanged for all controlSize
/// values. Scale its native coordinate space uniformly, retaining a 28pt hit slot.
@MainActor private final class CompactSwitchSlot: NSView {
    private let control: NSSwitch
    private let nativeSize: NSSize
    private var compactWidth: CGFloat { min(42, nativeSize.width) }
    override var intrinsicContentSize: NSSize { NSSize(width: compactWidth, height: 28) }
    init(control: NSSwitch) {
        self.control = control; nativeSize = control.intrinsicContentSize
        super.init(frame: .zero)
        addSubview(control)
    }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard newSize.width > 0 else { return }
        let scale = newSize.width / nativeSize.width
        bounds = NSRect(x: 0, y: 0, width: nativeSize.width, height: newSize.height / scale)
        control.frame = NSRect(x: 0, y: (bounds.height - nativeSize.height) / 2,
                               width: nativeSize.width, height: nativeSize.height)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:") }
}

@MainActor final class ModeRow: NSView {
    let mode: DisplayMode
    let selector: NSSwitch
    private let selectorSlot: CompactSwitchSlot
    private var selected: Bool
    private(set) var acceptsSelection = true
    private let inGlassGroup: Bool
    private let activate: (DisplayMode) -> Void
    init(mode: DisplayMode, selected: Bool, enabled: Bool, inGlassGroup: Bool = false,
         action: @escaping (DisplayMode) -> Void) {
        self.mode = mode
        // Scale the regular bezel itself; the small style adds invisible side
        // padding inside the unchanged intrinsic frame, spoiling visual alignment.
        let nativeSwitch = NSSwitch(); nativeSwitch.controlSize = .regular
        selector = nativeSwitch
        selectorSlot = CompactSwitchSlot(control: nativeSwitch)
        self.selected = selected
        self.inGlassGroup = inGlassGroup
        activate = action
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        // Let AppKit supply the native sliding thumb and Liquid Glass styling.
        // These remain exclusive policies, rather than three independent flags.
        update(selected: selected, enabled: enabled)
        selector.target = self; selector.action = #selector(switchChanged)
        selector.identifier = NSUserInterfaceItemIdentifier("qiming.mode." + mode.rawValue)
        selector.setAccessibilityLabel(L(mode.titleKey))
        selector.setAccessibilityHelp(L(mode.detailKey) + "\n" + L("mode.switch.help"))
        selector.toolTip = L("mode.switch.help")
        selector.setContentHuggingPriority(.required, for: .horizontal)
        selector.setContentCompressionResistancePriority(.required, for: .horizontal)
        let title = UI.label(L(mode.titleKey), weight: .medium)
        // Native switch widths vary with macOS. Match wrapping to its actual
        // intrinsic width within the 312pt content column, rather than clipping
        // a description laid out for the old, narrower radio button.
        let trailingInset: CGFloat = inGlassGroup ? 10 : 0
        let textWidth = 312 - 12 - 12 - trailingInset - selectorSlot.intrinsicContentSize.width
        let detail = UI.label(L(mode.detailKey), size: 12, secondary: true, width: textWidth)
        let text = UI.column([title, detail], spacing: 4)
        text.translatesAutoresizingMaskIntoConstraints = false
        selectorSlot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(text); addSubview(selectorSlot)
        NSLayoutConstraint.activate([
            selectorSlot.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -trailingInset),
            selectorSlot.centerYAnchor.constraint(equalTo: centerYAnchor),
            selectorSlot.widthAnchor.constraint(equalToConstant: selectorSlot.intrinsicContentSize.width),
            selectorSlot.heightAnchor.constraint(equalToConstant: 28),
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            text.trailingAnchor.constraint(equalTo: selectorSlot.leadingAnchor, constant: -12),
            text.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            text.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            detail.widthAnchor.constraint(equalTo: text.widthAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 62)
        ])
    }
    func update(selected: Bool, enabled: Bool) {
        self.selected = selected
        if selector.state != (selected ? NSControl.StateValue.on : .off) {
            selector.state = selected ? .on : .off
        }
        acceptsSelection = enabled && !(mode == .system && selected)
        let selectable = !(mode == .system && selected)
        if selector.isEnabled != selectable { selector.isEnabled = selectable }
        layer?.backgroundColor = selected && !inGlassGroup
            ? NSColor.controlAccentColor.withAlphaComponent(0.10).cgColor : nil
    }
    @objc private func switchChanged() {
        // The native control moves immediately on click. Restore the confirmed
        // value until the helper succeeds or the required risk card is accepted.
        selector.state = selected ? .on : .off
        guard acceptsSelection else { return }
        activate(selected ? .system : mode)
    }
    override func mouseDown(with event: NSEvent) { if acceptsSelection { activate(mode) } }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }
}
