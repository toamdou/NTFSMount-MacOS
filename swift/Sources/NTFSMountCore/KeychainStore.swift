import Foundation
import Security

// MARK: - 错误

public enum KeychainError: LocalizedError {
    case emptyPassword
    case unexpectedStatus(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .emptyPassword:
            return Localization.shared.t("settings.passwordEmpty")
        case .unexpectedStatus(let status):
            // 用系统自带的错误串：OSStatus 的可读描述来自 Security 框架（如 errSecAuthFailed）。
            return SecCopyErrorMessageString(status, nil) as String?
                ?? "OSStatus \(status)"
        }
    }
}

// MARK: - 存储

public final class KeychainStore: @unchecked Sendable {

    public static let shared = KeychainStore()

    private let service: String
    private let account = "sudo-admin-password"

    /// 串行化钥匙串访问。`save` 是「先删后写」两步，锁保证这两步对外原子。
    private let lock = NSLock()

    /// - Parameter service: 钥匙串条目的服务标识，默认取 bundle id（产品名会变，bundle id 稳定）。
    public init(service: String? = nil) {
        self.service = service
            ?? Bundle.main.bundleIdentifier
            ?? "com.ntfsmount.NTFSMount"
    }

    /// 条目的公共查询条件。增删查都基于它，避免三处各写一遍写歪。
    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    // MARK: - 查询

    /// 是否已有保存的密码。只查存在性，不取内容（设置页每次重绘都会调到）。
    public var hasPassword: Bool {
        lock.lock(); defer { lock.unlock() }

        var query = baseQuery
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess
    }

    /// 取回密码。没有条目、条目为空、数据不是合法 UTF-8 都返回 nil —— 调用方语义是「能否拿到可用密码」。
    public func loadPassword() -> String? {
        lock.lock(); defer { lock.unlock() }

        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let password = String(data: data, encoding: .utf8),
              !password.isEmpty
        else { return nil }
        return password
    }

    // MARK: - 写入 / 删除

    /// 保存密码（覆盖已有条目）。
    /// 原样保存不 trim：密码里的空格是密码的一部分，替用户清理会导致「输对了却报密码错误」。
    public func save(_ password: String) throws {
        guard !password.isEmpty else { throw KeychainError.emptyPassword }

        lock.lock(); defer { lock.unlock() }

        // 先删后写而非 SecItemUpdate：Update 无条目时返回 errSecItemNotFound，
        // 且旧条目 accessible 属性不同会导致更新失败；「删 + 增」语义单一且幂等。
        SecItemDelete(baseQuery as CFDictionary)

        var query = baseQuery
        query[kSecValueData as String] = Data(password.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// 删除条目。本来就不存在也视为成功 —— 幂等，便于「关闭开关」这类调用点。
    @discardableResult
    public func delete() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let status = SecItemDelete(baseQuery as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

// MARK: - 通知

public extension Notification.Name {

    /// 钥匙串里保存的密码被判定失效、并已自动删除。
    /// 由 `PrivilegedExecutor` 在「用保存的密码提权失败」时发出，设置页据此刷新状态。
    static let ntfsmountSavedPasswordInvalidated =
        Notification.Name("ntfsmount.savedPasswordInvalidated")
}
