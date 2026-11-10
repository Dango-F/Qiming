import AppKit
import UserNotifications
import QuartzCore
import ServiceManagement

@main @MainActor final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var model: AppModel!
    private var item: NSStatusItem!
    private var popover: GlassPopover!
    private var panel: PanelController!
    private var settings: SettingsController?
    private var observation: UUID?
    private let shortcuts = Shortcuts()
    private var shortcutObserver: NSObjectProtocol?
    private var previewWindow: NSWindow?
    private var menuLanguage = ""
    private var statusImageKey: String?
    private var startupPresentation: Task<Void, Never>?
    private var presentationRequestID = 0

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: ServiceIdentity.app)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if let existing = others.first { existing.activate(); NSApp.terminate(nil); return }
        NSApp.setActivationPolicy(.accessory)
        // QA arguments affect presentation only; preview never starts a power session.
        let args = ProcessInfo.processInfo.arguments
        UserDefaults.standard.register(defaults: ["launchSession": true, "notifications": true])
        if let language = argument("--language", in: args), ["system", "chinese", "english"].contains(language) {
            UserDefaults.standard.set(language, forKey: "language")
        }
        if let appearance = argument("--appearance", in: args) {
            NSApp.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        }
        model = AppModel()
        configureMenu()
        panel = PanelController(model: model, backgroundBlendingMode:
            args.contains("--preview") && argument("--preview-background", in: args) != nil ? .withinWindow : .behindWindow)
        panel.showSettings = { [weak self] in self?.showSettings() }
        panel.showStatus = { [weak self] in self?.showSettings(page: 2) }
        panel.quit = { [weak self] in self?.quit() }
        popover = GlassPopover(); popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.contentViewController = panel
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.target = self; button.action = #selector(togglePanel)
            // Decide on mouse-down, before the status window can make the panel
            // resign key. Mouse-up must not reopen a panel closed by that press.
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        }
        observation = model.observe { [weak self] in self?.updateStatusItem() }
        updateStatusItem()
        shortcuts.action = { [weak self] id in
            guard let self else { return }
            if id == 2 { Task { await self.model.screenOff() } }
            else if self.model.session != nil { Task { await self.model.stop() } }
            else { self.showPanel(); self.panel.choose(.closed) }
        }
        shortcuts.update()
        shortcutObserver = NotificationCenter.default.addObserver(forName: .qimingShortcutsChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.shortcuts.update() }
        }
        let notifications = UNUserNotificationCenter.current()
        notifications.delegate = self
        notifications.setNotificationCategories([UNNotificationCategory(identifier: "SCREEN_REMINDER", actions: [
            UNNotificationAction(identifier: "SWITCH", title: L("mode.closed")),
            UNNotificationAction(identifier: "STOP", title: L("stop"))
        ], intentIdentifiers: [])])
        if args.contains("--preview") {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 352, height: 510),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.title = ServiceIdentity.displayName + " · " + L("preview")
            popover.contentViewController = nil
            if let path = argument("--preview-background", in: args), let image = NSImage(contentsOfFile: path) {
                // QA only: exercise the real panel against a detailed, local background.
                // The image is neither captured from the screen nor bundled with the app.
                let host = NSViewController(); host.view = NSView()
                let background = NSImageView(image: image); background.imageScaling = .scaleAxesIndependently
                for axis in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
                    background.setContentCompressionResistancePriority(.init(1), for: axis)
                    background.setContentHuggingPriority(.init(1), for: axis)
                }
                UI.pin(background, to: host.view)
                host.addChild(panel); UI.pin(panel.view, to: host.view)
                window.contentViewController = host
            } else { window.contentViewController = panel }
            window.center(); window.makeKeyAndOrderFront(nil)
            window.setContentSize(panel.preferredContentSize)
            panel.presentationChanged(true)
            previewWindow = window; NSApp.activate(ignoringOtherApps: true)
        } else {
            if !UserDefaults.standard.bool(forKey: "loginDefaultConfigured") {
                do {
                    if SMAppService.mainApp.status == .notRegistered {
                        try SMAppService.mainApp.register()
                    }
                    UserDefaults.standard.set(true, forKey: "loginDefaultConfigured")
                } catch { model.fail(error) }
            }
            Task { await model.checkNotificationPermission(requestAuthorization: true) }
            let installedRelease = Bundle.main.bundleURL.resolvingSymlinksInPath().path == "/Applications/Qiming.app"
            let receipt = installedRelease ? argument("--update-receipt", in: args) : nil
            Task { @MainActor [weak self] in
                guard let self else { return }
                let failure = await self.model.checkHelperOnLaunch(repairRegistration: installedRelease)
                if let receipt { self.writeUpdateReceipt(to: receipt, failure: failure) }
                if failure == nil, self.model.session == nil, UserDefaults.standard.bool(forKey: "launchSession"),
                   let savedMode = UserDefaults.standard.string(forKey: "lastMode"),
                   let mode = DisplayMode(rawValue: savedMode), mode != .system {
                    self.panel.choose(mode)
                }
            }
            showPanel()
        }
        tracePresentation("launch-complete")
        if ProcessInfo.processInfo.environment["QIMING_TRACE_PRESENTATION"] == "1" {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1))
                self?.tracePresentation("launch-settled")
            }
        }
    }
    private func tracePresentation(_ event: String) {
        guard ProcessInfo.processInfo.environment["QIMING_TRACE_PRESENTATION"] == "1" else { return }
        let windows = NSApp.windows.filter(\.isVisible).map {
            "\(type(of: $0)):\($0.title):\($0.frame)"
        }.joined(separator: "; ")
        NSLog("Qiming presentation: %@; panelShown=%@; windows=%@", event,
              String(popover?.isShown ?? false), windows)
    }
    private func argument(_ key: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: key), args.indices.contains(index + 1) else { return nil }
        return args[index + 1]
    }
    private func writeUpdateReceipt(to path: String, failure: String?) {
        let receipt = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let directory = receipt.deletingLastPathComponent()
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        guard receipt.lastPathComponent == "status.txt", directory.lastPathComponent.hasPrefix("qiming-update-"),
              directory.deletingLastPathComponent().path == temporary.path else { return }
        let text = failure.map { "ERROR\n\($0)\n" } ?? "OK\n"
        do { try text.write(to: receipt, atomically: true, encoding: .utf8) }
        catch { NSLog("Qiming could not write the update status receipt: %@", error.localizedDescription) }
    }
    @objc private func togglePanel() {
        let wasPending = startupPresentation != nil
        cancelPanelPresentation()
        if NSApp.currentEvent?.type == .rightMouseDown { toggleQuickSession(); return }
        if popover.isShown || wasPending { popover.performClose(nil) } else { showPanel() }
    }
    private func cancelPanelPresentation() {
        presentationRequestID &+= 1
        startupPresentation?.cancel()
        startupPresentation = nil
    }
    private func showPanel() {
        tracePresentation("explicit-show")
        if let previewWindow {
            previewWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        guard let button = item?.button, let popover else { return }
        cancelPanelPresentation()
        let requestID = presentationRequestID
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        startupPresentation = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.presentationRequestID == requestID { self.startupPresentation = nil } }
            guard await popover.showWhenAnchored(of: button, preferredEdge: .minY),
                  !Task.isCancelled, self.presentationRequestID == requestID else { return }
            NSApp.activate(ignoringOtherApps: true)
            popover.contentViewController?.view.window?.makeKey()
            self.tracePresentation("anchor-shown")
        }
    }
    private func updateStatusItem() {
        guard let model, let button = item?.button else { return }
        if menuLanguage != Localization.language.rawValue { configureMenu() }
        previewWindow?.title = ServiceIdentity.displayName + " · " + L("preview")
        let protectionAlert = ["reason.thermal", "reason.lowBattery", "reason.conflict", "reason.failure"].contains(model.messageKey ?? "")
        let badge: IconBadge
        if model.connectionUnverified || protectionAlert || (model.isActive && model.power.thermal >= 1)
            || (model.status?.phase == "active" && !model.isActive) {
            badge = .attention
        } else if model.status?.phase == "waiting" { badge = .paused }
        else { badge = .none }
        let visualMode = model.isActive ? model.mode : DisplayMode.system
        let imageKey = visualMode.rawValue + ":" + badge.rawValue
        // Keep the last confirmed image while applying; ordinary refreshes never redraw it.
        if (!model.busy || statusImageKey == nil), imageKey != statusImageKey {
            if statusImageKey != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                button.wantsLayer = true
                let transition = CATransition(); transition.type = .fade; transition.duration = 0.14
                button.layer?.add(transition, forKey: "qiming.mode")
            }
            item.length = badge == .none ? NSStatusItem.squareLength : 34
            button.image = UI.brandImage(mode: visualMode, size: 22, badge: badge)
            statusImageKey = imageKey
        }
        let state: String
        if model.busy { state = "state.applying" }
        else if model.connectionUnverified { state = "state.unverified" }
        else if model.status?.phase == "waiting" { state = "state.waiting" }
        else if model.isActive { state = model.mode == .displayOnly ? "state.displayOnly" : "state.active" }
        else { state = "state.system" }
        var description = ServiceIdentity.displayName + " · " + L(model.mode.titleKey) + " · " + L(state)
        if let deadline = model.session?.deadline {
            description += " · " + L("time.remaining") + " " + Localization.clock(deadline.timeIntervalSinceNow)
        }
        if protectionAlert, let key = model.messageKey { description += " · " + L(key) }
        else if model.isActive && model.power.thermal >= 1 { description += " · " + L("thermal.warm") }
        button.toolTip = description; button.setAccessibilityLabel(description)
    }
    private func showSettings(page: Int = 0) {
        cancelPanelPresentation()
        popover.performClose(nil)
        if settings == nil {
            settings = SettingsController(model: model)
            settings?.onClose = { [weak self] in self?.settings = nil }
        }
        settings?.present(page: page)
    }
    private func toggleQuickSession() {
        guard !model.busy else { return }
        if model.session != nil {
            Task { await model.stop() }
        } else {
            // Normally operate without opening the panel. Missing setup still
            // needs a visible explanation, rather than a silent failed action.
            if !model.helper.ready { showPanel() }
            panel.choose(.closed)
        }
    }
    @objc private func openSettings() { showSettings() }
    @objc private func quit() { NSApp.terminate(nil) }

    private func configureMenu() {
        menuLanguage = Localization.language.rawValue
        let menu = NSMenu()
        let applicationItem = NSMenuItem(title: ServiceIdentity.displayName, action: nil, keyEquivalent: "")
        let applicationMenu = NSMenu(title: ServiceIdentity.displayName)
        let settingsItem = NSMenuItem(title: L("settings") + "…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self; applicationMenu.addItem(settingsItem)
        applicationMenu.addItem(.separator())
        let quitItem = NSMenuItem(title: L("quit"), action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self; applicationMenu.addItem(quitItem)
        applicationItem.submenu = applicationMenu; menu.addItem(applicationItem)
        let editItem = NSMenuItem(title: L("edit"), action: nil, keyEquivalent: ""); let edit = NSMenu(title: L("edit"))
        for (key, selector, shortcut) in [("edit.cut", #selector(NSText.cut(_:)), "x"),
            ("edit.copy", #selector(NSText.copy(_:)), "c"), ("edit.paste", #selector(NSText.paste(_:)), "v"),
            ("edit.selectAll", #selector(NSText.selectAll(_:)), "a")] {
            edit.addItem(NSMenuItem(title: L(key), action: selector, keyEquivalent: shortcut))
        }
        editItem.submenu = edit; menu.addItem(editItem)
        let windowItem = NSMenuItem(title: L("window"), action: nil, keyEquivalent: "")
        let windowMenu = NSMenu(title: L("window"))
        windowMenu.addItem(NSMenuItem(title: L("window.close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        windowItem.submenu = windowMenu; menu.addItem(windowItem)
        NSApp.windowsMenu = windowMenu
        if ProcessInfo.processInfo.arguments.contains("--preview") {
            let previewItem = NSMenuItem(title: L("preview"), action: nil, keyEquivalent: "")
            let previewMenu = NSMenu(title: L("preview"))
            for (key, selector) in [("appearance.light", #selector(previewLight)), ("appearance.dark", #selector(previewDark))] {
                let item = NSMenuItem(title: L(key), action: selector, keyEquivalent: "")
                item.target = self; previewMenu.addItem(item)
            }
            previewItem.submenu = previewMenu; menu.addItem(previewItem)
        }
        NSApp.mainMenu = menu
    }
    @objc private func previewLight() { NSApp.appearance = NSAppearance(named: .aqua); model.changed() }
    @objc private func previewDark() { NSApp.appearance = NSAppearance(named: .darkAqua); model.changed() }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        guard !model.busy else { return .terminateCancel }
        guard model.session != nil else { return .terminateNow }
        Task {
            await model.stop()
            if model.session != nil || model.technicalError != nil {
                // Invalidating the connection asks the daemon to clean up; its lease is the final fallback.
                model.helper.invalidate()
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        tracePresentation("reopen")
        showPanel()
        return true
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        Task { @MainActor in
            if action == "STOP" { await self.model.stop() }
            else if action == "SWITCH" { await self.model.start(.closed) }
        }
        completionHandler()
    }
}
