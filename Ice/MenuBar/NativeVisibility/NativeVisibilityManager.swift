//
//  NativeVisibilityManager.swift
//  Ice
//

import Cocoa
import Combine
import ScreenCaptureKit

// MARK: - MenuBarClientCore

/// A wrapper around macOS 27's private `MenuBarClientCore` framework.
///
/// Starting in macOS 27, status items are drawn by `MenuBarAgent` instead of
/// living in their own windows, and an item that is wider than the space
/// available is removed from the layout instead of pushing other items off
/// screen. This breaks hiding items by expanding a control item. The framework
/// behind the system's assessment (exam lockdown) mode can instead restrict
/// the menu bar to an allow-list of apps, which is what this wraps.
///
/// Everything is resolved at runtime, so a macOS release that changes or
/// removes the framework makes ``isAvailable`` return `false` instead of
/// crashing.
enum MenuBarClientCore {
    private static let frameworkPath = "/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore"

    private static let configurationInit = NSSelectorFromString("initWithAllowedSystemItems:allowedBundleIdentifiers:")
    private static let activateSelector = NSSelectorFromString("activateWithConfiguration:completionHandler:")
    private static let invalidateSelector = NSSelectorFromString("invalidate")

    private typealias ConfigurationInitIMP = @convention(c) (
        Unmanaged<AnyObject>, Selector, NSArray, NSArray
    ) -> Unmanaged<AnyObject>?

    private typealias ActivateIMP = @convention(c) (
        AnyObject, Selector, AnyObject, @escaping @convention(block) (NSError?) -> Void
    ) -> Void

    private static let classes: (configuration: NSObject.Type, assertion: NSObject.Type)? = {
        guard
            dlopen(frameworkPath, RTLD_NOW | RTLD_LOCAL) != nil,
            let configuration = NSClassFromString("MBAssessmentModeConfiguration") as? NSObject.Type,
            let assertion = NSClassFromString("MBAssessmentModeAssertion") as? NSObject.Type,
            configuration.instancesRespond(to: configurationInit),
            assertion.instancesRespond(to: activateSelector),
            assertion.instancesRespond(to: invalidateSelector)
        else {
            return nil
        }
        return (configuration, assertion)
    }()

    /// A Boolean value that indicates whether the framework, its classes, and
    /// every selector used are available on this system.
    static var isAvailable: Bool {
        classes != nil
    }

    /// Restricts the menu bar to the given system items and apps. macOS hides
    /// every other status item and reflows the menu bar.
    ///
    /// The restriction lasts until the returned assertion is invalidated, or
    /// until this process exits. The completion handler runs on the main queue.
    static func activate(
        allowedSystemItems: [Int],
        allowedBundleIdentifiers: [String],
        completion: @escaping (Result<Assertion, Error>) -> Void
    ) {
        guard let classes else {
            return completion(.failure(NativeVisibilityError.unavailable))
        }

        // Both lists must be arrays, as the framework indexes into them.
        let systemItems = allowedSystemItems.map { NSNumber(value: $0) } as NSArray
        let bundleIdentifiers = allowedBundleIdentifiers as NSArray

        let initIMP = unsafeBitCast(
            classes.configuration.instanceMethod(for: configurationInit),
            to: ConfigurationInitIMP.self
        )
        guard
            let allocated = (classes.configuration as AnyObject).perform(NSSelectorFromString("alloc")),
            let configuration = initIMP(allocated, configurationInit, systemItems, bundleIdentifiers)?.takeRetainedValue()
        else {
            return completion(.failure(NativeVisibilityError.creationFailed))
        }

        let rawAssertion = classes.assertion.init()
        let activateIMP = unsafeBitCast(
            rawAssertion.method(for: activateSelector),
            to: ActivateIMP.self
        )
        activateIMP(rawAssertion, activateSelector, configuration) { error in
            DispatchQueue.main.async {
                if let error {
                    completion(.failure(error))
                } else {
                    completion(.success(Assertion(raw: rawAssertion)))
                }
            }
        }
    }

