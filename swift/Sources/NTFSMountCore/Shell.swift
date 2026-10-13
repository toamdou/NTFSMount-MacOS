import Foundation

public struct ShellResult: Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public let timedOut: Bool

    public var succeeded: Bool { exitCode == 0 && !timedOut }
}

public enum Shell {

    /// 执行命令，带超时。超时后发送 SIGTERM，再宽限期后 SIGKILL。
    @discardableResult
    public static func run(_ launchPath: String,
                           _ arguments: [String],
                           timeout: TimeInterval = 10,
                           environment: [String: String]? = nil,
                           standardInput: String? = nil) throws -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        if let environment {
            process.environment = environment
        }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let inPipe = Pipe()
        process.standardInput = inPipe

        try process.run()

        // 先写 stdin 再等待，避免管道缓冲区填满导致死锁。
        if let standardInput {
            inPipe.fileHandleForWriting.write(Data((standardInput + "\n").utf8))
        }
        try? inPipe.fileHandleForWriting.close()

        // 异步排空 stdout/stderr，防止大输出填满管道缓冲区而阻塞进程。
        final class Box: @unchecked Sendable {
            var value = Data()
        }
        let outBox = Box()
        let errBox = Box()

        let group = DispatchGroup()
        let queue = DispatchQueue(label: "ntfsmount.shell.io", attributes: .concurrent)

        queue.async(group: group) {
            outBox.value = outPipe.fileHandleForReading.readDataToEndOfFile()
        }
        queue.async(group: group) {
            errBox.value = errPipe.fileHandleForReading.readDataToEndOfFile()
        }

        var timedOut = false
        let deadline = DispatchTime.now() + timeout
        let waiter = DispatchGroup()
        waiter.enter()
        DispatchQueue.global().async {
            process.waitUntilExit()
            waiter.leave()
        }

        if waiter.wait(timeout: deadline) == .timedOut {
            timedOut = true
            process.terminate()               // SIGTERM
            if waiter.wait(timeout: .now() + 1.0) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = waiter.wait(timeout: .now() + 1.0)
            }
        }

        group.wait()

        return ShellResult(
            exitCode: process.terminationStatus,
            stdout: String(data: outBox.value, encoding: .utf8) ?? "",
            stderr: String(data: errBox.value, encoding: .utf8) ?? "",
            timedOut: timedOut
        )
    }
}
