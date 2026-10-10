//
//  NativeIceBar.swift
//  Ice
//

import SwiftUI

/// The Ice Bar's content on macOS 27, where menu bar items no longer have
/// windows of their own. Items are drawn from images cut from the menu bar
/// while they were shown, or from their app's icon when there is none.
struct NativeIceBarContentView: View {
    @ObservedObject var manager: NativeVisibilityManager

    let screen: NSScreen
    let section: MenuBarSection.Name
    let closePanel: () -> Void

    private var menuBarHeight: CGFloat {
        max(screen.frame.maxY - screen.visibleFrame.maxY, 24)
    }

    var body: some View {
        let records = manager.itemRecords(in: section)
        HStack(spacing: 0) {
            if records.isEmpty {
                Text("No hidden menu bar items")
                    .padding(.horizontal, 10)
            } else {
                ForEach(records) { record in
                    NativeIceBarItemView(record: record, height: menuBarHeight) { mouseButton in
                        closePanel()
                        Task {
                            await manager.openItem(record, mouseButton: mouseButton)
                        }
                    }
                }
            }
        }
        .frame(height: menuBarHeight)
        .padding(.horizontal, 5)
        .background(.bar, in: Capsule())
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.33), radius: 2.5)
        .padding(5)
        .fixedSize()
    }
}

private struct NativeIceBarItemView: View {
    let record: NativeVisibilityManager.ItemRecord
    let height: CGFloat
    let action: (CGMouseButton) -> Void

    private var appName: String {
        NSRunningApplication.runningApplications(withBundleIdentifier: record.bundleIdentifier).first?.localizedName
            ?? record.bundleIdentifier
    }

    var body: some View {
        content
            .frame(height: height)
            .contentShape(Rectangle())
            .overlay {
                NativeIceBarClickView(action: action)
            }
            .help(appName)
            .accessibilityLabel(appName)
            .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private var content: some View {
        if let image = record.image {
            Image(decorative: image, scale: record.scale)
        } else if let icon = NSRunningApplication.runningApplications(withBundleIdentifier: record.bundleIdentifier).first?.icon {
            Image(nsImage: icon)
                .resizable()
                .frame(width: height - 8, height: height - 8)
                .padding(.horizontal, 6)
        } else {
            Image(systemName: "questionmark.square.dashed")
                .padding(.horizontal, 6)
        }
    }
}

/// Reports left and right clicks, which SwiftUI's tap gestures can't tell apart.
private struct NativeIceBarClickView: NSViewRepresentable {
    let action: (CGMouseButton) -> Void

    final class ClickView: NSView {
        var action: ((CGMouseButton) -> Void)?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }

        override func mouseUp(with event: NSEvent) {
            action?(.left)
        }

        override func rightMouseUp(with event: NSEvent) {
            action?(.right)
        }
    }

    func makeNSView(context: Context) -> ClickView {
        let view = ClickView()
        view.action = action
        return view
    }

    func updateNSView(_ nsView: ClickView, context: Context) {
        nsView.action = action
    }
}
