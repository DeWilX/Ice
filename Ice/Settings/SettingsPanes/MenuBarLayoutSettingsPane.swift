//
//  MenuBarLayoutSettingsPane.swift
//  Ice
//

import SwiftUI

struct MenuBarLayoutSettingsPane: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        if NativeVisibilityManager.isEnabled {
            nativeLayout
        } else if !ScreenCapture.cachedCheckPermissions() {
            missingScreenRecordingPermission
        } else if appState.menuBarManager.isMenuBarHiddenBySystemUserDefaults {
            cannotArrange
        } else {
            IceForm(alignment: .leading, spacing: 20) {
                header
                layoutBars
            }
        }
    }

    @ViewBuilder
    private var header: some View {
        Text("Drag to arrange your menu bar items")
            .font(.title2)

        IceGroupBox {
            AnnotationView(
                alignment: .center,
                font: .callout.bold()
            ) {
                Label {
                    Text("Tip: you can also arrange menu bar items by Command + dragging them in the menu bar")
                } icon: {
                    Image(systemName: "lightbulb")
                }
            }
        }
    }

    @ViewBuilder
    private var layoutBars: some View {
        VStack(spacing: 25) {
            ForEach(MenuBarSection.Name.allCases, id: \.self) { section in
                layoutBar(for: section)
            }
        }
    }

    /// On macOS 27, menu bar items no longer have their own windows, so they
    /// can't be captured or moved by Ice. Show the apps in each section instead.
    @ViewBuilder
    private var nativeLayout: some View {
        IceForm(alignment: .leading, spacing: 20) {
            Text("Arrange menu bar items by Command + dragging them in the menu bar")
                .font(.title2)

            IceGroupBox {
                AnnotationView(
                    alignment: .center,
                    font: .callout.bold()
                ) {
                    Label {
                        Text("Items to the left of the section divider are hidden. Hiding applies to all of an app's items at once.")
                    } icon: {
                        Image(systemName: "lightbulb")
                    }
                }
            }

            VStack(alignment: .leading, spacing: 25) {
                ForEach(MenuBarSection.Name.allCases, id: \.self) { name in
                    if
                        let section = appState.menuBarManager.section(withName: name),
                        section.isEnabled
                    {
                        nativeSectionList(for: name)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func nativeSectionList(for name: MenuBarSection.Name) -> some View {
        let apps = appState.menuBarManager.nativeVisibilityManager
            .bundleIdentifiers(in: name)
            .compactMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first }

        VStack(alignment: .leading, spacing: 4) {
            Text("\(name.displayString) Section")
                .font(.system(size: 14))
                .padding(.leading, 2)

            IceGroupBox {
                if apps.isEmpty {
                    Text("No apps")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(apps, id: \.processIdentifier) { app in
                            HStack(spacing: 8) {
                                if let icon = app.icon {
                                    Image(nsImage: icon)
                                        .resizable()
                                        .frame(width: 18, height: 18)
                                }
                                Text(app.localizedName ?? app.bundleIdentifier ?? "")
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    @ViewBuilder
    private var cannotArrange: some View {
        Text("Ice cannot arrange menu bar items in automatically hidden menu bars")
            .font(.title3)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    @ViewBuilder
    private var missingScreenRecordingPermission: some View {
        VStack {
            Text("Menu bar layout requires screen recording permissions")
                .font(.title2)

            Button {
                appState.navigationState.settingsNavigationIdentifier = .advanced
            } label: {
                Text("Go to Advanced Settings")
            }
            .buttonStyle(.link)
        }
    }

    @ViewBuilder
    private func layoutBar(for section: MenuBarSection.Name) -> some View {
        if
            let section = appState.menuBarManager.section(withName: section),
            section.isEnabled
        {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(section.name.displayString) Section")
                    .font(.system(size: 14))
                    .padding(.leading, 2)

                LayoutBar(section: section)
                    .environmentObject(appState.imageCache)
            }
        }
    }
}
