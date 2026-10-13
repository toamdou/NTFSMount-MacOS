import Foundation
import DiskArbitration

public enum DiskArbiter {

    public enum Key {
        public static let volumeKind   = "DAVolumeKind"
        public static let volumeName   = "DAVolumeName"
        public static let volumeUUID   = "DAVolumeUUID"
        public static let volumePath   = "DAVolumePath"
        public static let mediaName    = "DAMediaName"
        public static let mediaSize    = "DAMediaSize"
        public static let mediaRemovable = "DAMediaRemovable"
        public static let mediaEjectable = "DAMediaEjectable"
        public static let deviceInternal = "DADeviceInternal"
        public static let deviceModel  = "DADeviceModel"
        public static let deviceVendor = "DADeviceVendor"
        public static let deviceProtocol = "DADeviceProtocol"
    }

    /// 进程级共享会话：`DASessionCreate` 会连接 diskarbitrationd，不应每次查询都新建。
    /// `nonisolated(unsafe)`：DASession 非 Sendable，但查询只在主线程发起，无并发访问。
    nonisolated(unsafe) private static let session: DASession? = DASessionCreate(kCFAllocatorDefault)

    /// 读取指定 BSD 设备（`disk4s1`）的完整 DiskArbitration 描述。
    public static func description(forBSDName name: String) -> [String: Any]? {
        guard let session,
              let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, name)
        else { return nil }
        guard let raw = DADiskCopyDescription(disk) else { return nil }
        return raw as? [String: Any]
    }

    /// 卷的文件系统种类，统一转小写（`"ntfs"` / `"exfat"` / `"apfs"` …）。
    /// 返回 nil 表示无可识别文件系统，或 diskarbitrationd 尚未探测完。
    public static func volumeKind(forBSDName name: String) -> String? {
        string(Key.volumeKind, in: description(forBSDName: name))?.lowercased()
    }

    // MARK: - 描述字段取值

    public static func string(_ key: String, in description: [String: Any]?) -> String? {
        guard let value = description?[key] as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// CFBoolean / NSNumber 都要能取到值 —— plist 往返后静态类型会退化，因此两种都试。
    public static func bool(_ key: String, in description: [String: Any]?) -> Bool? {
        guard let value = description?[key] else { return nil }
        if let b = value as? Bool { return b }
        if let n = value as? NSNumber { return n.boolValue }
        return nil
    }

    public static func int64(_ key: String, in description: [String: Any]?) -> Int64? {
        guard let value = description?[key] else { return nil }
        if let n = value as? NSNumber { return n.int64Value }
        if let i = value as? Int64 { return i }
        return nil
    }

    /// `DAVolumeUUID` / `DAMediaUUID` 是 CFUUID 而非字符串。
    public static func uuidString(_ key: String, in description: [String: Any]?) -> String? {
        guard let value = description?[key] else { return nil }
        if let s = value as? String { return s }
        if CFGetTypeID(value as CFTypeRef) == CFUUIDGetTypeID() {
            let uuid = unsafeBitCast(value as CFTypeRef, to: CFUUID.self)
            return CFUUIDCreateString(kCFAllocatorDefault, uuid) as String
        }
        return nil
    }
}
