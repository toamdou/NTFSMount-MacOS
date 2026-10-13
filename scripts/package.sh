#!/usr/bin/env bash
# NTFSMount 打包脚本。用法见 --help。
# 注意：Universal 2 需要分别构建 arm64 与 x86_64 后用 lipo 合并。

set -euo pipefail

# ---------- 常量 ----------

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
readonly SWIFT_DIR="${REPO_ROOT}/swift"

readonly APP_NAME="NTFSMount"
readonly BUNDLE_ID="com.ntfsmount.NTFSMount"
readonly MIN_MACOS_VERSION="14.0"

# 版本号来源优先级：--version > swift/Info.plist 的 CFBundleShortVersionString > 本兜底常量
readonly FALLBACK_VERSION="1.0.0"

readonly ICON_CANDIDATES=(
  "${REPO_ROOT}/packaging/AppIcon.icns"
)

# Finder Sync 扩展（appex）。SwiftPM 无法产出 .appex bundle（入口是
# Info.plist 的 NSExtensionPrincipalClass，没有 C 的 main()），只能由
# Bazel 的 macos_extension 产出，再嵌进 Contents/PlugIns/。
readonly FINDER_EXT_DIR="${REPO_ROOT}/packaging/FinderExtension"
readonly APP_ENTITLEMENTS="${FINDER_EXT_DIR}/NTFSMount.entitlements"
readonly APPEX_ENTITLEMENTS="${FINDER_EXT_DIR}/NTFSMountFinderSync.entitlements"
readonly APPEX_NAME="NTFSMountFinderSync.appex"

# 随包提供的语言代码，与 Localization.supportedCodes 保持一致：
# 少任何一份，对应语言的界面就会退化成裸 key。
readonly LOCALE_CODES=(en zh-CN zh-TW ja de)

# ---------- 可配置项（由命令行覆盖） ----------

VERSION="${FALLBACK_VERSION}"
BUILD_ARCH=""       # 空=宿主架构；否则 arm64 / x86_64
UNIVERSAL=0
DO_SIGN=0
SIGN_IDENTITY=""
DO_DMG=0
DO_PKG=0
DO_APP_ONLY=0
OUTPUT_DIR="${REPO_ROOT}/dist"
SKIP_BUILD=0
WITH_FINDER_EXT=1          # 默认带 Finder 集成（appex）
APPEX_SRC=""              # 非空则直接用它，不再调 Bazel 重新构建

# 产物文件名后缀，由 main 依据实际构建架构填入（"-arm64" / "-x86_64" /
# "-universal" / 空）。必须贯穿 .app、.pkg、.dmg 与汇总报告，否则第二次
# 打包会**静默覆盖**第一次的产物。
ARTIFACT_SUFFIX=""

# ---------- 输出辅助 ----------

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'
else
  C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""
fi

# 日志一律走 stderr（含 log/ok/dim，不只是 warn/die）：stdout 要留给
# $(...) 回传产物路径，日志混进去会被当成路径的一部分。
log()  { printf '%s==>%s %s\n' "${C_BLUE}"   "${C_RESET}" "$*" >&2; }
ok()   { printf '%s  ✓%s %s\n' "${C_GREEN}"  "${C_RESET}" "$*" >&2; }
warn() { printf '%s  !%s %s\n' "${C_YELLOW}" "${C_RESET}" "$*" >&2; }
die()  { printf '%s  ✗%s %s\n' "${C_RED}"    "${C_RESET}" "$*" >&2; exit 1; }
dim()  { printf '%s    %s%s\n' "${C_DIM}" "$*" "${C_RESET}" >&2; }

usage() {
  cat <<'EOF'
NTFSMount 打包脚本

用法：
  scripts/package.sh [选项]

选项：
  --version <ver>     指定版本号（默认取 swift/Info.plist 的 CFBundleShortVersionString）
  --arch <arch>       构建指定架构：arm64 或 x86_64（默认宿主架构）
  --universal         构建 Universal 2（分别构建两架构后 lipo 合并）
  --sign              对 .app 签名（自动 ad-hoc，详见下方说明）
  --identity <id>     指定签名身份，配合 --sign 使用
                      例："Developer ID Application: Your Name (TEAMID)"
  --pkg               生成 .pkg 安装包
  --dmg               生成 .dmg 磁盘映像
  --app-only          只生成 .app，跳过 .pkg 与 .dmg（默认行为）
  --out <dir>         输出目录（默认 dist/）
  --skip-build        复用上次的 SwiftPM 产物，跳过 swift build
  --no-finder-ext     不打包 Finder Sync 扩展（appex）
                      默认会调 Bazel 构建 //swift:NTFSMountFinderSync 并
                      嵌入 Contents/PlugIns/。跳过则 Finder 图标徽标与
                      右键菜单不可用。
  --appex <dir>       直接用现成的 .appex 目录，跳过 Bazel 构建
  -h, --help          显示本帮助

示例：
  # 只出 .app（宿主架构，不签名）
  scripts/package.sh

  # Intel 版 .app
  scripts/package.sh --arch x86_64

  # Universal 2 + ad-hoc 签名 + .pkg + .dmg
  scripts/package.sh --universal --sign --pkg --dmg

  # 用开发者证书签名（可分发给其他机器）
  scripts/package.sh --universal --sign \
      --identity "Developer ID Application: Jane Doe (ABCDE12345)" --pkg --dmg

说明：
  · 本机必须安装 Xcode Command Line Tools（提供 swift build 与
    pkgbuild/productbuild/hdiutil）。
  · swift build 固定带 --disable-sandbox：本机 SwiftPM 嵌套沙箱不可用。
  · --sign 未指定 --identity 时使用 ad-hoc 签名（codesign --sign -），
    ad-hoc 签名只能在本机运行，无法分发给其他机器；要分发请提供
    Developer ID 证书。ad-hoc 产物仍会被 Gatekeeper 拦截。
  · .pkg 用 pkgbuild 生成组件包，再由 productbuild 套上可视化
    安装界面；postinstall 脚本负责安装收尾（修权限、刷新 LaunchServices）。
EOF
}

