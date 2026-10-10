import AppKit
import CoreGraphics
import EyesDrivenCore
import Foundation

/// Read-only snapshots of the on-screen windows and displays, in CoreGraphics
/// global coordinates (origin top-left of the main display, y down, points).
enum WindowCatalog {

    /// On-screen, non-desktop windows in front-to-back order, exactly as
    /// `CGWindowListCopyWindowInfo` returns them. Window titles are `nil`
    /// without Screen Recording permission and are never required.
    static func windows() -> [WindowInfo] {
        guard let raw = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return [] }

        var windows: [WindowInfo] = []
        windows.reserveCapacity(raw.count)

        for entry in raw {
            guard
                let id = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                let pid = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
                let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary)
            else { continue }

            windows.append(WindowInfo(
                id: id,
                pid: pid,
                appName: entry[kCGWindowOwnerName as String] as? String ?? "",
                title: entry[kCGWindowName as String] as? String,
                frame: frame,
                layer: (entry[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0,
                alpha: (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1,
                isOnScreen: (entry[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? true
            ))
        }
        return windows
    }

    /// Active displays in CoreGraphics global coordinates.
    static func displays() -> [DisplayInfo] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }

        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }

        return ids.prefix(Int(count)).map { DisplayInfo(id: $0, frame: CGDisplayBounds($0)) }
    }

    /// The frontmost layer-0 window: the first layer-0 window owned by
    /// `NSWorkspace.shared.frontmostApplication`, falling back to the first
    /// layer-0 window in the list.
    static func frontmostWindowID(in windows: [WindowInfo]) -> UInt32? {
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if let frontPID, let match = windows.first(where: { $0.layer == 0 && $0.pid == frontPID }) {
            return match.id
        }
        return windows.first(where: { $0.layer == 0 })?.id
    }
}
