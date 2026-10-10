//
//  RemoveSidebarToggle.swift
//  Ice
//

import SwiftUI

extension View {
    /// Removes the sidebar toggle button from the toolbar.
    @ViewBuilder
    func removeSidebarToggle() -> some View {
        if #available(macOS 26, *) {
            // The placeholder item below is rendered as a glass capsule that
            // covers the window buttons, preventing them from being clicked.
            toolbar(removing: .sidebarToggle)
        } else {
            toolbar(removing: .sidebarToggle)
                .toolbar {
                    Color.clear
                }
        }
    }
}