# ---------- 参数解析 ----------

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)   [[ $# -ge 2 ]] || die "--version 需要一个参数"; VERSION="$2"; shift 2 ;;
    --arch)      [[ $# -ge 2 ]] || die "--arch 需要一个参数"
                 BUILD_ARCH="$2"; shift 2 ;;
    --universal) UNIVERSAL=1; shift ;;
    --sign)      DO_SIGN=1; shift ;;
    --identity)  [[ $# -ge 2 ]] || die "--identity 需要一个参数"
                 SIGN_IDENTITY="$2"; DO_SIGN=1; shift 2 ;;
    --pkg)       DO_PKG=1; shift ;;
    --dmg)       DO_DMG=1; shift ;;
    --app-only)  DO_APP_ONLY=1; shift ;;
    --out)       [[ $# -ge 2 ]] || die "--out 需要一个参数"; OUTPUT_DIR="$2"; shift 2 ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    --no-finder-ext) WITH_FINDER_EXT=0; shift ;;
    --appex)      [[ $# -ge 2 ]] || die "--appex 需要一个参数"
                 APPEX_SRC="$2"; WITH_FINDER_EXT=1; shift 2 ;;
    -h|--help)   usage; exit 0 ;;
    *)           die "未知参数：$1（用 --help 查看用法）" ;;
  esac
done

[[ "${DO_APP_ONLY}" -eq 1 ]] && { DO_PKG=0; DO_DMG=0; }

# ---------- 环境校验 ----------

check_tools() {
  local missing=()
  command -v swift        >/dev/null 2>&1 || missing+=("swift")
  command -v codesign     >/dev/null 2>&1 || missing+=("codesign")
  command -v lipo         >/dev/null 2>&1 || missing+=("lipo")
  if [[ "${DO_PKG}" -eq 1 ]]; then
    command -v pkgbuild    >/dev/null 2>&1 || missing+=("pkgbuild")
    command -v productbuild >/dev/null 2>&1 || missing+=("productbuild")
  fi
  if [[ "${DO_DMG}" -eq 1 ]]; then
    command -v hdiutil     >/dev/null 2>&1 || missing+=("hdiutil")
  fi
  if [[ "${WITH_FINDER_EXT}" -eq 1 ]]; then
    command -v unzip       >/dev/null 2>&1 || missing+=("unzip")
  fi
  if [[ ${#missing[@]} -gt 0 ]]; then
    die "缺少必要工具：${missing[*]}
请先安装 Xcode Command Line Tools：xcode-select --install"
  fi
}

detect_version() {
  # 版本号的唯一事实来源是 swift/Info.plist 的 CFBundleShortVersionString。
  local plist="${SWIFT_DIR}/Info.plist"
  if [[ -f "${plist}" ]]; then
    local v
    v="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${plist}" 2>/dev/null || true)"
    if [[ -n "${v}" ]]; then
      VERSION="${v}"
      return
    fi
    warn "Info.plist 中读不到 CFBundleShortVersionString，回退到 ${FALLBACK_VERSION}"
  else
    warn "找不到 ${plist}，回退到 ${FALLBACK_VERSION}"
  fi
  VERSION="${FALLBACK_VERSION}"
}

validate_arch() {
  if [[ -n "${BUILD_ARCH}" && "${BUILD_ARCH}" != "arm64" && "${BUILD_ARCH}" != "x86_64" ]]; then
    die "--arch 只支持 arm64 或 x86_64，收到：${BUILD_ARCH}"
  fi
  if [[ "${UNIVERSAL}" -eq 1 && -n "${BUILD_ARCH}" ]]; then
    die "--universal 与 --arch 互斥（Universal 已包含两种架构）"
  fi
}

# ---------- 步骤 1：SwiftPM 构建 ----------
#
# 两个必须记住的事实：
#
# 1. `swift build` **没有** `--arch` 选项。传了会被静默忽略，两次「不同架构」
#    的构建其实都产出宿主架构，lipo 最后报 "same architectures found"。
#    跨架构编译要用 `--triple` + `--sdk`。
#
# 2. `.build/out/Products/` 下只有一份 Release 目录，不按 triple 分开，
#    构建 x86_64 会直接覆盖之前的 arm64 —— 每构建完一个架构必须立刻拷走。
#
# 交叉编译的目标 triple。最低版本与 MIN_MACOS_VERSION 保持一致。
triple_for_arch() {
  case "$1" in
    x86_64) printf '%s' "x86_64-apple-macosx${MIN_MACOS_VERSION}" ;;
    arm64)  printf '%s' "arm64-apple-macosx${MIN_MACOS_VERSION}" ;;
    *)      return 1 ;;
  esac
}

# 构建指定架构的二进制，拷贝到 ${2} 指定的目标路径。
build_arch_to() {
  local arch="$1" dest="$2"
  local -a args=(
    build
    -c release
    --disable-sandbox
    --package-path "${SWIFT_DIR}"
  )

  if [[ -n "${arch}" ]]; then
    local triple sdk
    triple="$(triple_for_arch "${arch}")" \
      || die "不支持的架构：${arch}"
    # CLT 的 MacOSX.sdk 含 arm64 与 x86_64 两个 slice，跨架构编译不需要 Rosetta。
    sdk="/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk"
    [[ -d "${sdk}" ]] || sdk="$(xcrun --show-sdk-path 2>/dev/null)" \
      || die "找不到 macOS SDK"
    args+=(--triple "${triple}" --sdk "${sdk}")
  fi

  log "swift build ${arch:+(arch=${arch} )}(release)"
  if ! (cd "${SWIFT_DIR}" && swift "${args[@]}" >/dev/null); then
    die "swift build 失败（arch=${arch:-host}）"
  fi

  local produced="${SWIFT_DIR}/.build/out/Products/Release/${APP_NAME}"
  [[ -f "${produced}" ]] || die "构建成功但未找到产物：${produced}"

  # 自检架构确实是请求的那个，避免静默产出错误架构。
  local got
  got="$(lipo -archs "${produced}" 2>/dev/null || echo "?")"
  if [[ -n "${arch}" && "${got}" != "${arch}" ]]; then
    die "架构不符：请求 ${arch}，产物实际为 ${got}（${produced}）"
  fi

  cp "${produced}" "${dest}"
  chmod +x "${dest}"
  ok "产物：${dest}  架构 ${got}"
}

# --skip-build 用：只取现有产物，不重建。
existing_bin_for_arch() {
  local arch="$1" dest="$2"
  local produced="${SWIFT_DIR}/.build/out/Products/Release/${APP_NAME}"
  [[ -f "${produced}" ]] || die "--skip-build 但找不到产物：${produced}"
  cp "${produced}" "${dest}"
  chmod +x "${dest}"
  dim "复用产物：${dest}  架构 $(lipo -archs "${dest}")"
}

# ---------- 步骤 2：组装 .app ----------

make_icon() {
  local dest="$1"
  for cand in "${ICON_CANDIDATES[@]}"; do
    if [[ -f "${cand}" ]]; then
      cp "${cand}" "${dest}"
      dim "图标：${cand}"
      return 0
    fi
  done

  # 没有现成 .icns：调 packaging/make-icon.swift 现场绘制，
  # 这样干净 clone 上打包也能得到正式图标而非系统占位图。
  local gen="${REPO_ROOT}/packaging/make-icon.swift"
  if [[ -f "${gen}" ]] && command -v swift >/dev/null 2>&1; then
    log "绘制应用图标（packaging/make-icon.swift）"
    local gen_dir
    gen_dir="$(mktemp -d)"
    local gen_icns="${gen_dir}/AppIcon.icns"
    if swift "${gen}" "${gen_icns}" >/dev/null 2>&1 && [[ -f "${gen_icns}" ]]; then
      # 固化到 packaging/ 下，后续打包直接命中上面的分支
      cp "${gen_icns}" "${ICON_CANDIDATES[0]}" 2>/dev/null || true
      cp "${gen_icns}" "${dest}"
      rm -rf "${gen_dir}"
      ok "图标已生成并缓存：${ICON_CANDIDATES[0]}"
      return 0
    fi
    rm -rf "${gen_dir}"
    warn "图标脚本执行失败，回退到系统占位图标"
  fi

  warn "未找到现成 .icns，生成占位图标"
  local tmp_iconset
  tmp_iconset="$(mktemp -d)/AppIcon.iconset"
  mkdir -p "${tmp_iconset}"
  local base="${tmp_iconset}/icon_"
  /usr/bin/sips -s format png --out "${base}512x512.png" \
    /System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericApplicationIcon.icns \
    >/dev/null 2>&1 || true
  if [[ ! -f "${base}512x512.png" ]]; then
    die "无法生成占位图标。请检查 packaging/make-icon.swift 是否存在、swift 是否可用。"
  fi
  mv "${base}512x512.png" "${base}512x512@2x.png"
  iconutil -c icns "${tmp_iconset}" -o "${dest}" 2>/dev/null \
    || cp "${base}512x512.png" "${dest}"
}

