//
//  KeepAwake.swift
//  TWZ
//
//  Settings › Connection's Keep the Mac awake: while TWZ runs, the Mac doesn't sleep when left idle,
//  so IB Gateway stays reachable from the iPhone app (TWZ-iOS). Closing the lid still sleeps it (but
//  with an external display and power). On by default.
//

import Foundation

enum KeepAwake {
    static let key = "keepMacAwake"
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }

    private static var activity: NSObjectProtocol?

    /// Holds off idle sleep while it's on, lets it go when it's off.
    static func update() {
        if isEnabled, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled],
                                                             reason: "TWZ keeps IB Gateway reachable (Settings › Connection)")
        } else if !isEnabled, let current = activity {
            ProcessInfo.processInfo.endActivity(current)
            activity = nil
        }
    }
}
