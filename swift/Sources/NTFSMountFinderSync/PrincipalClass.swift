import Foundation

/// appex 的 principal class，系统按 Info.plist 的 `NSExtensionPrincipalClass` 实例化一次并持有；其余实现都在 `NTFSFinderSync` 基类。
@objc(PrincipalClass)
public final class PrincipalClass: NTFSFinderSync, @unchecked Sendable {
    // @unchecked Sendable 需要在每个子类上重新声明 —— Swift 不会继承它。
}