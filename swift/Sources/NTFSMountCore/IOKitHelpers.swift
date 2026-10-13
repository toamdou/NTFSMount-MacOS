import Foundation
import IOKit
import IOKit.storage

public enum IOKitHelpers {

    static func stringProperty(_ service: io_service_t, _ key: String) -> String? {
        guard let cfValue = IORegistryEntryCreateCFProperty(
            service, key as CFString, kCFAllocatorDefault, 0
        ) else { return nil }
        guard let str = cfValue.takeRetainedValue() as? String else { return nil }
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 读取整数属性；IOMedia 上的布尔量是 CFNumber 的 0/1，不是 "Yes"/"No" 字符串，不能用 `stringProperty` 读。
    static func int64Property(_ service: io_service_t, _ key: String) -> Int64? {
        guard let cfValue = IORegistryEntryCreateCFProperty(
            service, key as CFString, kCFAllocatorDefault, 0
        ) else { return nil }
        let number = cfValue.takeRetainedValue()
        if let n = number as? NSNumber { return n.int64Value }
        if let i = number as? Int64 { return i }
        return nil
    }
}

public extension DiskInventory {

    /// `/dev/disk4s1` → `disk4s1`
    static func bsdName(fromPath path: String) -> String? {
        let name = path.hasPrefix("/dev/") ? String(path.dropFirst("/dev/".count)) : path
        return name.isEmpty ? nil : name
    }

    /// IOKit service → BSD 名称（disk4s1）
    static func bsdName(forIOService service: io_service_t) -> String? {
        IOKitHelpers.stringProperty(service, "BSD Name")
    }

    /// 在 IOMedia 层按设备路径找出对应节点，交给 `body` 读属性。
    /// 不用 `IOBSDNameMatching`：反正只需一次遍历，直接匹配 IOMedia 更直观。
    static func withIOMediaNode<T>(path: String, _ body: (io_service_t) -> T?) -> T? {
        guard let wanted = bsdName(fromPath: path) else { return nil }
        guard let matching = IOServiceMatching(kIOMediaClass) else { return nil }

        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iter) }

        var service = IOIteratorNext(iter)
        while service != 0 {
            let entry = service
            service = IOIteratorNext(iter)

            if IOKitHelpers.stringProperty(entry, "BSD Name") == wanted {
                let result = body(entry)
                IOObjectRelease(entry)
                return result
            }
            IOObjectRelease(entry)
        }
        return nil
    }

    // MARK: - IOKit 属性缓存

    /// 缓存容器本身是 Sendable，mutable 状态由内部锁保护。
    private static let iokitCache = IOKitPropertyCache()

    /// 读取某设备的介质属性集合（字符串化后缓存）。
    private static func iokitProperties(path: String) -> [String: String]? {
        if let cached = iokitCache.value(for: path), !cached.isEmpty {
            return cached
        }

        let props = withIOMediaNode(path: path) { node -> [String: String] in
            var out: [String: String] = [:]
            for key in ["Content", "Content Hint", "Media Name", "UUID"] {
                if let value = IOKitHelpers.stringProperty(node, key) { out[key] = value }
            }
            for key in ["Size", "Whole", "Leaf", "Removable", "Ejectable", "Writable"] {
                if let value = IOKitHelpers.int64Property(node, key) {
                    out[key] = String(value)
                }
            }
            return out
        }

        // 查不到**不要**写缓存：设备刚插入时 IOMedia 可能还没发布完，
        // 缓存空结果会让它整个进程生命周期内一直查不到。
        guard let props, !props.isEmpty else { return nil }
        iokitCache.set(props, for: path)
        return props
    }

    static func iokitContentIsNTFS(path: String) -> Bool {
        guard let content = iokitProperties(path: path)?["Content"] else { return false }
        return content.contains("NTFS")
    }

    static func iokitString(path: String, key: String) -> String? {
        iokitProperties(path: path)?[key]
    }

    /// 设备级容量（未挂载时使用），取自 IOMedia 的 `Size` 属性。
    static func deviceCapacity(path: String) -> VolumeCapacity? {
        let size = withIOMediaNode(path: path) { node in
            IOKitHelpers.int64Property(node, "Size")
        }

        // 可用空间要读文件系统的空闲块表，未挂载时拿不到，这里保守返回 0。
        guard let size, size > 0 else { return nil }
        return VolumeCapacity(total: size, used: 0, available: 0)
    }

    /// 清空 IOKit 缓存（设备插拔后调用）
    static func invalidateCache() {
        iokitCache.removeAll()
    }
}

/// 线程安全的 IOKit 属性缓存。
final class IOKitPropertyCache: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: [String: String]] = [:]

    func value(for key: String) -> [String: String]? {
        lock.lock(); defer { lock.unlock() }
        return storage[key]
    }

    func set(_ value: [String: String], for key: String) {
        lock.lock(); defer { lock.unlock() }
        storage[key] = value
    }

    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        storage.removeAll()
    }
}

// MARK: - 字节数解析

public enum ByteCountParser {
    /// 解析 `500.1 GB (500107862016 Bytes)` 这类 diskutil 风格字符串。
    public static func parse(_ s: String) -> Int64? {
        if let paren = s.range(of: #"\((\d+)\s+Bytes\)"#, options: .regularExpression) {
            let digits = s[paren].dropFirst().dropLast().split(separator: " ")
            if let value = Int(digits.first ?? "") { return Int64(value) }
        }
        let pattern = #"([\d.]+)\s*([KMGT]?B)"#
        guard let m = s.range(of: pattern, options: .regularExpression) else { return nil }
        let matched = String(s[m]).split(separator: " ")
        guard let value = Double(matched[0]) else { return nil }
        let unit = matched.count > 1 ? String(matched[1]).uppercased() : "B"

        let multiplier: Int64
        switch unit {
        case "KB": multiplier = 1024
        case "MB": multiplier = 1024 * 1024
        case "GB": multiplier = 1024 * 1024 * 1024
        case "TB": multiplier = 1024 * 1024 * 1024 * 1024
        default:   multiplier = 1
        }
        return Int64(value * Double(multiplier))
    }
}
