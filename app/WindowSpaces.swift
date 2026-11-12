import AppKit

// Read-only private queries: no Dock injection, Space creation/movement, or SIP
// changes. Assignment is authoritative: Mission Control/Space transitions can
// show thumbnails of windows from other desktops in the public visible list.
// Missing symbols/data stay unknown instead of allowing activation to switch.
enum WindowSpaceMembership { case current, other, unknown }
enum WindowSpaces {
    private typealias Connection = @convention(c) () -> Int32
    private typealias Displays = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias Spaces = @convention(c) (Int32,Int32,CFArray) -> Unmanaged<CFArray>?
    private static let library = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",RTLD_LAZY)
    private static func symbol<T>(_ name: String,as type: T.Type) -> T? {
        guard let library,let pointer = dlsym(library,name) else { return nil }
        return unsafeBitCast(pointer,to:type)
    }
    private static let connection = symbol("SLSMainConnectionID",as:Connection.self)
    private static let displays = symbol("SLSCopyManagedDisplaySpaces",as:Displays.self)
    private static let spaces = symbol("SLSCopySpacesForWindows",as:Spaces.self)
    static func activeSpaceIDs() -> Set<UInt64>? {
        guard let connection,let displays,
              let data = displays(connection())?.takeRetainedValue() as? [[String:Any]] else { return nil }
        let result = Set(data.compactMap { ($0["Current Space"] as? [String:Any])?["ManagedSpaceID"] as? NSNumber }.map(\.uint64Value))
        return result.isEmpty ? nil:result
    }
    static func assignedSpaceIDs(_ number: CGWindowID) -> Set<UInt64>? {
        guard let connection,let spaces,
              let data = spaces(connection(),0x7,[NSNumber(value:number)] as CFArray)?.takeRetainedValue() as? [NSNumber] else { return nil }
        let result = Set(data.map(\.uint64Value))
        return result.isEmpty ? nil:result
    }
    static func membership(_ number: CGWindowID) -> WindowSpaceMembership {
        guard let active = activeSpaceIDs(),let assigned = assignedSpaceIDs(number) else { return .unknown }
        return classify(assigned:assigned,active:active)
    }
    static func classify(assigned: Set<UInt64>,active: Set<UInt64>) -> WindowSpaceMembership {
        guard !assigned.isEmpty,!active.isEmpty else { return .unknown }
        return assigned.isDisjoint(with:active) ? .other:.current
    }
}
