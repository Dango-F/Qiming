import AppKit
import QuartzCore

@MainActor final class PanelController: NSViewController {
    private let model: AppModel
    private let backgroundBlendingMode: NSVisualEffectView.BlendingMode
    var showSettings: (() -> Void)?
    var showStatus: (() -> Void)?
    var quit: (() -> Void)?
    private var observation: UUID?
    private var timer: Timer?
    private var presented = false
    private var pending: DisplayMode?
    private var confirmingRisk = false
    private var signature = ""
    private var baseSignature = ""
    private var contentStack: NSStackView?
    private var headerControls: PanelHeaderControls?
    private var brandView: NSImageView?
    private var brandMode: DisplayMode?
    private var modeRows: [ModeRow] = []
    private var countdown = UI.label("", size: 17, weight: .medium)
    private var statusIndicator: (NSButton & PanelStatusPresenting)?
    private var confirmedIndicatorState: PanelIndicatorState?
    private var popup: PanelDurationPopup?
    private var footer: PanelFooterView?
    private var extendButton: ActionButton?
    private var messageModule: NSView?
    private var durationSignature = ""
    private let document = PanelDocumentView()
    private var glass: GlassSurfaceView!

    init(model: AppModel, backgroundBlendingMode: NSVisualEffectView.BlendingMode = .behindWindow) {
        self.model = model; self.backgroundBlendingMode = backgroundBlendingMode
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }
    override func loadView() {
        let scroll = NSScrollView()
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.documentView = document
        document.translatesAutoresizingMaskIntoConstraints = false
        document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        glass = GlassSurfaceView(content: scroll, backgroundBlendingMode: backgroundBlendingMode)
        glass.frame = NSRect(x: 0, y: 0, width: 352, height: 490)
        view = glass
        observation = model.observe { [weak self] in
            guard let self, self.view.window?.isVisible == true else { return }
            self.render()
        }
        render()
    }
    override func viewWillAppear() {
        super.viewWillAppear()
        presentationChanged(true)
    }
    func prepareForPresentation() {
        _ = view
        render()
    }
    func presentationChanged(_ visible: Bool) {
        guard visible != presented else {
            // viewWillAppear can run before NSWindow becomes visible. The host calls
            // this again after ordering it in; start the light on that first visible frame.
            if visible { updateStatus() }
            return
        }
        presented = visible
        guard visible else {
            timer?.invalidate(); timer = nil
            statusIndicator?.setPresented(false)
            return
        }
        render()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateStatus() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        Task { await model.refresh() }
    }
    override func viewDidDisappear() { super.viewDidDisappear(); presentationChanged(false) }

    func choose(_ mode: DisplayMode) {
        guard !model.busy else { return }
        // Startup can restore a policy before the menu-bar anchor is ready.
        // Confirmation/setup content must have its view hierarchy before rendering.
        _ = view
        if mode == model.mode, model.status?.phase != "waiting" {
            // Clicking the current policy also cancels a different policy's confirmation.
            guard pending != nil else { return }
            pending = nil; confirmingRisk = false; render()
            return
        }
        if mode == .system { pending = nil; confirmingRisk = false; Task { await model.stop() }; return }
        let needsConfirmation = mode == .always || !model.helper.ready
        // clearMessage publishes synchronously. Finalize local presentation state first,
        // otherwise that notification briefly renders a setup card for a ready helper.
        pending = needsConfirmation ? mode : nil
        confirmingRisk = mode == .always
        model.clearMessage()
        if needsConfirmation { render() }
        else { Task { await model.start(mode) } }
    }