    /// A held menu bar restriction.
    final class Assertion {
        private var raw: NSObject?

        fileprivate init(raw: NSObject) {
            self.raw = raw
        }

        /// Drops the restriction, letting macOS show the hidden items again.
        func invalidate() {
            guard let raw else {
                return
            }
            self.raw = nil
            _ = raw.perform(MenuBarClientCore.invalidateSelector)
        }

        deinit {
            invalidate()
        }
    }
}

enum NativeVisibilityError: LocalizedError {
    case unavailable
    case creationFailed

    var errorDescription: String? {
        switch self {
        case .unavailable: "MenuBarClientCore is unavailable on this system"
        case .creationFailed: "Could not create the menu bar visibility configuration"
        }
    }
}

// MARK: - NativeVisibilityManager

/// Hides menu bar items on macOS 27 and later by restricting the menu bar to
/// the apps whose items are in the shown sections.
///
/// Sections are read from where each app's items sit relative to the control
/// items, using the Accessibility API. Hiding applies per app: an app with
/// several items hides or shows them all, and the most visible section wins.
/// macOS's own items (clock, Control Center, etc.) are always kept visible.
@MainActor
final class NativeVisibilityManager: ObservableObject {
    /// A Boolean value that indicates whether hiding should use the native
    /// mechanism instead of expanding control items.
    static let isEnabled: Bool = {
        if #available(macOS 27, *) {
            return MenuBarClientCore.isAvailable
        }
        return false
    }()

    /// System item identifiers to keep visible. Unknown identifiers are ignored.
    private static let systemItemsToKeep = Array(0..<64)

    /// Bundles that own macOS's own items. These cannot be hidden by bundle, so
    /// they are left out of the layout and kept visible separately.
    private static let systemItemOwners: Set<String> = [
        "com.apple.MenuBarAgent",
        "com.apple.controlcenter",
    ]

    /// The section that each app's items belong to.
    private struct Layout {
        var sections = [String: MenuBarSection.Name]()

        func bundles(in wanted: Set<MenuBarSection.Name>) -> [String] {
            sections.filter { wanted.contains($0.value) }.map(\.key).sorted()
        }
    }

    /// A menu bar item as last seen while it was drawn, for the Ice Bar.
    struct ItemRecord: Identifiable {
        let id = UUID()
        let bundleIdentifier: String
        /// The item's frame, in Core Graphics coordinates, when it was last read.
        let frame: CGRect
        /// The item's index among its app's items, ordered from left to right.
        let index: Int
        /// An image of the item, cut from a capture of the menu bar.
        let image: CGImage?
        /// The scale factor of the display the image was captured on.
        let scale: CGFloat
    }

    /// The menu bar's items as last seen while they were drawn.
    @Published private(set) var itemRecords = [ItemRecord]()

    /// Apps whose items are shown for a moment, e.g. to click one from the Ice Bar.
    private var temporarilyShown = Set<String>()

    /// A Boolean value that indicates whether the next layout read should use
    /// the cached layout, even though nothing is hidden.
    private var usesCachedLayoutOnce = false

    /// A Boolean value that indicates whether a click on the clock is being
    /// passed on to it.
    private var isPassingClockClick = false

    private struct InventoryItem {
        let bundleIdentifier: String
        let frame: CGRect
    }

    private weak var appState: AppState?

    private var assertion: MenuBarClientCore.Assertion?

    /// The most recent layout. Only read fresh while nothing is hidden, as
    /// hidden items report stale positions.
    private var layout: Layout?

    /// Incremented whenever a pending update should no longer win.
    private var generation = 0

    private var retryTask: Task<Void, Never>?

    /// The last time a control item moved. At launch, positions read shortly
    /// after a move may not reflect where macOS placed the items yet.
    private var lastControlItemMove = Date.distantPast

    /// A Boolean value that indicates whether a layout has been read since
    /// launch. After that, control items only move because of toggling.
    private var hasReadLayout = false

    /// The most recent warning, so that retries don't repeat it.
    private var lastWarning: String?

    private var cancellables = Set<AnyCancellable>()

    init(appState: AppState) {
        self.appState = appState
    }

    func performSetup() {
        guard
            Self.isEnabled,
            let appState,
            let hiddenSection = appState.menuBarManager.section(withName: .hidden),
            let alwaysHiddenSection = appState.menuBarManager.section(withName: .alwaysHidden)
        else {
            return
        }

        Publishers.CombineLatest3(
            hiddenSection.controlItem.$state.removeDuplicates(),
            alwaysHiddenSection.controlItem.$state.removeDuplicates(),
            appState.settingsManager.advancedSettingsManager.$enableAlwaysHiddenSection.removeDuplicates()
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            self?.update()
        }
        .store(in: &cancellables)

        // Each restriction allows the apps that were running when it was made,
        // so an app launched later would be hidden wherever its items are. The
        // workspace's launch notification isn't posted for agent apps, which
        // most menu bar apps are, so observe the running apps instead.
        NSWorkspace.shared.publisher(for: \.runningApplications)
            .map { Set($0.compactMap(\.bundleIdentifier)) }
            .removeDuplicates()
            .scan((previous: Set<String>(), current: Set<String>())) { ($0.current, $1) }
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] change in
                guard let self, assertion != nil else {
                    return
                }
                update()
                classifyLaunchedApps(change.current.subtracting(change.previous))
            }
            .store(in: &cancellables)

        Publishers.MergeMany(appState.menuBarManager.sections.map { $0.controlItem.$windowFrame.removeDuplicates() })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.lastControlItemMove = Date()
            }
            .store(in: &cancellables)
    }

    /// Applies the restriction that matches the current section states.
    private func update() {
        retryTask?.cancel()
        retryTask = nil

        guard
            let appState,
            let hiddenSection = appState.menuBarManager.section(withName: .hidden),
            let alwaysHiddenSection = appState.menuBarManager.section(withName: .alwaysHidden)
        else {
            return
        }

        let alwaysHiddenEnabled = appState.settingsManager.advancedSettingsManager.enableAlwaysHiddenSection

        let hiddenSections: Set<MenuBarSection.Name>
        if hiddenSection.controlItem.state == .hideItems {
            hiddenSections = [.hidden, .alwaysHidden]
        } else if alwaysHiddenEnabled && alwaysHiddenSection.controlItem.state == .hideItems {
            hiddenSections = [.alwaysHidden]
        } else {
            releaseAssertion()
            return
        }

        guard AXIsProcessTrusted() else {
            // Without Accessibility the sections can't be read, and guessing
            // would hide items that are meant to be visible.
            warnOnce("Accessibility permission is needed to read the menu bar sections")
            scheduleRetry()
            return
        }

        withLayout(alwaysHiddenEnabled: alwaysHiddenEnabled) { [weak self] layout in
            guard let self else {
                return
            }
            guard let layout else {
                // The control items may not have been placed yet, e.g. at launch.
                warnOnce("Unable to read the control item positions")
                scheduleRetry()
                return
            }
            activate(hiding: layout.bundles(in: hiddenSections))
        }
    }

    private func warnOnce(_ message: String) {
        guard message != lastWarning else {
            return
        }
        lastWarning = message
        Logger.nativeVisibility.warning(message)
    }

    /// Hides newly launched apps whose items macOS placed in a hidden section.
    ///
    /// macOS places new items on the left, which is usually a hidden section.
    /// Launched apps are allowed until their items appear, so they're never
    /// hidden by mistake, and their sections are then read from their items.
    private func classifyLaunchedApps(_ bundleIdentifiers: Set<String>) {
        let launched = bundleIdentifiers.subtracting(Self.systemItemOwners)
        guard !launched.isEmpty else {
            return
        }
        Task { [weak self] in
            var pending = launched
            // An app's item may take a while to appear after launch.
            for delay in [0.5, 1, 2, 4, 8] {
                try? await Task.sleep(for: .seconds(delay))
                guard
                    let self,
                    assertion != nil,
                    layout != nil,
                    let appState,
                    let hiddenFrame = appState.menuBarManager.section(withName: .hidden)?.controlItem.windowFrame
                else {
                    return
                }
                let alwaysHiddenFrame = appState.settingsManager.advancedSettingsManager.enableAlwaysHiddenSection
                    ? appState.menuBarManager.section(withName: .alwaysHidden)?.controlItem.windowFrame
                    : nil
                let apps = NSWorkspace.shared.runningApplications.compactMap { app -> (pid_t, String)? in
                    guard let bundleIdentifier = app.bundleIdentifier, pending.contains(bundleIdentifier) else {
                        return nil
                    }
                    return (app.processIdentifier, bundleIdentifier)
                }
                let target = Self.captureTarget(for: appState.menuBarManager.section(withName: .hidden)?.controlItem.window?.screen)
                let (inventory, images) = await Task.detached(priority: .userInitiated) {
                    let inventory = Self.inventory(of: apps)
                    return (inventory, await Self.captureImages(of: inventory, target: target))
                }.value
                let launchedRecords = Self.records(for: inventory, images: images, scale: target?.scale ?? 1)
                    .filter { $0.frame.minX >= 0 && pending.contains($0.bundleIdentifier) }
                self.itemRecords.removeAll { record in launchedRecords.contains { $0.bundleIdentifier == record.bundleIdentifier } }
                self.itemRecords.append(contentsOf: launchedRecords)
                var changed = false
                // Items that aren't drawn report a negative position.
                for item in inventory where item.frame.minX >= 0 && pending.contains(item.bundleIdentifier) {
                    let section = Self.section(
                        of: item.frame,
                        hiddenFrame: hiddenFrame,
                        alwaysHiddenFrame: alwaysHiddenFrame
                    )
                    let current = self.layout?.sections[item.bundleIdentifier]
                    self.layout?.sections[item.bundleIdentifier] = current.map { Self.mostVisible($0, section) } ?? section
                    pending.remove(item.bundleIdentifier)
                    changed = true
                }
                if changed {
                    Logger.nativeVisibility.info("Read sections of launched apps: \(launched.sorted())")
                    update()
                }
                if pending.isEmpty {
                    return
                }
            }
        }
    }

    /// Tries again shortly, until the update succeeds or the state changes.
    private func scheduleRetry() {
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else {
                return
            }
            self?.update()
        }
    }

    /// Reads the current layout, or returns the cached one if items are
    /// currently hidden.
    private func withLayout(alwaysHiddenEnabled: Bool, body: @escaping (Layout?) -> Void) {
        if assertion != nil || usesCachedLayoutOnce, let layout {
            usesCachedLayoutOnce = false
            return body(layout)
        }
        usesCachedLayoutOnce = false
        guard
            let appState,
            hasReadLayout || Date().timeIntervalSince(lastControlItemMove) >= 1,
            let iceIconFrame = appState.menuBarManager.section(withName: .visible)?.controlItem.windowFrame,
            let hiddenFrame = appState.menuBarManager.section(withName: .hidden)?.controlItem.windowFrame,
            // The control items are always ordered with the Ice icon on the right.
            hiddenFrame.maxX <= iceIconFrame.minX + 1
        else {
            return body(nil)
        }
        let alwaysHiddenFrame: CGRect?
        if alwaysHiddenEnabled {
            guard
                let frame = appState.menuBarManager.section(withName: .alwaysHidden)?.controlItem.windowFrame,
                frame.maxX <= hiddenFrame.minX + 1
            else {
                return body(nil)
            }
            alwaysHiddenFrame = frame
        } else {
            alwaysHiddenFrame = nil
        }

        generation += 1
        let generation = generation

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let apps = NSWorkspace.shared.runningApplications.compactMap { app -> (pid_t, String)? in
            guard
                app.processIdentifier != ownPID,
                app.bundleURL?.pathExtension == "app",
                let bundleIdentifier = app.bundleIdentifier,
                !Self.systemItemOwners.contains(bundleIdentifier)
            else {
                return nil
            }
            return (app.processIdentifier, bundleIdentifier)
        }

        let captureTarget = Self.captureTarget(for: appState.menuBarManager.section(withName: .hidden)?.controlItem.window?.screen)

        Task.detached(priority: .userInitiated) {
            let inventory = Self.inventory(of: apps)
            let images = await Self.captureImages(of: inventory, target: captureTarget)
            await MainActor.run { [weak self] in
                guard let self, generation == self.generation else {
                    return
                }
                var layout = Layout()
                for item in inventory {
                    let section = Self.section(
                        of: item.frame,
                        hiddenFrame: hiddenFrame,
                        alwaysHiddenFrame: alwaysHiddenFrame
                    )
                    let current = layout.sections[item.bundleIdentifier]
                    layout.sections[item.bundleIdentifier] = current.map { Self.mostVisible($0, section) } ?? section
                }
                Logger.nativeVisibility.info(
                    """
                    Read layout with hidden divider at \(hiddenFrame.midX): visible \(layout.bundles(in: [.visible])), \
                    hidden \(layout.bundles(in: [.hidden])), \
                    always-hidden \(layout.bundles(in: [.alwaysHidden]))
                    """
                )
                self.layout = layout
                self.itemRecords = Self.records(for: inventory, images: images, scale: captureTarget?.scale ?? 1)
                hasReadLayout = true
                lastWarning = nil
                body(layout)
            }
        }
    }

    /// Hides the given apps' items. Every other running app stays allowed, so
    /// apps that couldn't be read are never hidden by mistake.
    ///
    /// The new restriction is activated before the old one is dropped, so
    /// switching between restrictions never flashes the whole menu bar.
    private func activate(hiding hiddenBundles: [String]) {
        generation += 1
        let generation = generation
        let hidden = Set(hiddenBundles).subtracting([Constants.bundleIdentifier]).subtracting(temporarilyShown)
        let running = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        let allowed = Set(running + [Constants.bundleIdentifier]).subtracting(hidden).sorted()
        MenuBarClientCore.activate(
            allowedSystemItems: Self.systemItemsToKeep,
            allowedBundleIdentifiers: allowed
        ) { [weak self] result in
            guard let self, generation == self.generation else {
                if case .success(let stale) = result {
                    stale.invalidate()
                }
                return
            }
            switch result {
            case .success(let newAssertion):
                let old = assertion
                assertion = newAssertion
                old?.invalidate()
                Logger.nativeVisibility.debug("Hid items of \(hidden.sorted())")
            case .failure(let error):
                // Never leave items hidden after an error.
                Logger.nativeVisibility.error("Failed to hide menu bar items: \(error.localizedDescription)")
                releaseAssertion()
            }
        }
    }

    private func releaseAssertion() {
        generation += 1
        assertion?.invalidate()
        assertion = nil
    }

    /// The bundle identifiers of the apps whose items are in the given section,
    /// as of the most recent layout read.
    func bundleIdentifiers(in section: MenuBarSection.Name) -> [String] {
        layout?.bundles(in: [section]) ?? []
    }

    // MARK: Clock

    /// Passes a click on the clock on to it while items are hidden.
    ///
    /// The restriction is the one behind assessment mode, which blocks
    /// Notification Center, so a click on the clock does nothing while items
    /// are hidden. The restriction is lifted, the click is made again, and the
    /// restriction comes back as soon as Notification Center opens or closes,
    /// which it stays through. Other system items open while items are hidden.
    func handleLeftMouseDown(at point: CGPoint) {
        guard
            assertion != nil,
            !isPassingClockClick,
            Self.systemItemIdentifier(at: point) == "com.apple.menuextra.clock"
        else {
            return
        }
        isPassingClockClick = true
        Task { [weak self] in
            guard let self else {
                return
            }
            let wasOpen = Self.isNotificationCenterOpen()
            releaseAssertion()
            // Let the original click finish and the restriction lift.
            try? await Task.sleep(for: .milliseconds(150))
            Self.postClick(at: point, mouseButton: .left)
            for _ in 0..<50 where Self.isNotificationCenterOpen() == wasOpen {
                try? await Task.sleep(for: .milliseconds(20))
            }
            isPassingClockClick = false
            // Nothing moved, so hide the same apps again without reading the
            // sections, keeping the hidden items' appearance short.
            usesCachedLayoutOnce = true
            update()
        }
    }

    private static func isNotificationCenterOpen() -> Bool {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.contains { window in
            (window[kCGWindowOwnerName as String] as? String) == "Notification Center" &&
            (window[kCGWindowName as String] as? String) == "Notification Center"
        }
    }

    /// Returns the identifier of the system item at the given point, in Core
    /// Graphics coordinates, e.g. "com.apple.menuextra.clock".
    private static func systemItemIdentifier(at point: CGPoint) -> String? {
        var hitElement: AXUIElement?
        guard
            AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hitElement) == .success,
            var element = hitElement
        else {
            return nil
        }
        for _ in 0..<3 {
            var identifier: CFTypeRef?
            if
                AXUIElementCopyAttributeValue(element, kAXIdentifierAttribute as CFString, &identifier) == .success,
                let identifier = identifier as? String,
                identifier.hasPrefix("com.apple.menuextra.")
            {
                return identifier
            }
            var parent: CFTypeRef?
            guard
                AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent) == .success,
                let parent,
                CFGetTypeID(parent) == AXUIElementGetTypeID()
            else {
                return nil
            }
            element = parent as! AXUIElement
        }
        return nil
    }

    // MARK: Ice Bar

    /// The records of the items in the given section, ordered from left to right.
    func itemRecords(in section: MenuBarSection.Name) -> [ItemRecord] {
        guard let layout else {
            return []
        }
        return itemRecords
            .filter { layout.sections[$0.bundleIdentifier] == section }
            .sorted { $0.frame.minX < $1.frame.minX }
    }

    /// Opens the menu of the given item, showing its app's items for a moment.
    ///
    /// A concealed item doesn't respond to Accessibility presses, so its app is
    /// allowed until the item is drawn, then the item is clicked where it
    /// appears. The app is hidden again once its menu closes. The approach and
    /// timings follow jordanbaird/Ice#1001.
    func openItem(_ record: ItemRecord, mouseButton: CGMouseButton) async {
        guard
            let app = NSRunningApplication.runningApplications(withBundleIdentifier: record.bundleIdentifier).first
        else {
            return
        }
        temporarilyShown.insert(record.bundleIdentifier)
        update()
        defer {
            temporarilyShown.remove(record.bundleIdentifier)
            update()
        }

        // A shown item is drawn 0.4–0.6 s after its app is allowed.
        var frame: CGRect?
        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(150))
            let frames = await Task.detached(priority: .userInitiated) {
                Self.inventory(of: [(app.processIdentifier, record.bundleIdentifier)])
                    .map(\.frame)
                    .filter { $0.minX >= 0 }
                    .sorted { $0.minX < $1.minX }
            }.value
            if frames.indices.contains(record.index) {
                frame = frames[record.index]
                // Wait for the menu bar to settle after the item appears.
                try? await Task.sleep(for: .milliseconds(150))
                break
            }
        }
        guard let frame else {
            Logger.nativeVisibility.warning("Item of \(record.bundleIdentifier) was not drawn in time")
            return
        }

        let baseline = Self.windowNumbers(of: app.processIdentifier)
        Self.postClick(at: CGPoint(x: frame.midX, y: frame.midY), mouseButton: mouseButton)

        // Keep the app shown while the menu or window that opened is up.
        try? await Task.sleep(for: .milliseconds(400))
        for _ in 0..<240 {
            guard !Self.windowNumbers(of: app.processIdentifier).subtracting(baseline).isEmpty else {
                break
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    private static func windowNumbers(of pid: pid_t) -> Set<Int> {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return Set(windows.compactMap { window in
            guard (window[kCGWindowOwnerPID as String] as? pid_t) == pid else {
                return nil
            }
            return window[kCGWindowNumber as String] as? Int
        })
    }

    /// Posts a click at the given point, then puts the pointer back.
    private static func postClick(at point: CGPoint, mouseButton: CGMouseButton) {
        let source = CGEventSource(stateID: .hidSystemState)
        let original = CGEvent(source: nil)?.location
        let types: [CGEventType] = mouseButton == .right ? [.rightMouseDown, .rightMouseUp] : [.leftMouseDown, .leftMouseUp]
        for type in types {
            CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: mouseButton)?
                .post(tap: .cghidEventTap)
        }
        if let original {
            CGWarpMouseCursorPosition(original)
        }
    }

    // MARK: Capture

    /// What's needed to capture a display's menu bar.
    private struct CaptureTarget: Sendable {
        let displayID: CGDirectDisplayID
        /// The menu bar's frame, in Core Graphics coordinates.
        let menuBarFrame: CGRect
        let scale: CGFloat
    }

    private static func captureTarget(for screen: NSScreen?) -> CaptureTarget? {
        guard
            CGPreflightScreenCaptureAccess(),
            let screen,
            let mainScreen = NSScreen.screens.first
        else {
            return nil
        }
        let menuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
        guard menuBarHeight > 0 else {
            return nil
        }
        // Core Graphics coordinates have their origin at the top left of the main screen.
        let menuBarFrame = CGRect(
            x: screen.frame.minX,
            y: mainScreen.frame.maxY - screen.frame.maxY,
            width: screen.frame.width,
            height: menuBarHeight
        )
        return CaptureTarget(displayID: screen.displayID, menuBarFrame: menuBarFrame, scale: screen.backingScaleFactor)
    }

    /// Captures the menu bar and cuts out an image of each item drawn on it.
    ///
    /// MenuBarAgent draws every item into one bar, so only a capture of the
    /// display holds them (as measured in jordanbaird/Ice#1001).
    private nonisolated static func captureImages(of inventory: [InventoryItem], target: CaptureTarget?) async -> [CGImage?] {
        guard let target else {
            return inventory.map { _ in nil }
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == target.displayID }) else {
                return inventory.map { _ in nil }
            }
            let configuration = SCStreamConfiguration()
            configuration.sourceRect = CGRect(origin: .zero, size: target.menuBarFrame.size)
            configuration.width = Int(target.menuBarFrame.width * target.scale)
            configuration.height = Int(target.menuBarFrame.height * target.scale)
            configuration.showsCursor = false
            let strip = try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(display: display, excludingWindows: []),
                configuration: configuration
            )
            return inventory.map { item in
                guard
                    item.frame.minX >= target.menuBarFrame.minX,
                    item.frame.maxX <= target.menuBarFrame.maxX,
                    abs(item.frame.midY - target.menuBarFrame.midY) < target.menuBarFrame.height
                else {
                    return nil
                }
                let rect = CGRect(
                    x: (item.frame.minX - target.menuBarFrame.minX) * target.scale,
                    y: 0,
                    width: item.frame.width * target.scale,
                    height: target.menuBarFrame.height * target.scale
                ).integral
                return strip.cropping(to: rect)
            }
        } catch {
            Logger.nativeVisibility.error("Failed to capture the menu bar: \(error.localizedDescription)")
            return inventory.map { _ in nil }
        }
    }

    private static func records(for inventory: [InventoryItem], images: [CGImage?], scale: CGFloat) -> [ItemRecord] {
        var records = [ItemRecord]()
        let indexed = zip(inventory, images).sorted { $0.0.frame.minX < $1.0.frame.minX }
        var counts = [String: Int]()
        for (item, image) in indexed where item.frame.minX >= 0 {
            let index = counts[item.bundleIdentifier, default: 0]
            counts[item.bundleIdentifier] = index + 1
            records.append(ItemRecord(bundleIdentifier: item.bundleIdentifier, frame: item.frame, index: index, image: image, scale: scale))
        }
        return records
    }

    // MARK: Hit Testing

    /// Returns a Boolean value that indicates whether there is a menu bar item
    /// at the given point, in Core Graphics coordinates.
    nonisolated static func isMenuBarItem(at point: CGPoint) -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        var hitElement: AXUIElement?
        guard
            AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &hitElement) == .success,
            var element = hitElement
        else {
            return false
        }
        // The hit element may be a child of the item, so check a few ancestors.
        for _ in 0..<3 {
            var subrole: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
            if (subrole as? String) == "AXMenuExtra" {
                return true
            }
            var parent: CFTypeRef?
            guard
                AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent) == .success,
                let parent,
                CFGetTypeID(parent) == AXUIElementGetTypeID()
            else {
                return false
            }
            element = parent as! AXUIElement
        }
        return false
    }

    // MARK: Layout Helpers

    private static func section(
        of frame: CGRect,
        hiddenFrame: CGRect,
        alwaysHiddenFrame: CGRect?
    ) -> MenuBarSection.Name {
        if frame.midX > hiddenFrame.midX {
            return .visible
        }
        if let alwaysHiddenFrame, frame.midX < alwaysHiddenFrame.midX {
            return .alwaysHidden
        }
        return .hidden
    }

    private static func mostVisible(_ lhs: MenuBarSection.Name, _ rhs: MenuBarSection.Name) -> MenuBarSection.Name {
        func rank(_ name: MenuBarSection.Name) -> Int {
            switch name {
            case .visible: 0
            case .hidden: 1
            case .alwaysHidden: 2
            }
        }
        return rank(lhs) <= rank(rhs) ? lhs : rhs
    }

    /// Returns other apps' status items, read through each app's
    /// `AXExtrasMenuBar`. Accessibility frames use a top-left origin, but only
    /// the horizontal position matters here, and it is the same in both.
    private nonisolated static func inventory(of apps: [(pid: pid_t, bundleIdentifier: String)]) -> [InventoryItem] {
        var items = [InventoryItem]()
        for app in apps {
            let element = AXUIElementCreateApplication(app.pid)
            // The default timeout is several seconds, so one busy app would
            // otherwise stall hiding.
            AXUIElementSetMessagingTimeout(element, 0.1)
            var barValue: CFTypeRef?
            guard
                AXUIElementCopyAttributeValue(element, "AXExtrasMenuBar" as CFString, &barValue) == .success,
                let barValue,
                CFGetTypeID(barValue) == AXUIElementGetTypeID()
            else {
                continue
            }
            var childrenValue: CFTypeRef?
            guard
                AXUIElementCopyAttributeValue(barValue as! AXUIElement, kAXChildrenAttribute as CFString, &childrenValue) == .success,
                let children = childrenValue as? [AXUIElement]
            else {
                continue
            }
            for child in children {
                if let frame = frame(of: child) {
                    items.append(InventoryItem(bundleIdentifier: app.bundleIdentifier, frame: frame))
                }
            }
        }
        return items
    }

    private nonisolated static func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
            AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
            let positionValue,
            let sizeValue
        else {
            return nil
        }
        var position = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionValue as! AXValue, .cgPoint, &position)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        return CGRect(origin: position, size: size)
    }
}

// MARK: - Logger

private extension Logger {
    static let nativeVisibility = Logger(category: "NativeVisibility")
}
