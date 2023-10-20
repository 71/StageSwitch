import Foundation
import Quartz

extension NSAccessibility.Attribute {
    static let frame: Self = .init(rawValue: "AXFrame")
    static let windowsIds: Self = .init(rawValue: "AXWindowsIDs")
}

func becomeMain(id: CGWindowID, pid: pid_t) -> Bool {
    let axOwner = AXUIElementCreateApplication(pid)

    guard
        let axWindows: [AXUIElement] = axOwner.get(.windows),
        let axWindowForSelf = axWindows.first(where: { window in true })
    else {
        return false
    }

    return axWindowForSelf.set(.main, to: 1)
}

func focusWindow(id: CGWindowID, pid: pid_t) {
    // Inspired by Hammerspoon:
    // https://github.com/Hammerspoon/hammerspoon/blob/0ccc9d07641a660140d1d2f05b76f682b501a0e8/extensions/window/window.lua#L520-L521
    if becomeMain(id: id, pid: pid) {
        NSRunningApplication(processIdentifier: pid)?.activate()
    }
}

extension AXUIElement {
    func get<T>(_ attr: NSAccessibility.Attribute, as type: T.Type = T.self) -> T? {
        var result: AnyObject?

        if AXUIElementCopyAttributeValue(self, attr.rawValue as CFString, &result) != .success {
            return nil
        }

        return result as? T
    }

    func frame() -> CGRect? {
        guard let value: AnyObject = get(.frame), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var result: CGRect = .zero
        AXValueGetValue(value as! AXValue, AXValueGetType(value as! AXValue), &result)
        return result
    }

    func set(_ attr: NSAccessibility.Attribute, to value: Int) -> Bool {
        AXUIElementSetAttributeValue(self, attr.rawValue as CFString, value as CFTypeRef) == .success
    }

    func children() -> [AXUIElement] {
        get(.children) ?? []
    }

    func role() -> NSAccessibility.Role {
        .init(rawValue: get(.role) ?? NSAccessibility.Role.unknown.rawValue)
    }
}

// TODO: go through stage manager window strips, group windowIds by position, jump to any window id in group
struct StageGroup {
    let frame: CGRect
    let windowIds: [CGWindowID]

    static func all() -> [Self] {
        guard let windowManager = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.WindowManager"
        }) else { return [] }

        let axWindowManager = AXUIElementCreateApplication(windowManager.processIdentifier)
        var groups: [Self] = []

        for group in axWindowManager.children() where group.role() == .group {
            for list in group.children() where list.role() == .list {
                for button in list.children() where button.role() == .button {
                    guard
                        let frame = button.frame(),
                        let windowIds: [CGWindowID] = button.get(.windowsIds),
                        !windowIds.isEmpty
                    else { continue }

                    groups.append(.init(frame: frame, windowIds: windowIds))
                }
            }
        }

        return groups.sorted(by: { $0.frame.origin.y < $1.frame.origin.y })
    }

    func focus(nth windowIndex: Int = 0) {
        if windowIndex >= windowIds.count {
            return
        }
        let windowId = windowIds[windowIndex]

        if let window = WindowInfo(id: windowId) {
            focusWindow(id: windowId, pid: window.ownerPID)
        }
    }
}

struct WindowInfo {
    let alpha: Float32
    let isOnScreen: Bool
    let layer: Int
    let id: Int
    let ownerName: String
    let ownerPID: pid_t
    let height: Int
    let width: Int
    let x: Int
    let y: Int

    var isOwnedByWindowManager: Bool {
        ownerName == "WindowManager"
    }

    init?(properties dict: [String: AnyObject]) {
        guard let alpha = dict["kCGWindowAlpha"] as? Float32,
              let isOnScreen = dict["kCGWindowIsOnscreen"] as? Bool,
              let layer = dict["kCGWindowLayer"] as? Int,
              let id = dict["kCGWindowNumber"] as? Int,
              let ownerName = dict["kCGWindowOwnerName"] as? String,
              let ownerPID = dict["kCGWindowOwnerPID"] as? pid_t,
              let bounds = dict["kCGWindowBounds"] as? [String: AnyObject],
              let height = bounds["Height"] as? Int,
              let width = bounds["Width"] as? Int,
              let x = bounds["X"] as? Int,
              let y = bounds["Y"] as? Int else {
            return nil
        }

        self.alpha = alpha
        self.isOnScreen = isOnScreen
        self.layer = layer
        self.id = id
        self.ownerName = ownerName
        self.ownerPID = ownerPID
        self.height = height
        self.width = width
        self.x = x
        self.y = y
    }

    init?(id: CGWindowID) {
        guard let window = Self.all(.optionIncludingWindow, relativeToWindow: id).first(where: {
            $0.id == id
        }) else { return nil }

        self = window
    }

    static func all(_ option: CGWindowListOption, relativeToWindow: CGWindowID = kCGNullWindowID) -> [Self] {
        guard let windows = CGWindowListCopyWindowInfo(option, relativeToWindow) as? [CFDictionary] else { return [] }

        return windows.compactMap {
            guard let dict = $0 as? [String: AnyObject] else {
                return nil
            }
            return WindowInfo(properties: dict)
        }
    }
}

let stageGroups = StageGroup.all()

if CommandLine.arguments.count < 2 {
    for (i, stageGroup) in stageGroups.enumerated() {
        print("group #\(i):")

        for windowId in stageGroup.windowIds {
            let title = switch WindowInfo(id: windowId) {
            case .some(let window) where !window.ownerName.isEmpty:
                ": \(window.ownerName)"
            case .none, .some(_):
                ""
            }
            print("- window #\(windowId)\(title)")
        }
    }

    exit(EXIT_SUCCESS)
}

if CommandLine.arguments.count > 3 {
    print("too many arguments")
    exit(EXIT_FAILURE)
}

let rawGroupIndex = CommandLine.arguments[1]
let rawWindowIndex = CommandLine.arguments.count == 3 ? CommandLine.arguments[2] : "0"

if rawGroupIndex == "-h" || rawGroupIndex == "--help" {
    print("usage:")
    print("\t\(CommandLine.arguments[0])")
    print("\t\tprint stages on screen")
    print("usage: \(CommandLine.arguments[0]) [group]")
    print("\t\tfocus first window of nth group")
    print("usage: \(CommandLine.arguments[0]) [group] [window]")
    print("\t\tfocus nth window of nth group")

    exit(EXIT_SUCCESS)
}

guard let groupIndex = UInt(rawGroupIndex), groupIndex < stageGroups.count else {
    print("invalid group index `\(rawGroupIndex)` >= `\(stageGroups.count)`")
    exit(EXIT_FAILURE)
}

let stageGroup = stageGroups[Int(groupIndex)]

guard let windowIndex = UInt(rawWindowIndex), windowIndex < stageGroup.windowIds.count else {
    print("invalid window index `\(rawWindowIndex)` >= `\(stageGroup.windowIds.count)`")
    exit(EXIT_FAILURE)
}

stageGroup.focus(nth: Int(windowIndex))