    private func render() {
        glass.fontColor = model.glassFontColor
        glass.variant = model.glassAppearance
        glass.transparency = model.glassTransparency
        let warnsAboutDisplay = pending == nil && model.messageKey == nil && model.isActive
            && model.mode == .closed && model.power.lidClosed == true
            && model.externalBlockers.contains { $0.kind == .idleDisplay }
        let baseKey = "\(model.glassAppearance.rawValue)-\(Localization.language.rawValue)-\(NSApp.appearance?.name.rawValue ?? "system")-\(NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency)"
        if contentStack == nil || baseKey != baseSignature {
            baseSignature = baseKey
            signature = ""
            buildPolicySection()
        }
        updateControls()
        let key = "\(pending?.rawValue ?? "")-\(confirmingRisk)-\(model.messageKey ?? "")-\(model.technicalError != nil)-\(warnsAboutDisplay)-\(pending != nil ? model.helper.statusKey : "")"
        guard key != signature else {
            updateStatus()
            updatePreferredSize()
            return
        }
        signature = key
        guard let stack = contentStack else { return }
        if let messageModule {
            stack.removeArrangedSubview(messageModule)
            messageModule.removeFromSuperview()
        }
        messageModule = nil
        let usesCards = model.glassAppearance.usesCards
        let moduleWidth: CGFloat = usesCards ? 292 : 312
        func addModule(_ content: NSView) {
            let module = usesCards ? UI.glassCard(content) : content
            stack.insertArrangedSubview(module, at: 2)
            UI.fillWidth(module, in: stack)
            messageModule = module
        }
        if let pending {
            let card = confirmationCard(for: pending)
            addModule(card)
        } else if let key = model.messageKey {
            let warning = UI.column([UI.label(L(key), size: 12, width: moduleWidth)], spacing: 6)
            if key != "screen.requested", model.technicalError != nil {
                warning.addArrangedSubview(ActionButton(L("details")) { [weak self] in self?.showStatus?() })
            }
            addModule(warning)
        } else if warnsAboutDisplay {
            let warning = UI.column([
                UI.label(L("warning.externalDisplay"), size: 12, secondary: true, width: moduleWidth),
                ActionButton(L("details")) { [weak self] in self?.showStatus?() }
            ], spacing: 5)
            addModule(warning)
        }

        updateControls()
        updateStatus()
        updatePreferredSize()
    }

    private func updatePreferredSize() {
        guard let contentStack else { return }
        // A helper reply can change both policy and timer rows. Retain the current
        // frame during the in-flight request, then resize once to the confirmed result.
        if !model.busy || preferredContentSize == .zero {
            view.layoutSubtreeIfNeeded()
            let size = NSSize(width: 352, height: max(450, contentStack.fittingSize.height + 40))
            if size != preferredContentSize { preferredContentSize = size }
        }
    }

    private func buildPolicySection() {
        statusIndicator?.setPresented(false)
        document.subviews.forEach { $0.removeFromSuperview() }
        modeRows = []
        messageModule = nil
        durationSignature = ""
        let stack = UI.column(spacing: 16)
        contentStack = stack
        UI.pin(stack, to: document, inset: 20)

        let image = NSImageView(image: UI.brandImage(mode: model.isActive ? model.mode : .system, size: 27))
        brandView = image
        brandMode = model.isActive ? model.mode : .system
        image.contentTintColor = .labelColor
        image.widthAnchor.constraint(equalToConstant: 27).isActive = true
        let title = UI.column([UI.label(ServiceIdentity.displayName, size: 18, weight: .semibold),
                               UI.label(L("brand.tagline"), size: 11, secondary: true)], spacing: 3)
        let controls = PanelHeaderControls(
            hasSession: model.session != nil, busy: model.busy, confirming: pending != nil,
            showDetails: { [weak self] in self?.showStatus?() },
            resetSession: { [weak self] in self?.choose(.system) },
            quit: { [weak self] in self?.quit?() },
            showSettings: { [weak self] in self?.showSettings?() })
        headerControls = controls
        statusIndicator = controls.indicator
        let header = UI.row([image, title, UI.spacer(), controls], spacing: 10)
        header.distribution = .fill
        stack.addArrangedSubview(header); UI.fillWidth(header, in: stack)
        let usesCards = model.glassAppearance.usesCards
        let modeSection = UI.column(spacing: 7)
        modeSection.addArrangedSubview(UI.label(L("display.mode"), size: 10, weight: .semibold, secondary: true))
        let modes = UI.column(spacing: usesCards ? 0 : 2)
        modes.setAccessibilityRole(.group)
        modes.setAccessibilityLabel(L("display.mode"))
        modes.setAccessibilityHelp(L("mode.switch.help"))
        if usesCards { UI.styleGlassCard(modes, radius: 23) }
        for (index, mode) in DisplayMode.allCases.enumerated() {
            if usesCards && index > 0 {
                let divider = UI.divider()
                modes.addArrangedSubview(divider); UI.fillWidth(divider, in: modes)
            }
            let row = ModeRow(mode: mode, selected: model.mode == mode, enabled: !model.busy, inGlassGroup: usesCards) { [weak self] requested in self?.choose(requested) }
            modeRows.append(row)
            modes.addArrangedSubview(row); UI.fillWidth(row, in: modes)
        }
        modeSection.addArrangedSubview(modes); UI.fillWidth(modes, in: modeSection)
        stack.addArrangedSubview(modeSection); UI.fillWidth(modeSection, in: stack)
        buildFooter(in: stack, usesCards: usesCards)
    }

