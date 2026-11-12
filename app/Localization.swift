import Foundation

enum AppLanguage: String, CaseIterable {
    case chinese = "zh-Hans", english = "en"
    // Keep language names readable even when the user chose the wrong language.
    var title: String { self == .chinese ? "简体中文":"English" }
    static func initial(defaults: UserDefaults = .standard,preferred: [String] = Locale.preferredLanguages) -> AppLanguage {
        if let raw = defaults.string(forKey:"InterfaceLanguage.v1"),let saved = AppLanguage(rawValue:raw) { return saved }
        return preferred.first?.hasPrefix("zh") == true ? .chinese:.english
    }
}

enum Localization {
    private static let lock = NSLock()
    private static var selected = AppLanguage.initial()
    private static let tables: [AppLanguage:[String:String]] = Dictionary(uniqueKeysWithValues:AppLanguage.allCases.map { language in
        var url = Bundle.main.url(forResource:"Localizable",withExtension:"strings",subdirectory:nil,localization:language.rawValue)
        // Unbundled native checks use the exact same shipped resources.
        if url == nil {
            var dir = URL(fileURLWithPath:CommandLine.arguments[0]).standardizedFileURL.deletingLastPathComponent()
            for _ in 0..<7 {
                let candidate = dir.appendingPathComponent("Resources/\(language.rawValue).lproj/Localizable.strings")
                if FileManager.default.fileExists(atPath:candidate.path) { url = candidate; break }
                dir.deleteLastPathComponent()
            }
        }
        let data = url.flatMap { try? Data(contentsOf:$0) }
        let table = data.flatMap { try? PropertyListSerialization.propertyList(from:$0,format:nil) as? [String:String] } ?? [:]
        return (language,table)
    })
    private struct Rendered { let key: String; let arguments: [String] }
    // Retain message provenance so visible errors can change language too.
    private static var rendered: [String:Rendered] = [:]
    private static var insertionOrder: [String] = []
    static var language: AppLanguage { lock.lock(); defer { lock.unlock() }; return selected }
    static func select(_ language: AppLanguage,defaults: UserDefaults = .standard) {
        lock.lock(); selected = language; lock.unlock()
        defaults.set(language.rawValue,forKey:"InterfaceLanguage.v1")
    }
    static func text(_ key: String,_ arguments: [String]) -> String {
        lock.lock(); let language = selected; lock.unlock()
        let template = tables[language]?[key] ?? key
        // One pass: argument contents must not be interpreted as placeholders.
        let pattern = try! NSRegularExpression(pattern:"\\{([0-9]+)\\}")
        let source = template as NSString
        var result = template
        for match in pattern.matches(in:template,range:NSRange(location:0,length:source.length)).reversed() {
            guard let index = Int(source.substring(with:match.range(at:1))),arguments.indices.contains(index),let range = Range(match.range,in:result) else { continue }
            result.replaceSubrange(range,with:arguments[index])
        }
        lock.lock()
        if rendered[result] == nil { insertionOrder.append(result) }
        rendered[result] = Rendered(key:key,arguments:arguments)
        if insertionOrder.count > 2048 { rendered.removeValue(forKey:insertionOrder.removeFirst()) }
        lock.unlock()
        return result
    }
    static func refresh(_ value: String) -> String { refresh(value,depth:0) }
    private static func refresh(_ value: String,depth: Int) -> String {
        guard depth < 8 else { return value }
        lock.lock(); let original = rendered[value]; lock.unlock()
        guard let original else { return value }
        return text(original.key,original.arguments.map { refresh($0,depth:depth+1) })
    }
}
func L(_ key: String,_ arguments: Any...) -> String { Localization.text(key,arguments.map { String(describing:$0) }) }
