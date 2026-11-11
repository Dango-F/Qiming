import AppKit
import ServiceManagement

@MainActor final class SettingsController: NSWindowController, NSWindowDelegate {
    private let model: AppModel
    private var observation: UUID?
    private var tabs: NSTabViewController!
    private var language = ""
    private var statusText: NSTextView?
    private var previewWindow: NSWindow?
    private weak var glassPreview: GlassPreviewView?
    private weak var glassSlider: NSSlider?
    private weak var glassVariantPicker: NSPopUpButton?
    private weak var helperLabel: NSTextField?
    private weak var notificationToggle: NSButton?
    private weak var notificationDetail: NSTextField?
    private weak var notificationSettingsButton: NSButton?
    var onClose: (() -> Void)?

    init(model: AppModel) {
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 470),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.minSize = NSSize(width: 580, height: 440)
        window.center(); window.isReleasedWhenClosed = false
        window.delegate = self
        build()
        observation = model.observe { [weak self] in
            guard let self else { return }
            if self.language != Localization.language.rawValue { self.build() }
            self.glassPreview?.variant = self.model.glassAppearance
            self.glassPreview?.fontColor = self.model.glassFontColor
            self.glassPreview?.transparency = self.model.glassTransparency
            self.glassVariantPicker?.selectItem(at: GlassAppearanceVariant.allCases.firstIndex(of: self.model.glassAppearance) ?? 0)
            if self.glassSlider?.doubleValue != self.model.glassTransparency {
                self.glassSlider?.doubleValue = self.model.glassTransparency
            }
            if self.tabs.selectedTabViewItemIndex == 2 { self.updateStatus() }
            self.helperLabel?.stringValue = L(self.model.helper.statusKey)
            self.updateNotificationControls()
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }
    func windowWillClose(_ notification: Notification) {
        if let observation { model.removeObserver(observation); self.observation = nil }
        previewWindow?.close(); previewWindow = nil
        onClose?()
    }

    func present(page: Int = 0) {
        build()
        tabs.selectedTabViewItemIndex = page
        showWindow(nil); NSApp.activate(ignoringOtherApps: true)
        Task { await model.refresh(); await model.checkNotificationPermission() }
    }

