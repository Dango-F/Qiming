import AppKit
import QuartzCore

enum MenuBarAnchorGeometry {
    static func screenIndex(for rect: NSRect, screens: [NSRect]) -> Int? {
        guard !rect.isEmpty, rect.height <= 64,
              [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite) else { return nil }
        return screens.firstIndex { screen in
            // A status window can already have its final size while still sitting
            // at (0, 0) or below the screen. Its screen assignment alone is insufficient.
            screen.contains(NSPoint(x: rect.midX, y: rect.midY))
                && rect.minY >= screen.maxY - max(64, rect.height + 8)
                && rect.maxY <= screen.maxY + 2
        }
    }
}

/// Public AppKit window hosting: avoids the opaque chrome beneath an NSPopover's content.
@MainActor final class GlassPopover: NSObject, NSWindowDelegate {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }
    private let window = Panel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: true)
    private var sizeObservation: NSKeyValueObservation?
    private var frameUpdateScheduled = false
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var anchorObservers: [NSObjectProtocol] = []
    private weak var anchor: NSView?
    private var presented = false
    private var transitionID = 0
    var animates = true
    // Visibility is the requested state, not the still-visible closing animation.
    var isShown: Bool { presented }
    private var shouldAnimate: Bool { animates && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    var contentViewController: NSViewController? {
        didSet {
            sizeObservation = nil
            window.contentViewController = contentViewController
            if let controller = contentViewController {
                sizeObservation = controller.observe(\.preferredContentSize, options: [.new]) { [weak self] _, _ in
                    Task { @MainActor in self?.scheduleFrameUpdate() }
                }
            }
        }
    }
    override init() {
        super.init()
        window.isOpaque = false; window.backgroundColor = .clear
        // Float above ordinary windows while allowing native menus and modal alerts above us.
        window.hasShadow = true; window.level = .floating
        window.title = ServiceIdentity.displayName
        window.hidesOnDeactivate = false; window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.collectionBehavior = [.transient, .fullScreenAuxiliary, .moveToActiveSpace]
        window.delegate = self
    }
    @discardableResult func show(relativeTo rect: NSRect, of view: NSView, preferredEdge: NSRectEdge) -> Bool {
        // Status items are not always attached to their window during application launch.
        // Never order an unpositioned panel at the default screen origin.
        guard anchorGeometry(of: view, rect: rect) != nil else { return false }
        anchor = view
        observeAnchor(view)
        let wasVisible = window.isVisible
        let wasPresented = presented
        transitionID &+= 1
        presented = true
        (contentViewController as? PanelController)?.prepareForPresentation()
        guard updateFrame(animated: false) else { presented = false; return false }
        if localMonitor == nil {
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
                let consume = MainActor.assumeIsolated {
                    guard let self else { return false }
                    if event.type == .keyDown && event.keyCode == 53 { self.performClose(nil); return true }
                    if event.type != .keyDown && event.window !== self.window && !self.isAnchorEvent(event) {
                        self.performClose(nil)
                    }
                    return false
                }
                return consume ? nil : event
            }
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self, !self.isAnchorEvent(event) else { return }
                    self.performClose(nil)
                }
            }
        }
        let fade = shouldAnimate && !wasPresented
        if !wasVisible { window.alphaValue = fade ? 0 : 1 }
        else if !fade { window.alphaValue = 1 }
        window.makeKeyAndOrderFront(nil)
        (contentViewController as? PanelController)?.presentationChanged(true)
        if fade {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.20
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().alphaValue = 1
            }
        }
        return true
    }
    /// Startup waits for AppKit to attach and position the status item. No provisional
    /// window is shown; cancellation prevents a late popup after a user opens Settings.
    func showWhenAnchored(of view: NSView, preferredEdge: NSRectEdge) async -> Bool {
        var previousRect: NSRect?
        var stableSamples = 0
        for _ in 0..<150 {
            guard !Task.isCancelled else { return false }
            if let geometry = anchorGeometry(of: view, rect: view.bounds) {
                stableSamples = geometry.rect == previousRect ? stableSamples + 1 : 1
                previousRect = geometry.rect
                if stableSamples >= 3, show(relativeTo: view.bounds, of: view, preferredEdge: preferredEdge) { return true }
            } else {
                previousRect = nil; stableSamples = 0
            }
            do { try await Task.sleep(for: .milliseconds(20)) }
            catch { return false }
        }
        return false
    }
    func performClose(_ sender: Any?) {
        guard presented else { return }
        presented = false
        transitionID &+= 1
        let closingID = transitionID
        (contentViewController as? PanelController)?.presentationChanged(false)
        if let localMonitor { NSEvent.removeMonitor(localMonitor); self.localMonitor = nil }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor); self.globalMonitor = nil }
        removeAnchorObservers()
        if shouldAnimate && window.isVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                window.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.transitionID == closingID, !self.presented else { return }
                    self.window.orderOut(nil)
                    self.window.alphaValue = 1
                }
            }
        } else { window.orderOut(sender); window.alphaValue = 1 }
    }
    func windowDidResignKey(_ notification: Notification) {
        // AppKit can resign the panel before dispatching the status-button action.
        // Preserve its open state for that action, then dismiss only if no explicit
        // show/close has superseded this notification. Never infer a toggle from
        // the transient NSWindow visibility between mouse-down and mouse-up.
        let resignationID = transitionID
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, self.transitionID == resignationID, self.presented,
                  !self.window.isKeyWindow else { return }
            if self.anchorContains(NSEvent.mouseLocation) { return }
            self.performClose(nil)
        }
    }
    private func anchorContains(_ point: NSPoint) -> Bool {
        guard let anchor, let anchorWindow = anchor.window else { return false }
        return anchorWindow.convertToScreen(anchor.convert(anchor.bounds, to: nil)).contains(point)
    }
    private func isAnchorEvent(_ event: NSEvent) -> Bool {
        guard [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp].contains(event.type) else { return false }
        if let eventWindow = event.window, eventWindow === anchor?.window { return true }
        let point = event.window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
        return anchorContains(point) || anchorContains(NSEvent.mouseLocation)
    }
    private func scheduleFrameUpdate() {
        guard !frameUpdateScheduled else { return }
        frameUpdateScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.frameUpdateScheduled = false
            guard self.presented else { return }
            self.updateFrame(animated: self.shouldAnimate)
        }
    }
    private func anchorGeometry(of view: NSView, rect: NSRect) -> (rect: NSRect, screen: NSScreen)? {
        guard let anchorWindow = view.window, !anchorWindow.frame.isEmpty,
              !rect.isEmpty, !view.bounds.isEmpty else { return nil }
        let converted = anchorWindow.convertToScreen(view.convert(rect, to: nil))
        let screens = NSScreen.screens
        guard let index = MenuBarAnchorGeometry.screenIndex(for: converted, screens: screens.map(\.frame)) else { return nil }
        return (converted, screens[index])
    }
    private func removeAnchorObservers() {
        for observer in anchorObservers { NotificationCenter.default.removeObserver(observer) }
        anchorObservers.removeAll()
    }
    private func observeAnchor(_ view: NSView) {
        removeAnchorObservers()
        view.postsFrameChangedNotifications = true
        view.postsBoundsChangedNotifications = true
        let center = NotificationCenter.default
        let notifications: [(Notification.Name, AnyObject?)] = [
            (NSView.frameDidChangeNotification, view), (NSView.boundsDidChangeNotification, view),
            (NSWindow.didMoveNotification, view.window), (NSWindow.didResizeNotification, view.window),
            (NSWindow.didChangeScreenNotification, view.window),
            (NSApplication.didChangeScreenParametersNotification, nil)
        ]
        for (name, object) in notifications {
            anchorObservers.append(center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.scheduleFrameUpdate() }
            })
        }
    }
    @discardableResult private func updateFrame(animated: Bool) -> Bool {
        guard let anchor, let controller = contentViewController,
              let geometry = anchorGeometry(of: anchor, rect: anchor.bounds) else { return false }
        let rect = geometry.rect
        let visible = geometry.screen.visibleFrame
        let requested = controller.preferredContentSize
        let size = NSSize(width: max(352, requested.width), height: min(max(450, requested.height), visible.height - 16))
        let x = min(max(rect.midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
        let top = min(rect.minY, visible.maxY) - 6
        let y = max(visible.minY + 8, top - size.height)
        let frame = NSRect(origin: NSPoint(x: x, y: y), size: size)
        guard frame != window.frame else { return true }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated ? 0.20 : 0
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = animated
            if animated { window.animator().setFrame(frame, display: true) }
            else { window.setFrame(frame, display: window.isVisible, animate: false) }
        }
        return true
    }
}
