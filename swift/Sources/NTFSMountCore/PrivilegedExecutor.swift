import Foundation

public enum PrivilegeError: LocalizedError, Sendable {
    case cancelled
    case wrongPassword
    case executionFailed(String)
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .cancelled:
            return Localization.shared.t("passwordDialog.userCancelled")
        case .wrongPassword:
            return Localization.shared.t("messages.passwordError")
        case .timedOut:
            return Localization.shared.t("messages.operationTimeout")
        case .executionFailed(let msg):
            return msg
        }
    }
}

public final class PrivilegedExecutor: Sendable {

    public static let shared = PrivilegedExecutor()

    private init() {}

    // MARK: - 偏好开关

    /// 是否优先使用钥匙串里保存的管理员密码（仅表示用户意图，还需钥匙串确有密码）。
    private final class PreferenceBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        var flag: Bool {
            get { lock.lock(); defer { lock.unlock() }
                  return value }
            set { lock.lock(); defer { lock.unlock() }
                  value = newValue }
        }
    }

    private let preference = PreferenceBox()

    public var prefersSavedPassword: Bool {
        get { preference.flag }
        set { preference.flag = newValue }
    }

    // MARK: - 路径 0：按偏好自动选择（首选入口）

    /// 提权首选入口：按偏好选系统授权框或密码路径；密码被拒时删除失效条目并回退系统授权框。
    public func executePrivileged(_ executable: String,
                                  _ arguments: [String]) async throws -> ShellResult {
        guard prefersSavedPassword,
              let saved = KeychainStore.shared.loadPassword() else {
            return try await execute(executable, arguments)
        }

        do {
            return try await executeWithPassword(executable, arguments, password: saved)
        } catch PrivilegeError.wrongPassword {
            KeychainStore.shared.delete()
            NotificationCenter.default.post(name: .ntfsmountSavedPasswordInvalidated,
                                            object: nil)
            return try await execute(executable, arguments)
        }
    }

    // MARK: - 路径 1：系统原生授权（推荐）

    /// 以管理员权限执行命令：弹系统授权对话框；`executable` 须为绝对路径。
    public func execute(_ executable: String, _ arguments: [String]) async throws -> ShellResult {
        let joined = ([executable] + arguments).map(Self.shellQuote).joined(separator: " ")
        let script = "do shell script \"\(Self.appleScriptEscape(joined))\" with administrator privileges"

        let result: ShellResult
        do {
            result = try Shell.run("/usr/bin/osascript", ["-e", script], timeout: 180)
        } catch {
            throw PrivilegeError.executionFailed(error.localizedDescription)
        }

        if result.timedOut { throw PrivilegeError.timedOut }

        if result.succeeded {
            return ShellResult(exitCode: 0,
                               stdout: result.stdout,
                               stderr: result.stderr,
                               timedOut: false)
        }

        let combined = (result.stderr + " " + result.stdout).lowercased()
        // osascript 用户取消返回 -128 ("User canceled.")
        if result.exitCode == -128
            || combined.contains("user canceled")
            || combined.contains("user cancelled")
            || combined.contains("-128") {
            throw PrivilegeError.cancelled
        }
        throw PrivilegeError.executionFailed(
            result.stderr.isEmpty ? result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                                  : result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    // MARK: - 路径 2：sudo + 密码

    /// 用明文密码执行 sudo；密码经 stdin 管道传入，绝不出现在命令行。
    public func executeWithPassword(_ executable: String,
                                   _ arguments: [String],
                                   password: String) async throws -> ShellResult {
        guard !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PrivilegeError.wrongPassword
        }

        // sudo -S 从 stdin 读密码；-k 忽略缓存时间戳，保证每次都实际校验密码。
        let sudoArgs: [String] = ["-S", "-k", "-p", ""] + [executable] + arguments

        let result: ShellResult
        do {
            result = try Shell.run("/usr/bin/sudo", sudoArgs,
                                   timeout: 60,
                                   standardInput: password)
        } catch {
            throw PrivilegeError.executionFailed(error.localizedDescription)
        }

        if result.timedOut { throw PrivilegeError.timedOut }

        if result.succeeded {
            return result
        }

        let combined = (result.stderr + " " + result.stdout).lowercased()
        let passwordMarkers = [
            "password is incorrect", "sorry, try again",
            "incorrect password", "wrong password",
            "authentication failure", "密码错误", "密码不正确",
            "パスワードが間違っています",
        ]
        if passwordMarkers.contains(where: { combined.contains($0) }) {
            throw PrivilegeError.wrongPassword
        }
        let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        throw PrivilegeError.executionFailed(detail.isEmpty ? result.stdout : detail)
    }

    // MARK: - 转义

    /// POSIX shell 单引号转义。
    public static func shellQuote(_ s: String) -> String {
        let needsQuote = s.isEmpty || s.contains { ch in
            ch == " " || ch == "\t" || ch == "\n" ||
            ch == "'" || ch == "\"" || ch == "\\" ||
            ch == "$" || ch == "`" || ch == "&" || ch == "|" ||
            ch == ";" || ch == "<" || ch == ">" || ch == "(" ||
            ch == ")" || ch == "*" || ch == "?" || ch == "[" ||
            ch == "]" || ch == "#" || ch == "~" || ch == "="
        }
        guard needsQuote else { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