    private func build() {
        let selected = tabs?.selectedTabViewItemIndex ?? 0
        language = Localization.language.rawValue
        window?.title = String(format: L("settings.title"), ServiceIdentity.displayName)
        tabs = NSTabViewController(); tabs.tabStyle = .toolbar
        for (title, symbol, content) in [
            ("general", "gearshape", generalPage()),
            ("protection", "shield.lefthalf.filled", protectionPage()),
            ("status", "waveform.path.ecg", statusPage())
        ] {
            let controller = NSViewController(); controller.view = scrollPage(content)
            let item = NSTabViewItem(viewController: controller)
            item.label = L(title); item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: L(title))
            tabs.addTabViewItem(item)
        }
        window?.contentViewController = tabs
        tabs.selectedTabViewItemIndex = selected
        updateStatus()
    }

    private func scrollPage(_ stack: NSStackView) -> NSView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let document = FlippedDocumentView(); scroll.documentView = document
        UI.pin(stack, to: document, inset: 28)
        document.translatesAutoresizingMaskIntoConstraints = false
        document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        return scroll
    }
    private func heading(_ title: String, detail: String) -> NSStackView {
        UI.column([UI.label(L(title), size: 20, weight: .semibold),
                   UI.label(L(detail), secondary: true, width: 540)], spacing: 6)
    }
    private func row(_ key: String, _ control: NSView) -> NSStackView {
        let label = UI.label(L(key), width: 330)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        let row = UI.row([label, UI.spacer(), control], spacing: 16)
        row.alignment = .firstBaseline
        return row
    }
    private func checkbox(_ title: String, value: Bool, action: @escaping (Bool) -> Void) -> NSButton {
        let button = ActionButton(L(title)) {}
        button.setButtonType(.switch); button.state = value ? .on : .off
        button.actionBlock = { [weak button] in if let button { action(button.state == .on) } }
        return button
    }
    private func add(_ child: NSView, to stack: NSStackView) { stack.addArrangedSubview(child); UI.fillWidth(child, in: stack) }

    private func generalPage() -> NSStackView {
        let stack = UI.column(spacing: 18)
        add(heading("general", detail: "general.subtitle"), to: stack)
        add(glassControls(), to: stack)
        add(UI.divider(), to: stack)
        let languages = ClosurePopup(titles: [L("language.system"), "简体中文", "English"],
                                    index: Language.allCases.firstIndex(of: Localization.language) ?? 0) { [weak self] index in
            UserDefaults.standard.set(Language.allCases[index].rawValue, forKey: "language")
            self?.model.languageChanged()
        }
        add(row("language", languages), to: stack)
        let durations: [TimeInterval] = [0, 1800, 3600, 7200]
        let durationPopup = ClosurePopup(titles: ["duration.forever", "duration.30m", "duration.1h", "duration.2h"].map(L),
            index: durations.firstIndex(of: model.duration) ?? 0) { [weak self] index in self?.model.duration = durations[index] }
        add(row("duration.default", durationPopup), to: stack)
        add(checkbox("login.start", value: SMAppService.mainApp.status == .enabled) { [weak self] enabled in
            do {
                if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                UserDefaults.standard.set(true, forKey: "loginDefaultConfigured")
            }
            catch { self?.model.fail(error); self?.build() }
        }, to: stack)
        add(checkbox("launch.session", value: UserDefaults.standard.bool(forKey: "launchSession")) { enabled in
            UserDefaults.standard.set(enabled, forKey: "launchSession")
        }, to: stack)
        let launchDetail = UI.label(L("launch.session.detail"), size: 12, secondary: true, width: 520)
        let launchExplanation = NSView()
        launchDetail.translatesAutoresizingMaskIntoConstraints = false
        launchExplanation.addSubview(launchDetail)
        NSLayoutConstraint.activate([
            launchDetail.leadingAnchor.constraint(equalTo: launchExplanation.leadingAnchor, constant: 22),
            launchDetail.trailingAnchor.constraint(equalTo: launchExplanation.trailingAnchor),
            launchDetail.topAnchor.constraint(equalTo: launchExplanation.topAnchor),
            launchDetail.bottomAnchor.constraint(equalTo: launchExplanation.bottomAnchor)
        ])
        add(launchExplanation, to: stack)
        let notificationToggle = checkbox("notifications", value: model.notifications) { [weak self] in
            self?.model.notifications = $0
        }
        self.notificationToggle = notificationToggle
        add(notificationToggle, to: stack)
        let detail = UI.label("", size: 12, secondary: true, width: 520)
        notificationDetail = detail
        let settings = ActionButton(L("notifications.settings")) { [weak self] in self?.model.openNotificationSettings() }
        notificationSettingsButton = settings
        let notificationInfo = UI.column([detail, settings], spacing: 6)
        add(notificationInfo, to: stack)
        updateNotificationControls()
        add(UI.divider(), to: stack)
        add(UI.label(L("shortcuts"), weight: .semibold), to: stack)
        add(checkbox("shortcuts.enable", value: UserDefaults.standard.bool(forKey: "shortcuts")) { [weak self] enabled in
            UserDefaults.standard.set(enabled, forKey: "shortcuts")
            NotificationCenter.default.post(name: .qimingShortcutsChanged, object: nil)
            self?.model.changed()
        }, to: stack)
        add(row("shortcuts.toggle", UI.label("⌃⌥⌘ A", secondary: true)), to: stack)
        add(row("screen.off", UI.label("⌃⌥⌘ S", secondary: true)), to: stack)
        add(UI.divider(), to: stack)
        let release = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let version = UI.label(release, size: 12, secondary: true)
        version.isSelectable = true
        version.setAccessibilityIdentifier("qiming.settings.version")
        add(row("app.version", version), to: stack)
        add(UI.label(L("privacy.local"), size: 12, secondary: true, width: 540), to: stack)
        return stack
    }

    private func updateNotificationControls() {
        notificationToggle?.state = model.notifications ? .on : .off
        notificationDetail?.stringValue = model.notificationError ?? L(model.notificationDetailKey)
        notificationSettingsButton?.isHidden = !model.notificationsNeedSettings
    }

    private func glassControls() -> NSView {
        let variants = GlassAppearanceVariant.allCases
        let variant = ClosurePopup(titles: variants.map { L($0.titleKey) },
            index: variants.firstIndex(of: model.glassAppearance) ?? 0) { [weak self] index in
                self?.model.glassAppearance = variants[index]
            }
        variant.setAccessibilityLabel(L("glass.variant"))
        glassVariantPicker = variant
        let variantRow = row("glass.variant", variant)
        let colors = GlassFontColor.allCases
        let fontColor = ClosurePopup(titles: colors.map { L($0.titleKey) },
            index: model.glassFontColor == .black ? 0 : 1) { [weak self] index in
                self?.model.glassFontColor = colors[index]
            }
        fontColor.setAccessibilityLabel(L("glass.fontColor"))
        fontColor.setAccessibilityIdentifier("qiming.settings.glassFontColor")
        let fontColorRow = row("glass.fontColor", fontColor)
        let preview = GlassPreviewView(); preview.variant = model.glassAppearance
        preview.fontColor = model.glassFontColor
        preview.transparency = model.glassTransparency
        glassPreview = preview
        let slider = NSSlider(value: model.glassTransparency, minValue: 0, maxValue: 1,
                              target: self, action: #selector(glassChanged(_:)))
        slider.isContinuous = true
        slider.trackFillColor = .separatorColor
        slider.setAccessibilityLabel(L("glass.transparency"))
        slider.setAccessibilityHelp(L("glass.detail"))
        glassSlider = slider
        let diffused = NSImageView(image: NSImage(systemSymbolName: "square.fill.on.square.fill", accessibilityDescription: L("glass.diffused"))!)
        let clear = NSImageView(image: NSImage(systemSymbolName: "square.on.square", accessibilityDescription: L("glass.clear"))!)
        for icon in [diffused, clear] {
            icon.contentTintColor = .secondaryLabelColor
            icon.widthAnchor.constraint(equalToConstant: 20).isActive = true
        }
        let track = UI.row([diffused, slider, clear], spacing: 12)
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let endpoints = UI.row([UI.label(L("glass.diffused"), size: 11, secondary: true), UI.spacer(),
                                UI.label(L("glass.clear"), size: 11, secondary: true)])
        let reset = ActionButton(L("glass.reset")) { [weak self] in
            self?.model.glassTransparency = GlassConfiguration.defaultTransparency
        }
        reset.controlSize = .small
        let header = UI.row([UI.label("Liquid Glass", weight: .semibold), UI.spacer(), reset])
        let stack = UI.column([header, variantRow, UI.label(L("glass.variant.detail"), size: 11, secondary: true, width: 540),
                              fontColorRow, preview, UI.label(L("glass.transparency"), size: 12), track, endpoints,
                              UI.label(L("glass.detail"), size: 12, secondary: true, width: 540)], spacing: 10)
        for child in [header, variantRow, fontColorRow, preview, track, endpoints] { UI.fillWidth(child, in: stack) }
        return stack
    }
    @objc private func glassChanged(_ sender: NSSlider) { model.glassTransparency = sender.doubleValue }

    private func protectionPage() -> NSStackView {
        let stack = UI.column(spacing: 18)
        add(heading("protection", detail: "protection.subtitle"), to: stack)
        add(checkbox("battery.allow", value: model.policy.allowBattery) { [weak self] value in
            guard let self else { return }; var p = self.model.policy; p.allowBattery = value; self.model.policy = p
        }, to: stack)
        let levels = [10, 15, 20, 25, 30, 40, 50]
        let battery = ClosurePopup(titles: levels.map { "\($0)%" }, index: levels.firstIndex(of: model.policy.minimumBattery) ?? 2) { [weak self] index in
            guard let self else { return }; var p = self.model.policy; p.minimumBattery = levels[index]; self.model.policy = p
        }
        battery.isEnabled = model.policy.endOnLowBattery
        battery.setAccessibilityIdentifier("qiming.protection.batteryThreshold")
        let lowBattery = checkbox("battery.threshold", value: model.policy.endOnLowBattery) { [weak self, weak battery] value in
            guard let self else { return }
            var policy = self.model.policy
            policy.endOnLowBattery = value
            self.model.policy = policy
            battery?.isEnabled = value
        }
        lowBattery.setAccessibilityIdentifier("qiming.protection.lowBattery")
        let batteryRow = UI.row([lowBattery, UI.spacer(), battery], spacing: 16)
        batteryRow.alignment = .firstBaseline
        add(batteryRow, to: stack)
        add(checkbox("power.pause", value: model.policy.pauseOnDisconnect) { [weak self] value in
            guard let self else { return }; var p = self.model.policy; p.pauseOnDisconnect = value; self.model.policy = p
        }, to: stack)
        add(checkbox("power.resume", value: model.policy.resumeOnPower) { [weak self] value in
            guard let self else { return }; var p = self.model.policy; p.resumeOnPower = value; self.model.policy = p
        }, to: stack)
        let reminders = [30, 60, 90, 120]
        let reminder = ClosurePopup(titles: reminders.map { "\($0) " + L("duration.minutes") },
                                    index: reminders.firstIndex(of: model.policy.reminderMinutes) ?? 1) { [weak self] index in
            guard let self else { return }; var p = self.model.policy; p.reminderMinutes = reminders[index]; self.model.policy = p
        }
        add(row("reminder.interval", reminder), to: stack)
        add(UI.label(L("protection.next"), size: 12, secondary: true, width: 540), to: stack)
        add(UI.divider(), to: stack)
        add(row("thermal.protection", UI.label(L("enabled"), secondary: true)), to: stack)
        add(UI.label(L("thermal.detail"), size: 12, secondary: true, width: 540), to: stack)
        add(UI.label(L("risk.body"), size: 12, secondary: true, width: 540), to: stack)
        add(UI.divider(), to: stack)
        let helperLabel = UI.label(L(model.helper.statusKey), secondary: true)
        self.helperLabel = helperLabel
        add(row("helper.title", helperLabel), to: stack)
        add(UI.label(L("helper.changes"), size: 12, secondary: true, width: 540), to: stack)
        let buttons = UI.row([
            ActionButton(L("setup.action")) { [weak self] in
                guard let self, !self.model.busy else { return }
                Task {
                    do {
                        try await self.model.helper.register()
                        await self.model.refresh()
                        self.build()
                    } catch { self.model.fail(error) }
                }
            },
            ActionButton(L("helper.settings")) { SMAppService.openSystemSettingsLoginItems() },
            ActionButton(L("helper.remove")) { [weak self] in
                guard let self, !self.model.busy else { return }
                Task {
                    if self.model.session != nil { await self.model.stop() }
                    guard self.model.session == nil, self.model.technicalError == nil else { return }
                    do { try await self.model.helper.unregister(); self.build() } catch { self.model.fail(error) }
                }
            }
        ])
        add(buttons, to: stack)
        add(ActionButton(L("verification")) { [weak self] in self?.showVerification() }, to: stack)
        return stack
    }

    private func statusPage() -> NSStackView {
        let stack = UI.column(spacing: 16)
        add(heading("status", detail: "status.subtitle"), to: stack)
        let text = NSTextView(); text.isEditable = false; text.isSelectable = true
        text.drawsBackground = false; text.font = .systemFont(ofSize: 13)
        text.textContainerInset = NSSize(width: 0, height: 8)
        text.textContainer?.lineFragmentPadding = 0
        let scroll = NSScrollView(); scroll.documentView = text; scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.heightAnchor.constraint(equalToConstant: 275).isActive = true
        statusText = text
        add(scroll, to: stack)
        add(UI.row([
            ActionButton(L("status.check")) { [weak self] in Task { await self?.model.refresh() } },
            ActionButton(L("status.restore")) { [weak self] in Task { await self?.model.stop() } },
            ActionButton(L("status.preview")) { [weak self] in Task { await self?.previewDiagnostics() } }
        ]), to: stack)
        return stack
    }
    private func updateStatus() { statusText?.string = model.statusSummary() }
    private func showVerification() {
        let alert = NSAlert(); alert.messageText = L("verification"); alert.informativeText = L("verification.body")
        alert.addButton(withTitle: L("done")); alert.runModal()
    }
    private func previewDiagnostics() async {
        let assertions = await Task.detached { SystemPower.assertionDetails() }.value
        let report = model.diagnosticReport(assertions: assertions)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 520),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = L("status.preview"); window.center(); window.isReleasedWhenClosed = false
        let text = NSTextView(); text.isEditable = true; text.string = report
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.textContainerInset = NSSize(width: 0, height: 12)
        text.textContainer?.lineFragmentPadding = 0
        let scroll = NSScrollView(); scroll.documentView = text; scroll.hasVerticalScroller = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 350).isActive = true
        let export = ActionButton(L("status.export")) { [weak window, weak text] in
            guard let window, let text else { return }
            let panel = NSSavePanel(); panel.nameFieldStringValue = "Qiming-diagnostics.txt"
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let url = panel.url else { return }
                do { try text.string.write(to: url, atomically: true, encoding: .utf8) }
                catch { NSAlert(error: error).runModal() }
            }
        }
        let stack = UI.column([UI.label(L("status.privacy"), size: 12, secondary: true, width: 640), scroll, export])
        UI.fillWidth(scroll, in: stack)
        let root = NSView(); UI.pin(stack, to: root, inset: 20); window.contentView = root
        previewWindow = window; window.makeKeyAndOrderFront(nil)
    }
}

@MainActor private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor private final class ClosurePopup: NSPopUpButton {
    let selected: (Int) -> Void
    init(titles: [String], index: Int, selected: @escaping (Int) -> Void) {
        self.selected = selected
        super.init(frame: .zero, pullsDown: false)
        addItems(withTitles: titles); selectItem(at: index)
        target = self; action = #selector(selectionChanged)
    }
    @objc private func selectionChanged() { selected(indexOfSelectedItem) }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }
}
