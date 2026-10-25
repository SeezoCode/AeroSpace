import AppKit
import Common

/// pids of the apps that AeroSpace natively hid (as in cmd-h) because all their windows are on invisible workspaces.
/// Windows hidden in the corner are still "visible" for macOS, so apps keep rendering them. Natively hidden apps
/// get their windows occluded, which lets them stop rendering and lets macOS App Nap them.
/// Values are the moments when hide was requested
@MainActor private var appsHiddenByAeroSpace: [pid_t: Date] = [:]

@MainActor func isHiddenByAeroSpace(_ app: MacApp) -> Bool { appsHiddenByAeroSpace[app.pid] != nil }

/// - Parameter allowHiding: Unhiding must happen before the layout (so that windows of the newly visible workspace
///   can be shown), hiding must happen after the layout (so that windows are already moved to the corner)
@MainActor func syncAppsHiddenByAeroSpace(allowHiding: Bool) {
    if !config.hideAppsOnInvisibleWorkspaces || !TrayMenuModel.shared.isEnabled {
        unhideAllAppsHiddenByAeroSpace()
        return
    }
    var pidsWithVisibleWindows: Set<pid_t> = []
    var pidsWithInvisibleWindows: Set<pid_t> = []
    for window in MacWindow.allWindows {
        let pid = window.macApp.pid
        switch window.windowParentCases {
            case .macosPopupWindowsContainer, .macosMinimizedWindowsContainer, .macosHiddenAppsWindowsContainer, .unbound:
                continue
            case .macosFullscreenWindowsContainer: // Native fullscreen windows live in their own macOS Spaces
                pidsWithVisibleWindows.insert(pid)
            case .tilingContainer, .floatingWindowsContainer:
                if window.nodeWorkspace?.isVisible != false {
                    pidsWithVisibleWindows.insert(pid)
                } else {
                    pidsWithInvisibleWindows.insert(pid)
                }
        }
    }

    for (pid, hideRequestDate) in appsHiddenByAeroSpace {
        guard let app = MacApp.allAppsMap[pid] else {
            appsHiddenByAeroSpace.removeValue(forKey: pid) // terminated
            continue
        }
        if pidsWithVisibleWindows.contains(pid) || !pidsWithInvisibleWindows.contains(pid) {
            appsHiddenByAeroSpace.removeValue(forKey: pid)
            app.nsApp.unhide()
        } else if !app.nsApp.isHidden && hideRequestDate.distance(to: .now) > 2 {
            // Somebody else unhid the app (e.g. cmd-tab). isHidden is updated asynchronously, that's why the delay
            appsHiddenByAeroSpace.removeValue(forKey: pid)
        }
    }

    if !allowHiding { return }
    let frontmostPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
    for pid in pidsWithInvisibleWindows.subtracting(pidsWithVisibleWindows) where pid != frontmostPid && appsHiddenByAeroSpace[pid] == nil {
        guard let app = MacApp.allAppsMap[pid], !app.nsApp.isHidden else { continue } // Don't touch apps hidden by the user
        // Don't trust the return value. On macOS 27, hide() hides the app but frequently returns false
        app.nsApp.hide()
        appsHiddenByAeroSpace[pid] = .now
    }
}

@MainActor func unhideAllAppsHiddenByAeroSpace() {
    for pid in appsHiddenByAeroSpace.keys {
        MacApp.allAppsMap[pid]?.nsApp.unhide()
    }
    appsHiddenByAeroSpace = [:]
}
