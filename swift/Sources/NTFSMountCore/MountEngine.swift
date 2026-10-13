import Foundation

public enum MountError: LocalizedError {
    case macFUSEUnavailable
    case ntfs3gNotFound
    case ntfs3gInvalidPath(String)
    case alreadyReadWrite(String)
    case dirtyNTFS
    case failed(String)
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .macFUSEUnavailable:
            return Localization.shared.t("mount.error.macfuseMissing")
        case .ntfs3gNotFound:
            return Localization.shared.t("mount.error.ntfs3gNotFound")
        case .ntfs3gInvalidPath(let p):
            return Localization.shared.t("mount.error.invalidPath", ["name": p])
        case .alreadyReadWrite(let name):
            return Localization.shared.t("mount.alreadyReadWrite", ["name": name])
        case .dirtyNTFS:
            return Localization.shared.t("mount.error.dirtyNTFS")
        case .timedOut:
            return Localization.shared.t("mount.error.timeout")
        case .failed(let m):
            return m
        }
    }
}

public final class MountEngine: Sendable {

    public static let shared = MountEngine()

    private let privilege = PrivilegedExecutor.shared
    private init() {}

    // MARK: - 路径解析

    /// 定位 ntfs-3g，处理 macOS 11+ firmlink。
    public func resolveNTFS3G() throws -> String {
        guard let path = ToolLocator.locate("ntfs-3g") else {
            throw MountError.ntfs3gNotFound
        }
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw MountError.ntfs3gInvalidPath(path)
        }
        return path
    }

    /// 定位 umount。Intel 系统自带 /sbin/umount；MacPorts/Homebrew 可能有 nmount。
    private func resolveUmount() -> (executable: String, prefixArgs: [String]) {
        if let nmount = ToolLocator.locate("nmount") {
            return (nmount, [])           // ntfs-3g 官方推荐 nmount，支持 -t
        }
        return ("/sbin/umount", [])
    }

    // MARK: - 挂载

    /// 挂载前置检查：缺依赖时提前抛错，否则连授权弹窗都走不到，用户只看到「点了没反应」。
    private func preflight() throws {
        let status = DependencyDetector().detect()
        // macFUSE 先查：没有它 ntfs-3g 即使存在也挂不上。
        if !status.macFUSE { throw MountError.macFUSEUnavailable }
        if !status.ntfs3g { throw MountError.ntfs3gNotFound }
    }

    public func mountReadWrite(device: NTFSDevice) async throws {
        try preflight()

        let ntfs3g = try resolveNTFS3G()
        let mountPoint = device.volume.isEmpty ? mountPointFor(device) : device.volume

        // 已是读写模式：无需重复挂载
        if device.isReadWrite {
            // 仍需确认，避免陈旧状态
            if let record = DiskInventory.mountTable()
                .first(where: { $0.devicePath == device.devicePath }),
               !record.options.contains("ro") {
                throw MountError.alreadyReadWrite(device.volumeName)
            }
        }

        // 卸载现有（只读）挂载
        try? await forceUnmount(device: device, quiet: true)

        let arguments = MountContract.arguments(for: device, mountPoint: mountPoint)

        do {
            let result = try await privilege.executePrivileged(ntfs3g, arguments)
            guard result.succeeded else {
                throw MountError.failed(Self.diagnose(stderr: result.stderr,
                                                       stdout: result.stdout))
            }
        } catch let error as MountError {
            throw error
        } catch let error as PrivilegeError {
            switch error {
            case .timedOut:
                throw MountError.timedOut
            default:
                throw MountError.failed(error.errorDescription ?? "")
            }
        }

        // 挂载点可能不存在（例如设备从未被系统挂载过），确保存在
        if !FileManager.default.fileExists(atPath: mountPoint) {
            try? FileManager.default.createDirectory(
                atPath: mountPoint,
                withIntermediateDirectories: true)
        }

        DiskInventory.invalidateCache()
    }

    public func forceUnmount(device: NTFSDevice, quiet: Bool = false) async throws {
        let (umount, prefix) = resolveUmount()
        var arguments = prefix + ["-f", device.devicePath]
        if umount.hasSuffix("nmount") {
            arguments = prefix + ["-f", "-t", "ntfs-3g", device.devicePath]
        }
        do {
            let result = try await privilege.executePrivileged(umount, arguments)
            if !result.succeeded && !quiet {
                // nmount 退出码非 0：多数情况下仍已被 DiskArbitration 卸载成功，
                // 但不能假设 —— 用 diskutil 幂等地再确认一次
                try? await executeDiskutil("unmount", "force", device.devicePath)
            }
        } catch {
            if quiet { return }
            // 回退到 diskutil（不需要单独的 umount 路径）
            try? await executeDiskutil("unmount", "force", device.devicePath)
        }
        DiskInventory.invalidateCache()
    }

    // MARK: - 卸载 / 还原只读 / 推出

    /// 卸载设备（FUSE 卸载为只读或直接消失）。
    public func unmount(device: NTFSDevice) async throws {
        try await forceUnmount(device: device, quiet: false)
        try? await executeDiskutil("unmount", "force", device.devicePath)
        DiskInventory.invalidateCache()
    }

    /// 还原为系统默认的只读挂载。
    public func restoreToReadOnly(device: NTFSDevice) async throws {
        try await forceUnmount(device: device, quiet: true)
        // diskutil mount 对 NTFS 默认以系统内置驱动只读挂载
        try? await executeDiskutil("mount", device.devicePath)
        DiskInventory.invalidateCache()
    }

    /// 推出设备（完全断开）。
    public func eject(device: NTFSDevice) async throws {
        try await executeDiskutil("eject", device.devicePath)
        DiskInventory.invalidateCache()
    }

    /// 重置设备：卸载 + ntfsfix 修复 + 重挂载，用于解决 "Resource busy" 与 hiberfile 脏状态。
    public func reset(device: NTFSDevice) async throws {
        try? await forceUnmount(device: device, quiet: true)
        try? await executeDiskutil("unmount", device.devicePath)

        guard let ntfsfix = ToolLocator.locate("ntfsfix") else {
            throw MountError.failed(Localization.shared.t("mount.error.ntfsfixMissing"))
        }
        let result = try await privilege.executePrivileged(ntfsfix, ["-d", device.devicePath])
        guard result.succeeded else {
            throw MountError.failed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }

        try? await executeDiskutil("mount", device.devicePath)
        DiskInventory.invalidateCache()
    }

    // MARK: - 辅助

    /// 非特权 diskutil 操作（推出/只读挂载）普通用户即可执行，无需授权对话框。
    private func executeDiskutil(_ args: String...) async throws {
        try await executeDiskutil(args)
    }

    private func executeDiskutil(_ args: [String]) async throws {
        guard let diskutil = ToolLocator.locate("diskutil") ?? optional("/usr/sbin/diskutil")
        else { throw MountError.failed("diskutil not found") }

        do {
            // eject / unmount / mount 对外部介质通常无需 root，先直接尝试
            let result = try Shell.run(diskutil, args, timeout: 30)
            if result.succeeded { return }

            // 失败再走提权路径（若开了「保存管理员密码」，这里不会弹框）
            let privileged = try await privilege.executePrivileged(diskutil, args)
            guard privileged.succeeded else {
                throw MountError.failed(
                    privileged.stderr.isEmpty ? privileged.stdout : privileged.stderr)
            }
        } catch let error as MountError {
            throw error
        } catch let error as PrivilegeError {
            throw MountError.failed(error.errorDescription ?? error.localizedDescription)
        } catch {
            throw MountError.failed(error.localizedDescription)
        }
    }

    private func optional(_ p: String) -> String? {
        FileManager.default.isExecutableFile(atPath: p) ? p : nil
    }

    /// 设备挂载点：优先用当前挂载点，其次按卷名推导。
    private func mountPointFor(_ device: NTFSDevice) -> String {
        if let record = DiskInventory.mountTable()
            .first(where: { $0.devicePath == device.devicePath }) {
            return record.mountPoint
        }
        return "/Volumes/\(device.volumeName)"
    }

    /// 把 ntfs-3g 的 stderr 翻译为中文指引，同时保留原始错误供日志排查。
    static func diagnose(stderr: String, stdout: String) -> String {
        let text = (stderr + " " + stdout).lowercased()

        if text.contains("windows is hibernated") || text.contains("hiberfil") {
            return Localization.shared.t("mount.error.hibernated")
        }
        if text.contains("resource busy") {
            return Localization.shared.t("mount.error.resourceBusy")
        }
        if text.contains("permission denied") || text.contains("not permitted") {
            return Localization.shared.t("mount.error.permissionDenied")
        }
        if text.contains("could not find") && text.contains("fuse") {
            return Localization.shared.t("mount.error.macfuseMissing")
        }
        // 保留原始错误供日志排查
        let raw = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty {
            return Localization.shared.t("mount.error.generic",
                                     ["name": stdout.trimmingCharacters(in: .whitespacesAndNewlines)])
        }
        return raw
    }
}
