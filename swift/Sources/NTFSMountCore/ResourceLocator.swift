import Foundation

public enum ResourceLocator {

    /// 资源在 bundle 内的子目录提示，按优先级排列。`locales` 放在最前：
    /// 若先试根目录，会加载到旧版残留文件，且不报错。
    private static let subdirectoryHints: [String?] = [
        "locales",
        "Resources/locales",
        "Resources",
        nil,
    ]

    /// 候选 bundle，去重且保持优先级：主 bundle → 类型所在 bundle →
    /// 主 bundle 同级目录下名为 `*NTFSMountCore.bundle` 的产物。
    public static func candidateBundles() -> [Bundle] {
        var out: [Bundle] = [.main, Bundle(for: ResourceLocatorToken.self)]

        let fm = FileManager.default
        var searchDirs: [URL] = []
        searchDirs.append(Bundle.main.bundleURL)
        if let res = Bundle.main.resourceURL { searchDirs.append(res) }
        if let exe = Bundle.main.executableURL { searchDirs.append(exe.deletingLastPathComponent()) }

        // 先解析符号链接再去重：`contentsOfDirectory(at:)` 在指向目录的符号链接上会失败，
        // 而 `try?` 会静默吞掉 —— 结果是一个候选 bundle 都收不到。
        var seenDirs = Set<String>()
        for raw in searchDirs {
            let dir = raw.resolvingSymlinksInPath()
            guard seenDirs.insert(dir.path).inserted else { continue }

            guard let entries = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else { continue }
            for url in entries where url.pathExtension == "bundle" {
                guard url.lastPathComponent.contains("NTFSMountCore"),
                      let bundle = Bundle(url: url) else { continue }
                out.append(bundle)
            }
        }

        var seen = Set<String>()
        return out.filter { seen.insert($0.bundlePath).inserted }
    }

    /// 定位随包资源文件；`fileName` 需带扩展名（如 `zh-CN.json`），返回第一个可读文件 URL。
    public static func locate(_ fileName: String) -> URL? {
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension

        for bundle in candidateBundles() {
            for hint in subdirectoryHints {
                if let url = bundle.url(forResource: base, withExtension: ext,
                                        subdirectory: hint) {
                    return url
                }
            }
            // 慢路径：按文件名遍历目录树，深度上限 5 层，避免在异常庞大的 bundle 里做无谓递归。
            if let root = bundle.resourceURL, let url = searchTree(root, name: fileName) {
                return url
            }
        }
        return nil
    }

    private static func searchTree(_ root: URL, name: String) -> URL? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return nil }

        for case let url as URL in enumerator {
            guard url.lastPathComponent == name else { continue }
            let depth = url.pathComponents.count - root.pathComponents.count
            if depth <= 5 { return url }
        }
        return nil
    }

    /// 资源自检：返回可加载的语言代码，供启动日志与打包脚本校验；
    /// 返回空集说明产物里没有语言包，界面会全面退化成裸 key。
    public static func availableLanguageCodes(_ codes: [String]) -> [String] {
        codes.filter { locate("\($0).json") != nil }
    }
}

private final class ResourceLocatorToken {}