    private func buildFooter(in stack: NSStackView, usesCards: Bool) {
        countdown = UI.label("", size: 12, weight: .medium)
        countdown.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let clock = NSImageView(image: NSImage(systemSymbolName: "clock", accessibilityDescription: nil)!)
        clock.contentTintColor = model.glassAppearance == .backupBlack ? .white.withAlphaComponent(0.82) : UI.panelSecondary
        clock.widthAnchor.constraint(equalToConstant: 14).isActive = true
        let summary = UI.row([clock, countdown, UI.spacer()], spacing: 8)
        summary.distribution = .fill
        summary.heightAnchor.constraint(equalToConstant: usesCards ? 32 : 24).isActive = true
        let extend = ActionButton(L("duration.extend")) { [weak self] in Task { await self?.model.extendSession() } }
        extend.isBordered = false; extend.controlSize = .small
        extend.font = .systemFont(ofSize: 11)
        extend.contentTintColor = .labelColor
        extendButton = extend
        summary.addArrangedSubview(extend)

        let duration = PanelDurationPopup(frame: .zero, pullsDown: false)
        let durationKeys = ["duration.forever", "duration.30m", "duration.1h", "duration.2h", "duration.custom", "duration.until"]
        duration.addItems(withTitles: durationKeys.map(L))
        duration.target = self; duration.action = #selector(durationChanged(_:))
        duration.setAccessibilityLabel(L("duration"))
        popup = duration
        let footer = PanelFooterView(duration: duration, sessionSummary: summary, variant: model.glassAppearance,
            screenOff: { [weak self] in Task { await self?.model.screenOff() } })
        self.footer = footer
        stack.addArrangedSubview(footer); UI.fillWidth(footer, in: stack)
    }

    private func updateControls() {
        headerControls?.update(hasSession: model.session != nil, busy: model.busy, confirming: pending != nil)
        for row in modeRows {
            row.update(selected: model.mode == row.mode, enabled: !model.busy)
        }
        let mode = model.isActive ? model.mode : DisplayMode.system
        if !model.busy, brandMode != mode {
            brandView?.image = UI.brandImage(mode: mode, size: 27)
            brandMode = mode
        }
        let hasDeadline = model.session?.deadline != nil
        footer?.showSummary(hasDeadline || model.mode == .always)
        if extendButton?.isHidden == hasDeadline { extendButton?.isHidden = !hasDeadline }
        let selection = model.panelDuration
        let durationKey = "\(selection.seconds)-\(selection.until?.timeIntervalSinceReferenceDate ?? 0)"
        if durationKey != durationSignature {
            durationSignature = durationKey
            let values: [TimeInterval] = [0, 1800, 3600, 7200]
            let index = selection.until != nil ? 5 : values.firstIndex(of: selection.seconds) ?? 4
            popup?.showSelection(at: index, customSeconds: selection.seconds)
        }
        func updateActions(in view: NSView) {
            if let control = view as? ActionButton, control.identifier?.rawValue == "qiming.screenOff"
                || control === extendButton {
                control.blocksActions = model.busy
            }
            for child in view.subviews { updateActions(in: child) }
        }
        if let contentStack { updateActions(in: contentStack) }
        popup?.blocksInteraction = model.busy
    }

    private func confirmationCard(for mode: DisplayMode) -> NSView {
        let isRisk = confirmingRisk
        let card = UI.column(spacing: 9)
        let width: CGFloat = model.glassAppearance.usesCards ? 292 : 312
        card.addArrangedSubview(UI.label(L(isRisk ? "risk.title" : "setup.title"), size: 13, weight: .semibold, width: width))
        card.addArrangedSubview(UI.label(L(isRisk ? "risk.body" : "setup.body"), size: 12, secondary: true, width: width))
        if !isRisk {
            card.addArrangedSubview(UI.label(L(model.helper.statusKey), size: 11, secondary: true, width: width))
        }
        let cancel = ActionButton(L("cancel")) { [weak self] in
            self?.pending = nil; self?.confirmingRisk = false; self?.render()
        }
        let proceed = ActionButton(L(isRisk ? "risk.enable" : "setup.action")) { [weak self] in
            guard let self else { return }
            if isRisk {
                self.confirmingRisk = false
                if self.model.helper.ready {
                    self.pending = nil
                    Task { await self.model.start(mode) }
                    // start publishes busy before rebuilding. Do not first shrink to the
                    // previous policy here and expand again after the async reply.
                    return
                }
                self.render()
            } else {
                Task {
                    do {
                        try await self.model.helper.register()
                        if self.model.helper.ready {
                            self.pending = nil; await self.model.start(mode)
                        }
                    } catch { self.pending = nil; self.model.fail(error) }
                    self.render()
                }
            }
        }
        let row = UI.row([cancel, UI.spacer(), proceed])
        card.addArrangedSubview(row); UI.fillWidth(row, in: card)
        return card
    }

