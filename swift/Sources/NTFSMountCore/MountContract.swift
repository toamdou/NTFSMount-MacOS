import Foundation

public enum MountContract {

    // MARK: - 必需参数

    /// 逐项取舍：
    /// - `-olocal`：不标记为本地卷会被 Finder 当网络卷，侧边栏归属与空闲自动卸载都不同。
    /// - `-oallow_other`：去掉后只有 root 能访问，桌面用户用不了；Spotlight 索引也依赖它。
    /// - `-oremove_hiberfile`：卷被 Windows 休眠时会被强制只读；开启才能删除 hiberfile 写入。
    /// - `-onoatime`：每次读都更新 inode 访问时间，是纯写放大。
    public static let requiredFlags: [String] = [
        "-olocal",
        "-oallow_other",
        "-oremove_hiberfile",
        "-onoatime",
    ]

    // MARK: - 已移除：-oauto_xattr（负优化）

    /// `-oauto_xattr` 会强制用 `._` AppleDouble 边车文件存 xattr，而 ntfs-3g 原生支持 xattr，故移除。
    public static let removedFlags: [String] = [
        "-oauto_xattr",
    ]
    public static let removedFlagsReason =
        "auto_xattr 强制用 ._ AppleDouble 存 xattr，而 ntfs-3g 原生支持 xattr"

    // MARK: - 可选实验参数（默认关闭）

    /// `-obig_writes`：macFUSE 的 `max_write` 已把写请求钳在约 32 KiB，可能是空操作，故默认不进参数集。
    public static let bigWrites = "-obig_writes"

    /// 实验性参数，默认不启用。
    public static let experimentalFlags: [String] = [
        bigWrites,
    ]

    /// 实验性开关的线程安全容器（Swift 6 不允许裸的可变全局状态）。
    public final class ExperimentalSwitch: @unchecked Sendable {
        private let lock = NSLock()
        private var _enabled = false

        public static let shared = ExperimentalSwitch()

        public var isEnabled: Bool {
            lock.lock(); defer { lock.unlock() }
            return _enabled
        }

        public func set(_ value: Bool) {
            lock.lock(); defer { lock.unlock() }
            _enabled = value
        }
    }

    /// 实验性参数是否启用。默认 false。
    public static var experimentalEnabled: Bool {
        get { ExperimentalSwitch.shared.isEnabled }
        set { ExperimentalSwitch.shared.set(newValue) }
    }

    public static var activeExperimentalFlags: [String] {
        experimentalEnabled ? experimentalFlags : []
    }

    // MARK: - macFUSE 参数

    /// `-oiosize=N`，macFUSE / libfuse 侧选项（非 ntfs-3g）；与 `backend=fskit` 互斥。
    public static var macFUSEFlags: [String] {
        guard let bytes = IOBlockSizeSwitch.shared.value.bytes else { return [] }
        return ["-oiosize=\(bytes)"]
    }

    /// 当前生效的 I/O 块大小档位。由设置页驱动，默认 1 MiB。
    public static var ioBlockSize: IOBlockSize {
        get { IOBlockSizeSwitch.shared.value }
        set { IOBlockSizeSwitch.shared.value = newValue }
    }

    /// 档位开关的线程安全容器（同 `ExperimentalSwitch`：Swift 6 不允许裸的可变全局状态）。
    public final class IOBlockSizeSwitch: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: IOBlockSize = .oneMiB

        public static let shared = IOBlockSizeSwitch()

        public var value: IOBlockSize {
            get { lock.lock(); defer { lock.unlock() }
                  return _value }
            set { lock.lock(); defer { lock.unlock() }
                  _value = newValue }
        }
    }

    // MARK: - 组装

    /// 完整挂载参数集（不含 device / mountPoint 位置参数）；顺序固定，便于回归比对。
    public static var flags: [String] {
        requiredFlags + macFUSEFlags + activeExperimentalFlags
    }

    /// 冒烟测试期望值快照；刻意写字面量，避免断言变成「自己等于自己」。
    public static var expectedFlags: [String] {
        requiredFlags + ["-oiosize=1048576"]
    }

    /// 生成实际传给 ntfs-3g 的完整 argv（尾随 device、mountPoint）。
    public static func arguments(for device: NTFSDevice,
                                 mountPoint: String) -> [String] {
        var argv = flags
        argv.append("-ovolname=\(device.volumeName)")
        argv.append(device.devicePath)
        argv.append(mountPoint)
        return argv
    }

    // MARK: - 诊断辅助

    /// 某个 `-o` 参数是否被显式写出（供 diagnose 判断报错来源）。
    public static func hasOption(_ name: String) -> Bool {
        flags.contains { $0 == "-o\(name)" }
    }
}
