import Foundation

enum ApplicationRecallMethod: String {
    case unhide, reopen
    var alternative: ApplicationRecallMethod { self == .unhide ? .reopen:.unhide }
}

// Used on WindowController's worker queue. Only a confirmed recall teaches a
// preference; a failed request or nonactivating quit recovery teaches nothing.
final class ApplicationRecallMemory {
    private let defaults: UserDefaults
    private let key = "ApplicationRecallMethods.v1"
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    func preferred(for bundle: String) -> ApplicationRecallMethod {
        if let raw = defaults.dictionary(forKey:key)?[bundle] as? String,
           let method = ApplicationRecallMethod(rawValue:raw) { return method }
        // Verified compatibility default: WeChat requires the Dock-style reopen
        // event. A subsequently learned successful method takes precedence.
        return bundle == "com.tencent.xinWeChat" ? .reopen:.unhide
    }
    func remember(_ method: ApplicationRecallMethod,for bundle: String) {
        var saved = defaults.dictionary(forKey:key) as? [String:String] ?? [:]
        guard saved[bundle] != method.rawValue else { return }
        saved[bundle] = method.rawValue
        defaults.set(saved,forKey:key)
    }
}