    private func updateStatus() {
        let confirmedState: PanelIndicatorState
        if model.connectionUnverified || model.technicalError != nil { confirmedState = .attention }
        else if model.status?.phase == "waiting" { confirmedState = .waiting }
        else if model.status?.manualDisplayOff == true { confirmedState = .screenOff }
        else if ["reason.lowBattery", "reason.thermal", "reason.conflict", "reason.failure"].contains(model.messageKey ?? "") {
            confirmedState = .protected
        } else if model.isActive && model.power.thermal >= 1 { confirmedState = .warm }
        else if model.isActive && model.mode == .displayOnly { confirmedState = .displayOnly }
        else if model.isActive { confirmedState = model.mode == .always ? .alwaysOn : .running }
        else { confirmedState = .system }
        // Hold the last confirmed visual while a request is in flight. A normal
        // start goes gray -> green, without borrowing the warning color.
        let state = model.busy ? (confirmedIndicatorState ?? confirmedState) : confirmedState
        if !model.busy || confirmedIndicatorState == nil { confirmedIndicatorState = state }
        let source = model.power.onAC.map { L($0 ? "power.ac" : "power.battery") } ?? L("unknown")
        let battery = model.power.battery.map { " · \($0)%" } ?? ""
        let lid = model.power.lidClosed.map { L($0 ? "lid.closed" : "lid.open") } ?? L("unknown")
        var details = ["\(source)\(battery) · \(lid)"]
        if model.busy { details.insert(L("state.applying"), at: 0) }
        if let session = model.session {
            if let deadline = session.deadline {
                let seconds = deadline.timeIntervalSinceNow
                let remaining = seconds > 0
                    ? L("time.remaining") + " " + Localization.clock(seconds, roundingUp: true)
                    : L("time.ending")
                countdown.stringValue = remaining
                details.append(remaining)
            } else {
                countdown.stringValue = L("screen.elapsed") + " " + Localization.clock(Date().timeIntervalSince(session.startedAt))
                details.append(L("duration.forever"))
            }
            if model.mode == .always {
                details.append(L("screen.elapsed") + " " + Localization.clock(Date().timeIntervalSince(session.startedAt)))
            }
        } else { details.append(L("state.noOverrides")) }
        if let message = model.messageKey { details.append(L(message)) }
        statusIndicator?.update(state, details: details.joined(separator: "\n"))
        statusIndicator?.setPresented(presented)
    }

    @objc private func durationChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        let values: [TimeInterval] = [0, 1800, 3600, 7200]
        guard !model.busy, (0...5).contains(index) else { return }
        if values.indices.contains(index) {
            Task { await model.changePanelDuration(values[index]) }
            return
        }
        let selection = model.panelDuration
        let alert = NSAlert()
        alert.messageText = L(index == 4 ? "duration.custom" : "duration.until")
        alert.informativeText = L("duration.limit")
        alert.addButton(withTitle: L("save")); alert.addButton(withTitle: L("cancel"))
        let input: NSView
        let custom = index == 4 ? PanelCustomDurationInput() : nil
        if let custom {
            if selection.seconds > 0 {
                custom.field.stringValue = String(format: "%g", selection.seconds / 60)
            }
            input = custom
        } else {
            let picker = NSDatePicker(frame: NSRect(x: 0, y: 0, width: 260, height: 30))
            picker.datePickerElements = [.yearMonthDay, .hourMinute]
            let earliest = Date().addingTimeInterval(60)
            picker.minDate = earliest; picker.maxDate = Date().addingTimeInterval(604800)
            picker.dateValue = selection.until.flatMap { $0 >= earliest ? $0 : nil }
                ?? Date().addingTimeInterval(7200)
            input = picker
        }
        alert.accessoryView = input
        if let custom { alert.window.initialFirstResponder = custom.field }
        if alert.runModal() == .alertFirstButtonReturn {
            if let custom, let minutes = Double(custom.field.stringValue), minutes > 0, minutes <= 10080 {
                Task { await model.changePanelDuration(minutes * 60) }
            } else if let picker = input as? NSDatePicker {
                let date = picker.dateValue
                Task { await model.changePanelDuration(selection.seconds, until: date) }
            }
        }
        durationSignature = ""
        render()
    }
}

@MainActor private final class PanelDocumentView: NSView {
    override var isFlipped: Bool { true }
}
