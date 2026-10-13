import Foundation
import IOKit
import IOKit.storage

public struct DiskEntry: Sendable {
    public let identifier: String
    public let devicePath: String
    public let volumeName: String
    public let mountPoint: String?      // /Volumes/XXX，未挂载为 nil
    public let volumeUUID: String?
    public let isNTFS: Bool
    public let isFUSE: Bool
    public let isReadOnly: Bool
    public let isInternal: Bool
    public let wholeDisk: Bool
}

public struct VolumeCapacity: Sendable {
    public let total: Int64
    public let used: Int64
    public let available: Int64

    public var usedFraction: Double {
        total > 0 ? Double(used) / Double(total) : 0
    }
}

public enum DiskInventory {

    // MARK: - 挂载表

    /// 读取挂载表。用 `statfs(2)` 遍历 `/Volumes`：`getmntinfo` 的 mntent 类型在现代 SDK 中不暴露给 Swift，
    /// 而 statfs 一次调用即可同时得到挂载点、文件系统类型、来源设备与容量。
    public static func mountTable() -> [MountRecord] {
        var records: [MountRecord] = []

        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: "/Volumes") else {
            return records
        }
        records.reserveCapacity(names.count)

        for name in names {
            // 跳过 .VolumeIcon / .Trashes 之类的系统隐藏项
            guard !name.hasPrefix(".") else { continue }
            let path = "/Volumes/\(name)"

            var st = statfs()
            guard statfs(path, &st) == 0 else { continue }

            let source = fixedCString(st.f_mntfromname)
            // f_mntfromname 对 ntfs-3g(FUSE) 挂载会是 "ntfs-3g"，
            // 对系统 NTFS 只读挂载是 "/dev/diskXsY"
            records.append(MountRecord(
                devicePath: source.hasPrefix("/dev/") ? source : path,
                mountPoint: path,
                fsType: fixedCString(st.f_fstypename),
                options: mountOptions(st),
                totalBytes: Int64(st.f_blocks) * Int64(st.f_bsize),
                freeBytes: Int64(st.f_bavail) * Int64(st.f_bsize)
            ))
        }
        return records
    }

    /// 把 `statfs.f_flags` 翻译成 `mount(8)` 风格的选项串。f_flags 是位掩码，必须按位取值
    /// （`== MNT_RDONLY` 会漏判）；此选项串是 DeviceService 判定只读的唯一依据。
    static func mountOptions(_ st: statfs) -> String {
        let raw = st.f_flags
        var flags: [String] = []
        flags.append((raw & UInt32(MNT_RDONLY)) != 0 ? "ro" : "rw")
        if (raw & UInt32(MNT_SYNCHRONOUS)) != 0 { flags.append("sync") }
        if (raw & UInt32(MNT_NOEXEC)) != 0 { flags.append("noexec") }
        if (raw & UInt32(MNT_NOSUID)) != 0 { flags.append("nosuid") }
        if (raw & UInt32(MNT_NODEV)) != 0 { flags.append("nodev") }
        if (raw & UInt32(MNT_DONTBROWSE)) != 0 { flags.append("nobrowse") }
        if (raw & UInt32(MNT_AUTOMOUNTED)) != 0 { flags.append("automounted") }
        if (raw & UInt32(MNT_QUARANTINE)) != 0 { flags.append("quarantine") }
        return flags.joined(separator: ",")
    }

    /// 把 options 串切成标记集合。必须按逗号切分精确比对：子串匹配会被
    /// `nobrowse` / `automounted` 之类的词误判。
    public static func optionTokens(_ options: String) -> Set<String> {
        Set(options.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        })
    }

    /// 定长 C 字符数组字段 → String。
    static func fixedCString<T>(_ value: T) -> String {
        withUnsafeBytes(of: value) { raw in
            let buf = raw.bindMemory(to: UInt8.self)
            let len = buf.prefix(while: { $0 != 0 }).count
            return len > 0 ? String(decoding: buf[0..<len], as: UTF8.self) : ""
        }
    }

    /// 找出 ntfs-3g/FUSE 驱动的挂载记录。
    public static func fuseNTFSMounts() -> [MountRecord] {
        mountTable().filter { record in
            let t = record.fsType.lowercased()
            return t.contains("ntfs") || t.contains("fuse")
        }
    }

    // MARK: - 磁盘枚举

    /// GPT 里「Microsoft Basic Data」的分区类型 GUID。NTFS 与 exFAT 共用一个类型，
    /// 因此单看类型无法判定文件系统，必须再问一次 DiskArbitration。
    static let microsoftBasicDataGUID = "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7"

    /// 单个分区的 NTFS 判定结果。
    public enum NTFSProbe: Equatable {
        case yes
        case no
        /// 疑似 NTFS，但 DiskArbitration 的探测还没完成，稍后重来
        case pending
    }

    /// 一次分区扫描的结果。
    public struct PartitionScan: Sendable {
        public let entries: [DiskEntry]
        /// 本次扫描顺带读到的挂载表（省去调用方再单独调一次 `mountTable()`）。
        public let mountTable: [MountRecord]
        /// 本次扫描是否遇到「判定悬而未决」的分区，调用方据此安排一次延迟重扫。
        public let hasPendingProbe: Bool
    }

    /// 枚举所有 NTFS 分区（已挂载与未挂载都包含）。
    public static func enumerateNTFSPartitions() -> [DiskEntry] {
        scanNTFSPartitions().entries
    }

    /// 枚举 NTFS 分区，并报告是否存在悬而未决的判定。
    /// 必须匹配 IOMedia（介质层）而非 IOBlockStorageDriver（驱动层），只有前者带 BSD Name / Content 等属性。
    public static func scanNTFSPartitions() -> PartitionScan {
        let matching = IOServiceMatching(kIOMediaClass)
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS
        else { return PartitionScan(entries: [], mountTable: [], hasPendingProbe: false) }

        let table = mountTable()
        var results: [DiskEntry] = []
        var pending = false

        // DiskArbitration 查询要过一次进程间通信，同一次扫描里同一设备只查一遍。
        var daCache: [String: [String: Any]?] = [:]
        func daDescription(_ name: String) -> [String: Any]? {
            if let cached = daCache[name] { return cached }
            let value = DiskArbiter.description(forBSDName: name)
            daCache[name] = value
            return value
        }

        // io_service_t 是 UInt32，不能写 `while case let entry = service`（对任意值都成立，
        // 迭代器耗尽后 service == 0 会死循环），必须显式判零。
        var service = IOIteratorNext(iter)
        while service != 0 {
            let entry = service
            service = IOIteratorNext(iter)
            defer { IOObjectRelease(entry) }

            guard let bsdName = stringProperty(entry, "BSD Name") else { continue }

            let content = stringProperty(entry, "Content")
            let hint = stringProperty(entry, "Content Hint")

            // 只有分区类型位给不出答案时才去问 DiskArbitration
            let probe: NTFSProbe
            if needsVolumeProbe(content: content, contentHint: hint) {
                let kind = DiskArbiter.string(DiskArbiter.Key.volumeKind,
                                              in: daDescription(bsdName))
                probe = classifyNTFS(content: content, contentHint: hint, volumeKind: kind)
            } else {
                probe = classifyNTFS(content: content, contentHint: hint, volumeKind: nil)
            }

            if probe == .pending { pending = true }
            guard probe == .yes else { continue }

            let path = "/dev/\(bsdName)"
            let record = table.first { $0.devicePath == path }
            let desc = daDescription(bsdName)
            let options = record?.options ?? "ro"

            results.append(DiskEntry(
                identifier: bsdName,
                devicePath: path,
                volumeName: displayName(record: record, node: entry,
                                        description: desc, fallback: bsdName),
                mountPoint: record?.mountPoint,
                volumeUUID: DiskArbiter.uuidString(DiskArbiter.Key.volumeUUID, in: desc)
                            ?? stringProperty(entry, "UUID"),
                isNTFS: true,
                isFUSE: record?.isFUSEMount ?? false,
                // 没出现在挂载表里就谈不上可写
                isReadOnly: optionTokens(options).contains("ro") || record == nil,
                isInternal: DiskArbiter.bool(DiskArbiter.Key.deviceInternal, in: desc) ?? false,
                wholeDisk: intProperty(entry, "Whole") == 1
            ))
        }
        IOObjectRelease(iter)

        return PartitionScan(entries: results, mountTable: table, hasPendingProbe: pending)
    }

    /// 分区类型位自身能给出答案时（`Content` 含 NTFS 或 Apple 自有类型），不必多花一次 DiskArbitration 往返。
    public static func needsVolumeProbe(content: String?, contentHint: String?) -> Bool {
        if contentMentionsNTFS(content) || contentMentionsNTFS(contentHint) { return false }

        // Microsoft Basic Data 是唯一「必须探测」的类型：NTFS 与 exFAT 共用它。
        if gptType(content) == .microsoftBasicData { return true }
        if gptType(contentHint) == .microsoftBasicData { return true }

        // Apple 自有类型不可能装 NTFS，免探测。
        if isAppleGPTType(content) || isAppleGPTType(contentHint) { return false }

        return gptType(content) != nil || gptType(contentHint) != nil
    }

    /// Apple 自用 GPT 分区类型（APFS 容器 / 卷等）共用的注册后缀，认出来即可省掉一次 DiskArbitration 查询。
    static let appleGPTTypeSuffix = "-11AA-AA11-00306543ECAC"

    public static func isAppleGPTType(_ value: String?) -> Bool {
        value?.uppercased().hasSuffix(appleGPTTypeSuffix) ?? false
    }

    /// 判定一个分区是不是 NTFS。三条通路：Content 直接含 NTFS → Microsoft Basic Data（须看 `DAVolumeKind`）→ 其它 GPT 类型（同样看探测结果）。
    /// 只走第一条会漏掉全部 GPT 的 NTFS 盘（它们都报 Microsoft Basic Data），只走第三条则在 diskarbitrationd 尚未探测完时漏盘。
    public static func classifyNTFS(content: String?,
                                    contentHint: String?,
                                    volumeKind: String?) -> NTFSProbe {
        if contentMentionsNTFS(content) || contentMentionsNTFS(contentHint) { return .yes }

        switch gptType(content) ?? gptType(contentHint) {
        case .microsoftBasicData:
            // 探测没出结果就悬着，等下一轮 —— 这时候既不能断言是 NTFS
            // （同类型里 exFAT 很常见），也不该就此永久漏掉一块 NTFS 盘。
            guard let kind = volumeKind?.lowercased() else { return .pending }
            return kind == "ntfs" ? .yes : .no

        case .other:
            // 落在这里的多是苹果自家分区（APFS 容器 / Preboot / Recovery），
            // 标成待定会让调用方的延迟重扫永远空转。
            return volumeKind?.lowercased() == "ntfs" ? .yes : .no

        case .none:
            return .no
        }
    }

    static func contentMentionsNTFS(_ value: String?) -> Bool {
        value?.uppercased().contains("NTFS") ?? false
    }

    enum GPTType {
        /// Windows 数据分区：NTFS 与 exFAT 共用，必须进一步探测
        case microsoftBasicData
        case other
    }

    static func gptType(_ value: String?) -> GPTType? {
        guard let value else { return nil }
        let upper = value.uppercased()
        if upper == "MICROSOFT BASIC DATA" { return .microsoftBasicData }
        if upper == microsoftBasicDataGUID { return .microsoftBasicData }
        return isGUIDLike(upper) ? .other : nil
    }

    /// `Content` 是不是 GPT 分区类型 GUID（8-4-4-4-12 十六进制）；MBR 的类型名是 `Windows_NTFS` 这类词。
    static func isGUIDLike(_ value: String?) -> Bool {
        guard let value else { return false }
        let upper = value.uppercased()
        let parts = upper.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 5, parts.map(\.count) == [8, 4, 4, 4, 12] else { return false }
        let hex = CharacterSet(charactersIn: "0123456789ABCDEF")
        return parts.allSatisfy { $0.unicodeScalars.allSatisfy(hex.contains) }
    }

    /// 界面上显示的名字，优先级：挂载点目录名 → DiskArbitration 卷标 → IOMedia 介质名 → BSD 名。
    /// 挂载点目录名优先是因为它就是 Finder 里显示的名字。
    static func displayName(record: MountRecord?,
                            node: io_service_t,
                            description: [String: Any]?,
                            fallback: String) -> String {
        if let mountPoint = record?.mountPoint, mountPoint.hasPrefix("/Volumes/") {
            let name = String(mountPoint.dropFirst("/Volumes/".count))
            if !name.isEmpty { return name }
        }
        if let volumeName = DiskArbiter.string(DiskArbiter.Key.volumeName, in: description) {
            return volumeName
        }
        if let mediaName = stringProperty(node, "Media Name") {
            return mediaName
        }
        return fallback
    }

    static func stringProperty(_ service: io_service_t, _ key: String) -> String? {
        IOKitHelpers.stringProperty(service, key)
    }

    /// 从 IOKit registry 读取整数属性。IOMedia 的 `Whole` / `Leaf` 等是 CFNumber(0/1)，
    /// 不是字符串，不能用 `stringProperty` 读。
    static func intProperty(_ service: io_service_t, _ key: String) -> Int64? {
        IOKitHelpers.int64Property(service, key)
    }

    // MARK: - 容量

    /// 读取挂载点容量，`statfs` 一次系统调用完成。
    public static func capacity(ofMountPoint path: String) -> VolumeCapacity? {
        var stat = statfs()
        guard statfs(path, &stat) == 0 else { return nil }

        let blockSize = Int64(stat.f_bsize)
        let total = Int64(stat.f_blocks) * blockSize
        let free = Int64(stat.f_bavail) * blockSize
        let used = total - free

        return VolumeCapacity(total: total, used: max(0, used), available: free)
    }
}

public struct MountRecord: Sendable {
    public let devicePath: String
    public let mountPoint: String
    public let fsType: String
    public let options: String
    /// statfs 顺带返回的容量，避免为每个设备再调一次 statfs
    public let totalBytes: Int64
    public let freeBytes: Int64

    /// 是否以只读方式挂载。按标记精确比对，不做子串匹配。
    public var isReadOnly: Bool {
        DiskInventory.optionTokens(options).contains("ro")
    }

    /// 是否由 FUSE 系驱动（macFUSE + ntfs-3g）挂载。`f_fstypename` 可能是 `macfuse`、
    /// `fusefs` 或 `ntfs-3g`，三种都要认，否则会被误判成系统只读挂载。
    public var isFUSEMount: Bool {
        let t = fsType.lowercased()
        return t.contains("fuse") || t.contains("ntfs-3g") || t.contains("ntfs3g")
    }

    public var capacity: VolumeCapacity? {
        guard totalBytes > 0 else { return nil }
        return VolumeCapacity(total: totalBytes,
                              used: max(0, totalBytes - freeBytes),
                              available: freeBytes)
    }
}