# 把构建产出的随包资源拷进 .app/Contents/Resources/（locales 与 manual）。
#
# ★ 只认 Core 的资源 bundle：手册（help.<code>.md）与语言包（*.json）都必须
#   真正进包，否则运行期会静默退化成兜底页 / 裸 key，而打包全程绿灯。
copy_resources() {
  local app="$1"
  local res_root="${app}/Contents/Resources"
  local loc_dst="${res_root}/locales"
  local man_dst="${res_root}/manual"
  mkdir -p "${loc_dst}" "${man_dst}"

  local -a candidates=(
    "${SWIFT_DIR}/.build/out/Products/Release/NTFSMount_NTFSMountCore.bundle"
    "${SWIFT_DIR}/.build/out/Products/Debug/NTFSMount_NTFSMountCore.bundle"
  )
  local src base
  for src in "${candidates[@]}"; do
    [[ -d "${src}" ]] || continue
    base="${src}/Contents/Resources/Resources"
    [[ -d "${base}/locales" ]] || base="${src}/Contents/Resources"
    if [[ -d "${base}/locales" ]]; then
      cp "${base}/locales"/*.json "${loc_dst}/"
      if [[ -d "${base}/manual" ]]; then
        cp "${base}/manual"/*.md "${man_dst}/"
      fi
      break
    fi
  done

  # 兜底：直接取源码目录（构建产物缺失、或产物里没带手册时）
  if ! compgen -G "${loc_dst}/*.json" > /dev/null \
     || ! compgen -G "${man_dst}/*.md" > /dev/null; then
    local src_res="${SWIFT_DIR}/Sources/NTFSMountCore/Resources"
    [[ -d "${src_res}/locales" ]] \
      || die "未找到语言包资源（期望 Sources/NTFSMountCore/Resources/locales/*.json）"
    [[ -d "${src_res}/manual" ]] \
      || die "未找到手册资源（期望 Sources/NTFSMountCore/Resources/manual/help.*.md）"
    cp "${src_res}/locales"/*.json "${loc_dst}/"
    cp "${src_res}/manual"/*.md "${man_dst}/"
    dim "随包资源：改从源码目录拷贝"
  fi

  validate_locales "${loc_dst}"
  validate_manual "${man_dst}"
  dim "语言包：$(ls "${loc_dst}" | tr '\n' ' ')"
  dim "使用手册：$(ls "${man_dst}" | tr '\n' ' ')"
}

# 手册健全性校验：五种语言的 help.<code>.md 必须齐全、非空、且有二级标题。
# 三种故障（缺失 / 空文件 / 无 "## "）都只在运行时表现为「手册不对」，构建期安静。
validate_manual() {
  local dir="$1"
  local code missing=() empty=() nosection=()

  for code in "${LOCALE_CODES[@]}"; do
    local f="${dir}/help.${code}.md"
    if [[ ! -f "${f}" ]]; then
      missing+=("${code}")
    elif [[ ! -s "${f}" ]]; then
      empty+=("${code}")
    elif ! grep -q '^## ' "${f}"; then
      nosection+=("${code}")
    fi
  done

  (( ${#missing[@]} == 0 )) \
    || die "使用手册不完整，缺少：${missing[*]}（目录 ${dir}）"
  (( ${#empty[@]} == 0 )) \
    || die "使用手册是空文件：${empty[*]}（目录 ${dir}）"
  (( ${#nosection[@]} == 0 )) \
    || die "使用手册没有二级标题，切不出章节：${nosection[*]}（目录 ${dir}）"

  # 章数差异过大只告警不中断：译本允许有细微出入，硬闸门交给上面的结构校验。
  local report
  report="$(for code in "${LOCALE_CODES[@]}"; do
              printf '%s:%s ' "${code}" "$(grep -c '^## ' "${dir}/help.${code}.md")"
            done)"
  dim "手册章数：${report}"
}

# 文案审计：在编译之前就拦住裸 key。
# 检查「源码引用的 key 是否都能查到」，能发现 key 拼错、动态 key 家族漏配等。
audit_localization() {
  local script="${SCRIPT_DIR}/audit-l10n.py"
  [[ -f "${script}" ]] || { warn "未找到 ${script}，跳过文案审计"; return 0; }
  if command -v python3 > /dev/null 2>&1; then
    python3 "${script}" || die "文案审计未通过（详见上方报告）"
  else
    warn "未找到 python3，跳过文案审计"
  fi
}

# 语言包健全性校验：五种语言齐全、可解析、体量相当。
# 把「文案退化」从运行期隐患变成构建期失败：缺一份语言包只会让界面全是裸 key。
validate_locales() {
  local dir="$1"
  local code missing=()
  for code in "${LOCALE_CODES[@]}"; do
    [[ -f "${dir}/${code}.json" ]] || missing+=("${code}")
  done
  (( ${#missing[@]} == 0 )) || die "语言包不完整，缺少：${missing[*]}（目录 ${dir}）"

  # 用 python3 是因为 plutil 不校验 JSON 结构，而这里要「能解析 + 规模可观测」。
  local report
  report="$(python3 - "$dir" "${LOCALE_CODES[@]}" << 'PY'
import json, sys
d, codes = sys.argv[1], sys.argv[2:]
sizes, bad = {}, []
for c in codes:
    try:
        with open(f"{d}/{c}.json", encoding="utf-8") as f:
            obj = json.load(f)
        # 按 UTF-8 字节数统计，语义与文件体积一致（中文字符数会偏低）
        sizes[c] = len(json.dumps(obj, ensure_ascii=False).encode("utf-8"))
    except Exception as e:
        bad.append(f"{c}({e})")
if bad:
    print("FAIL=" + ",".join(bad)); sys.exit(0)
lo, hi = min(sizes.values()), max(sizes.values())
print("SIZES=" + ",".join(f"{c}:{sizes[c]}" for c in codes))
print("TORATIO=" + f"{hi}/{lo}")
PY
)"

  case "${report}" in
    FAIL=*) die "语言包解析失败：${report#FAIL=}" ;;
  esac

  local sizes ratio
  sizes="$(printf '%s\n' "${report}" | grep '^SIZES=' | cut -d= -f2-)"
  ratio="$(printf '%s\n' "${report}" | grep '^TORATIO=' | cut -d= -f2-)"
  [[ -n "${sizes}" ]] || die "语言包校验未产出结果"

  dim "语言包体量：${sizes}（最大/最小 = ${ratio}）"

  # 这里刻意**不做**「体量差异过大」告警：各语言平均每条长度天差地别，
  # 按体量推断「某语言包过期」只会持续误报、淹没真实告警。真正的判据是
  # 「某 key 在某种语言里查不到」，由 scripts/audit-l10n.py 逐 key 硬校验。
}

# 生成 .app 的 Info.plist。
make_info_plist() {
  local app="$1" version="$2"
  local plist="${app}/Contents/Info.plist"

  cat > "${plist}" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>zh_CN</string>
	<key>CFBundleExecutable</key>
	<string>${APP_NAME}</string>
	<key>CFBundleIdentifier</key>
	<string>${BUNDLE_ID}</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>${APP_NAME}</string>
	<key>CFBundleDisplayName</key>
	<string>${APP_NAME}</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleShortVersionString</key>
	<string>${version}</string>
	<key>CFBundleVersion</key>
	<string>${version}</string>
	<key>LSMinimumSystemVersion</key>
	<string>${MIN_MACOS_VERSION}</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSRequiresAquaSystemAppearance</key>
	<false/>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.utilities</string>
	<key>NSAppleEventsUsageDescription</key>
	<string>${APP_NAME} 需要管理辅助进程以挂载、卸载和维护 NTFS 卷。</string>
	<key>LSUIElement</key>
	<false/>
	<key>NSSupportsAutomaticTermination</key>
	<false/>
	<key>NSSupportsSuddenTermination</key>
	<false/>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
</dict>
</plist>
PLIST_EOF

  plutil -lint "${plist}" >/dev/null || die "生成的 Info.plist 语法错误"
}

# assemble_app <目标路径> <源可执行文件>
assemble_app() {
  local app="$1" bin="$2"
  rm -rf "${app}"
  mkdir -p "${app}/Contents/MacOS" "${app}/Contents/Resources"

  cp "${bin}" "${app}/Contents/MacOS/${APP_NAME}"
  chmod +x "${app}/Contents/MacOS/${APP_NAME}"

  make_icon "${app}/Contents/Resources/AppIcon.icns"
  copy_resources "${app}"
  make_info_plist "${app}" "${VERSION}"

  printf 'APPL????' > "${app}/Contents/PkgInfo"

  if [[ "${WITH_FINDER_EXT}" -eq 1 ]]; then
    embed_finder_extension "${app}" "${APPEX_SRC:-}"
  fi

  ok ".app 组装完成：${app}"
}

# ---------- Finder Sync 扩展（appex） ----------
#
# appex 只能来自 Bazel（SwiftPM 产不出）。Bazel 的 --config=intel/arm64 决定
# appex 架构，必须与主应用一致，否则混装会让 Finder 加载扩展直接失败。

# 定位 Bazel 产出的 appex 真实路径。
# 不用 bazel-bin 软链：它只暴露最近一次构建的输出树，会读到陈旧产物。
# bazel cquery --output=files 由 Bazel 解析当次配置路径，是唯一可靠来源。
bazel_appex_path() {
  local bzl="$1" config="$2"
  (cd "${REPO_ROOT}" && "${bzl}" cquery //swift:NTFSMountFinderSync \
      "--config=${config}" --output=files 2>/dev/null) \
    | grep -E '\.(zip|appex)$' | head -n1
}

build_appex() {
  local arch="$1" out_dir="$2"

  command -v bazelisk >/dev/null 2>&1 || command -v bazel >/dev/null 2>&1 \
    || die "生成 Finder 扩展需要 bazelisk 或 bazel
可加 --no-finder-ext 跳过 Finder 集成（注意：那样 Finder 图标徽标与右键菜单不可用）"
  local bzl="bazelisk"
  command -v bazelisk >/dev/null 2>&1 || bzl="bazel"

  local config="arm64"
  [[ "${arch}" == "x86_64" ]] && config="intel"

  log "构建 Finder 扩展（appex，${config}）"
  if ! (cd "${REPO_ROOT}" && "${bzl}" build //swift:NTFSMountFinderSync "--config=${config}"); then
    die "Bazel 构建 appex 失败（${config}）
appex 是 Finder 集成的必需产物；若只想先出主应用，加 --no-finder-ext 跳过。"
  fi

  local src dest
  src="$(bazel_appex_path "${bzl}" "${config}")"
  [[ -n "${src}" ]] || die "未能定位 appex 产物（config=${config}）
cquery 没有返回 .zip/.appex 产物路径。"
  src="${REPO_ROOT}/${src}"
  dest="${out_dir}/${APPEX_NAME}"

  mkdir -p "${out_dir}"
  if [[ "${src}" == *.zip ]]; then
    # rules_apple 的 macos_extension 默认产 .zip，内含已签名 .appex
    if ! unzip -q "${src}" -d "${out_dir}"; then
      die "解压 appex 失败：${src}"
    fi
  elif [[ -d "${src}" ]]; then
    cp -R "${src}" "${dest}"
  fi

  [[ -d "${dest}" ]] || die "appex 解压后未找到目录：${dest}
（zip 内层目录名可能已变，请检查 ${src} 的实际结构）"
  local appex_bin="${dest}/Contents/MacOS/NTFSMountFinderSync"
  [[ -f "${appex_bin}" ]] \
    || die "appex 内缺少可执行文件：${appex_bin}"

  # appex 必须与主程序同架构，否则 Finder 拒绝加载；显式校验避免静默流到产物。
  local got_arch want_arch
  got_arch="$(lipo -archs "${appex_bin}" 2>/dev/null || echo unknown)"
  want_arch="${arch:-$(uname -m)}"
  if [[ "${got_arch}" != "${want_arch}" ]]; then
    die "appex 架构不符：期望 ${want_arch}，实际 ${got_arch}
（产物：${appex_bin}）
常见原因：--platforms 没用 @apple_support//platforms:darwin_* 的原始 label，
rules_apple 的 split transition 会静默回退到宿主架构。"
  fi

  ok "appex 构建完成（${got_arch}；Bazel 已签名，组装时按顺序重签）"
}

# 把 appex 放进 .app/Contents/PlugIns/ —— Finder 只加载这个位置的 appex。
embed_finder_extension() {
  local app="$1" src="$2"

  if [[ ! -d "${src}" ]]; then
    die "未找到 appex 源目录：${src}
请先构建 //swift:NTFSMountFinderSync，或加 --no-finder-ext 跳过。"
  fi
  local plugins="${app}/Contents/PlugIns"
  mkdir -p "${plugins}"
  # 显式指定目标目录名：cp -R 到已存在路径会追加 basename，源目录名不符就落错。
  cp -R "${src}" "${plugins}/${APPEX_NAME}"

  # Info.plist 的修正必须在**拷贝之后、对副本**做：
  # 顺序反了会拷进未修正的旧值，扩展注册静默失败，Finder 看不到徽标与菜单。
  local plist="${plugins}/${APPEX_NAME}/Contents/Info.plist"
  if [[ -f "${plist}" ]]; then
    local resolved_id
    resolved_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${plist}" 2>/dev/null || true)"
    if [[ -z "${resolved_id}" || "${resolved_id}" == \$* ]]; then
      /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ${BUNDLE_ID}.FinderSync" "${plist}" \
        || warn "appex CFBundleIdentifier 写入失败"
    elif [[ "${resolved_id}" != "${BUNDLE_ID}.FinderSync" ]]; then
      # Bazel 展开出了值但与主应用不同族（主应用是 ${BUNDLE_ID}）。
      # 扩展 id 必须与主应用成前缀关系，Finder 与 postinstall 都依赖这一点。
      /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ${BUNDLE_ID}.FinderSync" "${plist}" \
        || warn "appex CFBundleIdentifier 修正失败（原值 ${resolved_id}）"
      dim "appex CFBundleIdentifier：${resolved_id} → ${BUNDLE_ID}.FinderSync"
    fi
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "${plist}" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${VERSION}" "${plist}" 2>/dev/null || true
  else
    die "appex 内缺少 Info.plist：${plist}"
  fi

  printf 'XPC!!' > "${plugins}/${APPEX_NAME}/Contents/PkgInfo"

  # 交叉校验：appex 标识符必须与主应用成前缀关系，且与 postinstall 注册的
  # pluginkit -i 参数一致；任一不匹配都会让 Finder 集成静默失效。
  local appex_id app_id
  appex_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${plist}" 2>/dev/null || true)"
  app_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${app}/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "${appex_id}" != "${app_id}.FinderSync" ]]; then
    die "appex 标识符与主应用不匹配：
  主应用 = ${app_id}
  appex  = ${appex_id}
期望 appex = ${app_id}.FinderSync（postinstall 用 pluginkit -i 注册的就是这个 id）"
  fi

  ok "Finder 扩展已嵌入：Contents/PlugIns/${APPEX_NAME}（${appex_id}）"
}

# ---------- 步骤 3：签名 ----------

sign_app() {
  local app="$1"
  local identity="${SIGN_IDENTITY:--}"

  log "codesign 签名（identity=${identity}）"

  # 签名顺序必须「先内后外」：appex → 主可执行文件 → 整个 .app，反过来会
  # 破坏外层签名。不要用 --deep：它会把 entitlements 强套到内嵌二进制上，
  # 而 appex 与主 app 的 entitlements 不同。
  local -a common_args=(
    --force
    --sign "${identity}"
    --timestamp
  )
  if [[ "${identity}" != "-" ]]; then
    common_args+=(--options runtime)
  fi

  local appex="${app}/Contents/PlugIns/${APPEX_NAME}"
  if [[ -d "${appex}" ]]; then
    # FinderSync 扩展不能有 com.apple.security.elevation：
    # FIFinderSync 在设计上就是无特权进程。
    if [[ -f "${APPEX_ENTITLEMENTS}" ]]; then
      codesign "${common_args[@]}" \
        --entitlements "${APPEX_ENTITLEMENTS}" "${appex}" \
        || die "appex 签名失败：${appex}"
      dim "appex 已签名（含 app-sandbox + App Group entitlements）"
    else
      codesign "${common_args[@]}" "${appex}" \
        || die "appex 签名失败：${appex}"
      warn "未找到 ${APPEX_ENTITLEMENTS}，appex 以无 entitlements 签名
Finder 需要 App Group 才能与主应用通信，扩展将无法读写共享容器。"
    fi
  fi

  codesign "${common_args[@]}" "${app}/Contents/MacOS/${APP_NAME}" \
    || die "主可执行文件签名失败"

  local -a bundle_args=("${common_args[@]}")
  if [[ "${identity}" != "-" ]]; then
    bundle_args+=(--options runtime)
  fi
  if [[ -f "${APP_ENTITLEMENTS}" ]]; then
    bundle_args+=(--entitlements "${APP_ENTITLEMENTS}")
  fi
  if ! codesign "${bundle_args[@]}" "${app}"; then
    die "codesign 失败（identity=${identity}）
ad-hoc 签名请用 --sign 且不要指定 --identity；
Developer ID 签名请确认证书已在钥匙串中且未被吊销。"
  fi

  codesign --verify --deep --strict --verbose=2 "${app}" \
    || die "签名校验未通过：${app}"
  ok "签名完成并通过校验"
}

# ---------- 步骤 4：.pkg ----------

# postinstall 脚本：安装收尾。
# pkgbuild 的 scripts 会在安装完成后以 root 执行。
make_postinstall() {
  local path="$1"
  cat > "${path}" <<'POST_EOF'
#!/bin/bash
#
# NTFSMount 安装收尾脚本（由 Installer 以 root 身份执行）
set -euo pipefail

APP_PATH="/Applications/NTFSMount.app"

if [ ! -d "${APP_PATH}" ]; then
  echo "postinstall: 未找到 ${APP_PATH}，跳过收尾"
  exit 0
fi

# 1. 主可执行文件去掉 quarantine（若从 dmg 拖装）
if [ -f "${APP_PATH}/Contents/MacOS/NTFSMount" ]; then
  xattr -dr com.apple.quarantine "${APP_PATH}" 2>/dev/null || true
  chmod 755 "${APP_PATH}/Contents/MacOS/NTFSMount"
fi

# 2. 资源目录权限归位
if [ -d "${APP_PATH}/Contents/Resources" ]; then
  chmod -R a+rX "${APP_PATH}/Contents/Resources"
fi

# 3. 移除旧版本遗留的 LaunchAgents 副本
if [ -e "/Library/LaunchAgents/com.ntfsmount.NTFSMount.helper.plist" ]; then
  launchctl bootout system "/Library/LaunchAgents/com.ntfsmount.NTFSMount.helper.plist" 2>/dev/null || true
  rm -f "/Library/LaunchAgents/com.ntfsmount.NTFSMount.helper.plist"
fi

# 4. 注册 Finder Sync 扩展
#    装进 Contents/PlugIns/ 后 Finder 不会自动加载，需显式注册；-A 需 root。
#    失败不致命：用户仍可手动在系统设置里启用。
PLUGINKIT="/usr/bin/pluginkit"
if [ -x "${PLUGINKIT}" ]; then
  "${PLUGINKIT}" -a "${APP_PATH}/Contents/PlugIns/NTFSMountFinderSync.appex" 2>/dev/null || true
  "${PLUGINKIT}" -A -a -D -i "com.ntfsmount.NTFSMount.FinderSync" 2>/dev/null || true
fi

# 5. 刷新 LaunchServices，让新 app 立即出现在程序库
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [ -x "${LSREGISTER}" ]; then
  "${LSREGISTER}" -f "${APP_PATH}" 2>/dev/null || true
fi

touch "${APP_PATH}"

echo "postinstall: ${APP_PATH} 收尾完成"
exit 0
POST_EOF
  chmod +x "${path}"
}

# 生成 Distribution 描述文件（productbuild 用，决定安装界面文案）。
# 关键：最后的 <pkg-ref> 必须带子元素正文；写成裸 <pkg-ref id="..."/> 时
# productbuild 不报错却产出只有 Distribution 与 Resources 的空壳 pkg。
make_distribution() {
  local path="$1" version="$2" pkg_id="$3"

  # hostArchitectures 必须与包内真实架构一致：声明双架构而实际单架构时，
  # 架构不符的机器照样能装，装完启动才报错 —— 把错误推迟到用户侧。
  local host_archs
  case "${ARTIFACT_SUFFIX}" in
    -arm64)   host_archs="arm64" ;;
    -x86_64)  host_archs="x86_64" ;;
    *)        host_archs="arm64,x86_64" ;;
  esac

  cat > "${path}" <<DIST_EOF
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>${APP_NAME} ${version}</title>
    <organization>com.ntfsmount</organization>
    <domains enable_anywhere="false" enable_currentUserHome="false" enable_localSystem="true"/>
    <options customize="never" require-scripts="true" hostArchitectures="${host_archs}"/>
    <choices-outline>
        <line choice="default">
            <line choice="${pkg_id}"/>
        </line>
    </choices-outline>
    <choice id="default"/>
    <choice id="${pkg_id}" visible="false">
        <pkg-ref id="${pkg_id}"/>
    </choice>
    <pkg-ref id="${pkg_id}" version="${version}" onConclusion="none">${pkg_id}</pkg-ref>
    <welcome file="welcome.html"/>
    <license file="license.html"/>
    <conclusion file="conclusion.html"/>
</installer-gui-script>
DIST_EOF
}

# 生成 GUI 用的 html 文案（productbuild 会内联进 pkg）
make_gui_files() {
  local dir="$1" version="$2"
  mkdir -p "${dir}"

  cat > "${dir}/welcome.html" <<EOF
<html><body style="font-family:-apple-system;font-size:13px">
<h2>安装 ${APP_NAME} ${version}</h2>
<p>${APP_NAME} 用于在 macOS 上挂载、卸载与维护 NTFS 卷。</p>
<p>应用将被安装到 <code>/Applications</code>。安装过程需要管理员权限，
因为挂载 NTFS 卷需要访问磁盘设备节点并安装辅助进程。</p>
<p>点击"继续"开始安装。</p>
</body></html>
EOF

  cat > "${dir}/license.html" <<EOF
<html><body style="font-family:-apple-system;font-size:12px">
<h3>许可协议</h3>
<p>安装 ${APP_NAME} 即表示你同意以下条款：</p>
<ol>
  <li>本软件按"现状"提供，不附带任何明示或默示担保。</li>
  <li>挂载与卸载 NTFS 卷涉及底层磁盘驱动调用，可能存在数据风险。
      请在操作前确保目标卷已正确弹出或已做备份。</li>
  <li>因使用本软件导致的任何数据丢失，作者不承担责任。</li>
</ol>
</body></html>
EOF

  cat > "${dir}/conclusion.html" <<EOF
<html><body style="font-family:-apple-system;font-size:13px">
<h2>安装完成</h2>
<p>${APP_NAME} ${version} 已安装到 /Applications。</p>
<p>首次启动时，macOS 会询问是否允许 ${APP_NAME} 管理辅助进程
（用于提权挂载 NTFS 卷），请选择"允许"。</p>
</body></html>
EOF
}

build_pkg() {
  local app="$1" workdir="$2"
  local pkg_id="${BUNDLE_ID}.pkg"
  local versioned_pkg="${OUTPUT_DIR}/${APP_NAME}-${VERSION}${ARTIFACT_SUFFIX}-Installer.pkg"

  log "pkgbuild 生成组件包"
  # 组件包文件名必须与 Distribution 里的 <pkg-ref id> **完全一致**；
  # 不一致时 productbuild 找不到同名包却不报错，只输出空壳，靠体积校验兜住。
  local component="${workdir}/${pkg_id}"
  if ! pkgbuild \
      --root "${workdir}/pkgroot" \
      --scripts "${workdir}/pkgscripts" \
      --identifier "${pkg_id}" \
      --version "${VERSION}" \
      --install-location "/" \
      "${component}"; then
    die "pkgbuild 失败"
  fi

  log "productbuild 生成安装包"
  local dist_xml="${workdir}/Distribution.xml"
  local final_pkg="${versioned_pkg}"

  make_distribution "${dist_xml}" "${VERSION}" "${pkg_id}"
  make_gui_files "${workdir}/gui" "${VERSION}"

  # 注意：productbuild **不接受** --arch；能装的架构由 Distribution 的
  #  <hostArchitectures> 决定。它会覆盖已存在的输出，无需预先清理。
  if ! productbuild \
      --distribution "${dist_xml}" \
      --resources "${workdir}/gui" \
      --package-path "${workdir}" \
      "${final_pkg}"; then
    die "productbuild 失败"
  fi

  # 校验产物确实含应用本体：空壳 pkg 只有几 KB。
  local pkg_bytes
  pkg_bytes="$(stat -f%z "${final_pkg}" 2>/dev/null || echo 0)"
  if (( pkg_bytes < 1048576 )); then
    die "产出的 pkg 只有 ${pkg_bytes} 字节 —— 组件包没被真正打进去，这是空壳。
请检查组件包文件名是否与 Distribution 的 pkg-ref id 一致。"
  fi

  # 对 .pkg 也做一次 ad-hoc 签名，否则 Installer 会拒绝打开
  if [[ "${DO_SIGN}" -eq 1 ]]; then
    local identity="${SIGN_IDENTITY:--}"
    codesign --force --sign "${identity}" "${final_pkg}" 2>/dev/null \
      || warn "pkg 签名失败（不影响 .app 本身）"
  fi

  ok "安装包：${final_pkg}"
}

# ---------- 步骤 5：.dmg ----------

dmg_arch_note() {
  case "${ARTIFACT_SUFFIX}" in
    -arm64)
      printf 'Apple Silicon（M 系列芯片）专用。Intel Mac 请改用 x86_64 版本。'
      ;;
    -x86_64)
      printf 'Intel 处理器专用。Apple Silicon 机器可经 Rosetta 2 运行，但建议改用 arm64 版本。'
      ;;
    -universal)
      printf 'Universal 2 —— Apple Silicon 与 Intel 均可原生运行。'
      ;;
    *)
      printf '当前宿主架构（%s）版本。' "$(uname -m)"
      ;;
  esac
}

build_dmg() {
  local app="$1" workdir="$2"
  local dmg="${OUTPUT_DIR}/${APP_NAME}-${VERSION}${ARTIFACT_SUFFIX}.dmg"
  local stage="${workdir}/dmgstage"
  # 卷名带架构后缀：两个架构的映像可能同时挂载，重名会让 AppleScript
  # 按卷名定位到错的那个卷。
  local volname="${APP_NAME} ${VERSION}${ARTIFACT_SUFFIX}"

  log "准备 dmg 内容"
  rm -rf "${stage}"
  mkdir -p "${stage}"
  # 映像内的 app 固定叫 NTFSMount.app（去掉版本与架构后缀）：AppleScript 与
  # README 都按这个固定名引用，名不对齐会让窗口布局静默失败。
  cp -R "${app}" "${stage}/${APP_NAME}.app"
  ln -s /Applications "${stage}/Applications"

  # 可选：附带 README
  #
  # ⚠️ 这段文字必须与实现一致：本应用**刻意不安装**特权 helper（提权走
  # osascript 的系统授权对话框），README 不能教用户去删不存在的组件。
  cat > "${stage}/README.txt" <<EOF
${APP_NAME} ${VERSION}${ARTIFACT_SUFFIX}
==================================================

适用架构：
  $(dmg_arch_note)

安装方式：
  1. 把 ${APP_NAME}.app 拖到右侧的 Applications 文件夹。
  2. 安装依赖（读写能力来自它们，必须单独安装，二选一）：

       MacPorts：
         sudo port install macfuse
         sudo port install ntfs-3g

       Homebrew：
         brew install --cask macfuse
         brew tap gromgit/homebrew-fuse
         brew install ntfs-3g-mac

     装完 macFUSE 后需要在「系统设置 → 通用 → 登录项与扩展」里允许它。
     应用内的「系统依赖」页也会检测缺失项并给出对应命令。

首次启动：
  ad-hoc 签名未经过 Apple 认证，若提示「无法验证开发者」，
  右键点 ${APP_NAME}.app → 选「打开」→ 弹窗里再点「打开」（只需一次）。

挂载权限：
  挂载为读写时会弹出系统的授权对话框（支持 Touch ID）。
  本应用不安装任何特权 helper 或后台守护进程，
  凭据不经过应用进程。可在设置里选择把密码存入钥匙串以免重复授权。

卸载：
  把 ${APP_NAME}.app 拖到废纸篓即可，没有残留的特权组件需要清理。
EOF

  # 窗口布局尺寸（窗口外框 540×400）
  local win_w=540 win_h=400
  # 图标位置：经典的左右双栏（app 在左、Applications 在右），README 居中下方
  local app_x=150  app_y=150
  local link_x=390 link_y=150
  local readme_x=150 readme_y=290

  log "hdiutil 创建 dmg"
  local tmp_dmg="${workdir}/${APP_NAME}-rw.dmg"
  # UDIF 读写格式，便于后续注入 .DS_Store 窗口布局。
  # -ov = 不加密；不要写 -attach_key（hdiutil 没有这个选项，会直接失败）。
  if ! hdiutil create \
      -srcfolder "${stage}" \
      -volname "${volname}" \
      -fs HFS+ \
      -format UDRW \
      -size 100m \
      -ov \
      "${tmp_dmg}" >/dev/null; then
    die "hdiutil create 失败"
  fi

  local mount_point="${workdir}/dmgmnt"
  mkdir -p "${mount_point}"
  # 挂载但保持可写，以便写入 .DS_Store
  if ! hdiutil attach "${tmp_dmg}" \
      -mountpoint "${mount_point}" \
      -nobrowse \
      -noverify >/dev/null; then
    die "hdiutil attach 失败"
  fi

  # 清理挂载点：默认会把 .background/Icon\ 视图标进去
  rm -f "${mount_point}/.background/Icon?" 2>/dev/null || true
  rmdir "${mount_point}/.background" 2>/dev/null || true
  rmdir "${mount_point}/.Trashes" 2>/dev/null || true

  # 用 Finder 排图标窗口。失败不致命——用户仍可手动拖拽。
  log "设置 dmg 窗口布局（AppleScript + Finder）"
  if [[ -x /usr/bin/osascript ]]; then
    if osascript <<APPLESCRIPT_EOF
tell application "Finder"
    tell disk "${volname}"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        -- bounds 是 {左, 上, 右, 下} 四个屏幕坐标，**不是** {左, 上, 宽, 高}。
        set the bounds of container window to {200, 150, 200 + ${win_w}, 150 + ${win_h}}
        set viewOptions to the icon view options of container window
        -- 枚举名是 not arranged，不是 "not arranged in any order"（后者会让
        -- 整个脚本编译失败，位置设置全部不生效）。中文系统下再兜一层 try。
        try
            set arrangement of viewOptions to not arranged
        end try
        set icon size of viewOptions to 96
        set position of item "${APP_NAME}.app" of container window to {${app_x}, ${app_y}}
        try
            set position of item "Applications" of container window to {${link_x}, ${link_y}}
        end try
        try
            set position of item "README.txt" of container window to {${readme_x}, ${readme_y}}
        end try
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT_EOF
    then
      ok "窗口布局已设置"
    else
      warn "AppleScript 设置窗口布局失败（dmg 仍可用，用户可手动拖拽）"
      dim "常见原因：当前终端未被授权控制 Finder。可在「系统设置 →"
      dim "隐私与安全性 → 自动化」里勾选对应终端的 Finder 权限后重打。"
    fi
  else
    warn "未找到 osascript，跳过窗口布局"
  fi

  log "卸载并压缩为只读 dmg"
  # 先确认暂存区确实有 app —— dmg 与 pkgbuild 同样可能产出"看着正常、实则空壳"
  # 的产物，属于静默失败。
  if [[ ! -d "${stage}" ]] || [[ -z "$(find "${stage}" -maxdepth 1 -name '*.app' -print -quit 2>/dev/null)" ]]; then
    die "dmg 暂存区里没有 .app，拒绝生成空映像（stage=${stage}）"
  fi

  if ! hdiutil detach "${mount_point}" -quiet; then
    hdiutil detach "${mount_point}" -force || true
  fi
  # convert **没有** -ov（只有 create 有）：输出文件已存在时会直接失败，
  # 重复打包必然踩到；因此先输出到临时路径再用 mv 覆盖目标。
  local conv_out="${workdir}/ntfsmount-final.dmg"
  if ! hdiutil convert "${tmp_dmg}" -format UDZO -imagekey zlib-level=9 -o "${conv_out}" >/dev/null; then
    die "hdiutil convert 失败"
  fi
  mv -f "${conv_out}" "${dmg}"
  rm -f "${tmp_dmg}"

  # 体积自检：单架构应用压缩后至少也有数百 KB
  local dmg_bytes
  dmg_bytes="$(stat -f%z "${dmg}" 2>/dev/null || echo 0)"
  if (( dmg_bytes < 262144 )); then
    die "dmg 只有 ${dmg_bytes} 字节，疑似空映像"
  fi

  ok "磁盘映像：${dmg}"
}

# ---------- 输出报告 ----------

human_size() {
  local f="$1"
  if [[ ! -e "${f}" ]]; then
    printf -- '-'
    return
  fi
  # .app 是目录，用 du 求总占用（du 输出 KB，换算回 byte）
  if [[ -d "${f}" ]]; then
    awk -v b="$(du -sk "${f}" | awk '{print $1 * 1024}')" 'BEGIN {
      split("B KB MB GB", u, " ")
      i = 1
      while (b >= 1024 && i < 4) { b /= 1024; i++ }
      printf (i == 1 ? "%d %s" : "%.1f %s"), b, u[i]
    }'
    return
  fi
  local bytes
  bytes="$(stat -f%z "${f}")"
  awk -v b="${bytes}" 'BEGIN {
    split("B KB MB GB", u, " ")
    i = 1
    while (b >= 1024 && i < 4) { b /= 1024; i++ }
    printf (i == 1 ? "%d %s" : "%.1f %s"), b, u[i]
  }'
}

report() {
  local title="$1"; shift
  local -a artifacts=("$@")
  printf '\n%s%s%s\n' "${C_BOLD}" "${title}" "${C_RESET}"
  local f
  for f in "${artifacts[@]}"; do
    [[ -e "${f}" ]] || continue
    printf '  %-56s %8s\n' "${f#"${REPO_ROOT}"/}" "$(human_size "${f}")"
  done
}

# ---------- 主流程 ----------

main() {
  check_tools
  validate_arch
  detect_version
  audit_localization

  [[ "${VERSION}" =~ ^[0-9][0-9.]*$ ]] || die "版本号格式非法：${VERSION}"

  if [[ "${UNIVERSAL}" -eq 1 && "${SKIP_BUILD}" -eq 1 ]]; then
    die "--universal 与 --skip-build 互斥（Universal 需要两次真实构建）"
  fi

  mkdir -p "${OUTPUT_DIR}"
  local workdir
  workdir="$(mktemp -d "${TMPDIR:-/tmp}/ntfsmount-pkg.XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -rf '${workdir}'" EXIT

  printf '%sNTFSMount 打包%s  版本 %s  宿主 %s\n' \
    "${C_BOLD}" "${C_RESET}" "${VERSION}" "$(uname -m)"

  # 决定本次要产出哪些架构的二进制
  local -a archs=()
  if [[ "${UNIVERSAL}" -eq 1 ]]; then
    archs=(arm64 x86_64)
  elif [[ -n "${BUILD_ARCH}" ]]; then
    archs=("${BUILD_ARCH}")
  else
    archs=("")   # 宿主架构
  fi

  # 逐架构构建
  local -a bins=()
  local arch
  for arch in "${archs[@]}"; do
    # 每构建完一个架构就拷到 workdir —— SwiftPM 的 Products 目录不按架构分开。
    local bin="${workdir}/bin-${arch:-host}"
    if [[ "${SKIP_BUILD}" -eq 1 ]]; then
      existing_bin_for_arch "${arch}" "${bin}"
    else
      build_arch_to "${arch}" "${bin}"
    fi
    bins+=("${bin}")
  done

  # 决定 .app 内的最终二进制（Universal 时先 lipo 合并）
  local final_bin="${bins[0]}"
  local app_suffix=""

  if [[ "${UNIVERSAL}" -eq 1 ]]; then
    log "lipo 合并为 Universal 2"
    final_bin="${workdir}/${APP_NAME}-universal"
    lipo -create "${bins[0]}" "${bins[1]}" \
      -output "${final_bin}" \
      || die "lipo 合并失败"
    ok "已合并：$(lipo -archs "${final_bin}")"
    app_suffix="-universal"
  elif [[ -n "${BUILD_ARCH}" ]]; then
    app_suffix="-${BUILD_ARCH}"
  fi

  # 后缀必须贯穿全部产物，否则第二次打包会静默覆盖第一次的安装包。
  ARTIFACT_SUFFIX="${app_suffix}"

  # 构建 Finder 扩展（appex），并跟着架构走：Universal 主程序配单架构 appex
  # 会让 Finder 拒绝加载；appex 同样逐架构构建，Universal 时再 lipo 合并。
  if [[ "${WITH_FINDER_EXT}" -eq 1 ]]; then
    if [[ -n "${APPEX_SRC}" ]]; then
      log "使用现成 appex：${APPEX_SRC}"
      APPEX_SRC="$(cd "${APPEX_SRC}" && pwd)"
      if [[ "${UNIVERSAL}" -eq 1 ]]; then
        warn "Universal 模式下手工指定的 appex 不会被 lipo 合并
若 appex 是单架构，Finder 可能拒绝加载。请确认 ${APPEX_SRC} 的架构。"
      fi
    else
      local -a appex_dirs=()
      local a
      for a in "${archs[@]}"; do
        build_appex "${a}" "${workdir}/appex-${a:-host}"
        appex_dirs+=("${workdir}/appex-${a:-host}/${APPEX_NAME}")
      done

      if [[ "${UNIVERSAL}" -eq 1 ]]; then
        log "lipo 合并 appex 为 Universal 2"
        local merged="${workdir}/appex-universal/${APPEX_NAME}"
        mkdir -p "$(dirname "${merged}")"
        cp -R "${appex_dirs[0]}" "${merged}"
        local merged_bin="${merged}/Contents/MacOS/NTFSMountFinderSync"
        [[ -f "${merged_bin}" ]] || die "appex 内未找到可执行文件：${merged_bin}"
        lipo -create \
          "${appex_dirs[0]}/Contents/MacOS/NTFSMountFinderSync" \
          "${appex_dirs[1]}/Contents/MacOS/NTFSMountFinderSync" \
          -output "${merged_bin}" \
          || die "appex lipo 合并失败"
        ok "appex 已合并：$(lipo -archs "${merged_bin}")"
        APPEX_SRC="${merged}"
      else
        APPEX_SRC="${appex_dirs[0]}"
      fi
    fi
  fi

  # 组装 .app
  local app
  app="${OUTPUT_DIR}/${APP_NAME}-${VERSION}${app_suffix}.app"
  assemble_app "${app}" "${final_bin}"

  # 签名
  if [[ "${DO_SIGN}" -eq 1 ]]; then
    sign_app "${app}"
  else
    dim "未签名（--sign 可开启；未签名 app 首次启动需右键打开）"
  fi

  # .pkg
  if [[ "${DO_PKG}" -eq 1 ]]; then
    log "准备 pkg 目录结构"
    local pkgroot="${workdir}/pkgroot/Applications"
    mkdir -p "${pkgroot}"
    # 装进 /Applications 时**去掉**版本与架构后缀，固定叫 NTFSMount.app：
    # make_postinstall 的 APP_PATH 写死该名字，不一致会静默跳过全部收尾。
    cp -R "${app}" "${pkgroot}/${APP_NAME}.app"
    mkdir -p "${workdir}/pkgscripts"
    make_postinstall "${workdir}/pkgscripts/postinstall"
    build_pkg "${app}" "${workdir}"
  fi

  # .dmg
  if [[ "${DO_DMG}" -eq 1 ]]; then
    build_dmg "${app}" "${workdir}"
  fi

  # 汇总
  local -a artifacts=("${app}")
  if [[ "${DO_PKG}" -eq 1 ]]; then
    artifacts+=("${OUTPUT_DIR}/${APP_NAME}-${VERSION}${ARTIFACT_SUFFIX}-Installer.pkg")
  fi
  if [[ "${DO_DMG}" -eq 1 ]]; then
    artifacts+=("${OUTPUT_DIR}/${APP_NAME}-${VERSION}${ARTIFACT_SUFFIX}.dmg")
  fi
  report "产物汇总（输出目录 ${OUTPUT_DIR}）" "${artifacts[@]}"
  # ok() 走 printf '%s'，参数里的 \n 不会被解释成换行，要空行就自己 printf。
  printf '\n'
  ok "全部完成"
}

main "$@"