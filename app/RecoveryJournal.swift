import Foundation
import Darwin

extension CGRect {
    var recoveryArea: CGFloat { isNull || isInfinite ? 0:width*height }
}
enum RecoveryGeometry {
    enum Decision { case restore, preserveVisible, unknown }
    static func decide(actual: CGRect,owned: CGRect?,screens: [CGRect],onScreen: Bool) -> Decision {
        if let owned, abs(actual.minX-owned.minX)<2, abs(actual.minY-owned.minY)<2,
           abs(actual.width-owned.width)<2, abs(actual.height-owned.height)<2 { return .restore }
        if onScreen && screens.contains(where:{ $0.intersection(actual).recoveryArea > actual.recoveryArea*0.5 }) { return .preserveVisible }
        return .unknown
    }
}

// Hold a lock on a separate inode: atomic replacement changes the journal inode.
// Never unlink the lock while another Peek might have a descriptor referring to it.
final class RecoveryJournal {
    let url: URL
    private var fd: Int32 = -1
    private var originalBytes: Data?
    private var committed: [UUID:WindowRecovery] = [:]
    enum Issue: String, LocalizedError {
        case otherWriter, duplicateBinding, externallyChanged
        var errorDescription: String? {
            switch self {
            case .otherWriter: return L("另一个 Peek 正在管理窗口。请退出多余的副本后重试。")
            case .duplicateBinding: return L("恢复文件含重复绑定。原件已保留，窗口管理已暂停。")
            case .externallyChanged: return L("恢复文件被其他程序更改，未覆盖。请重新启动 Peek 后重试。")
            }
        }
    }
    init(url: URL) { self.url = url }
    deinit { if fd >= 0 { Darwin.close(fd) } }
    private func bytes() throws -> Data? {
        do { return try Data(contentsOf:url) }
        catch let e as NSError where e.domain == NSCocoaErrorDomain && e.code == NSFileReadNoSuchFileError { return nil }
    }
    func load() throws -> [UUID:WindowRecovery] {
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        fd = Darwin.open(url.path+".lock",O_CREAT|O_RDWR|O_CLOEXEC|O_NOFOLLOW,0o600)
        guard fd >= 0 else { throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno)) }
        guard flock(fd,LOCK_EX|LOCK_NB) == 0 else { throw Issue.otherWriter }
        originalBytes = try bytes()
        if let data = originalBytes {
            for record in try JSONDecoder().decode([WindowRecovery].self,from:data) {
                guard committed.updateValue(record,forKey:record.bindingID) == nil else { throw Issue.duplicateBinding }
            }
        }
        return committed
    }
    func checkUnchanged() throws { guard try bytes() == originalBytes else { throw Issue.externallyChanged } }
    func save(_ next: [UUID:WindowRecovery]) throws {
        guard committed != next else { return }
        try checkUnchanged()
        let data = try JSONEncoder().encode(next.values.sorted { $0.bindingID.uuidString < $1.bindingID.uuidString })
        try data.write(to:url,options:.atomic)
        committed = next; originalBytes = data
    }
}
