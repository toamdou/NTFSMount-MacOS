//  make-icon.swift —— 生成 NTFSMount 的应用图标（AppIcon.icns）。
//  用法：swift packaging/make-icon.swift <输出.icns 路径>

import AppKit
import Foundation

// MARK: - 参数

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("用法：swift make-icon.swift <输出.icns 路径>\n".utf8))
    exit(2)
}
let outPath = args[1]
let iconsetDir = (outPath as NSString).deletingPathExtension + ".iconset"
let outDir = (outPath as NSString).deletingLastPathComponent

// MARK: - 绘制工具

/// 把 SF Symbol 以指定颜色画进 dest 区域（按比例缩放到 fit 并居中）。
/// 返回 false 表示系统没有这个符号（调用方据此回退）。
@discardableResult
func drawSymbol(_ name: String,
                dest: CGRect,
                color: NSColor,
                weight: NSFont.Weight,
                ctx: CGContext) -> Bool {
    guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
        return false
    }
    let cfg = NSImage.SymbolConfiguration(pointSize: dest.height, weight: weight)
    guard let sym = base.withSymbolConfiguration(cfg) else { return false }

    let s = sym.size
    guard s.width > 0, s.height > 0 else { return false }

    let scale = min(dest.width / s.width, dest.height / s.height)
    let w = s.width * scale
    let h = s.height * scale
    let r = CGRect(x: dest.midX - w / 2, y: dest.midY - h / 2, width: w, height: h)

    // 用透明度层把 sourceAtop 限定在这块区域：先画符号，再把白色盖到它
    // 已有的像素上；直接 fill 整个上下文会把底板一并染白。
    ctx.saveGState()
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    sym.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1)
    ctx.setBlendMode(.sourceAtop)
    ctx.setFillColor(color.cgColor)
    ctx.fill(r)
    ctx.endTransparencyLayer()
    ctx.restoreGState()
    return true
}

/// 圆角矩形填充
func fillRoundedRect(_ rect: CGRect, radius: CGFloat, color: NSColor, ctx: CGContext) {
    let path = CGPath(roundedRect: rect,
                      cornerWidth: radius, cornerHeight: radius,
                      transform: nil)
    ctx.saveGState()
    ctx.addPath(path)
    ctx.setFillColor(color.cgColor)
    ctx.fillPath()
    ctx.restoreGState()
}

// MARK: - 主图

func drawMaster(size: CGFloat) -> NSBitmapImageRep? {
    let px = Int(size)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    ) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    guard let nsc = NSGraphicsContext.current else { return nil }

    let ctx = nsc.cgContext
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    let k = size / 1024.0

    // ---------- 1. 圆角方形底板 ----------
    let inset = 100 * k
    let side = size - inset * 2
    let plate = CGRect(x: inset, y: inset, width: side, height: side)
    let radius = side * 0.2237
    let platePath = CGPath(roundedRect: plate,
                           cornerWidth: radius, cornerHeight: radius,
                           transform: nil)

    ctx.saveGState()
    ctx.addPath(platePath)
    ctx.clip()

    // 主体渐变：顶部亮蓝 → 底部深蓝
    if let g = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            NSColor(srgbRed: 0.400, green: 0.553, blue: 1.000, alpha: 1).cgColor,
            NSColor(srgbRed: 0.098, green: 0.220, blue: 0.780, alpha: 1).cgColor,
        ] as CFArray,
        locations: [0, 1]
    ) {
        ctx.drawLinearGradient(
            g,
            start: CGPoint(x: plate.midX, y: plate.maxY),
            end: CGPoint(x: plate.midX, y: plate.minY),
            options: []
        )
    }

    // 顶部柔光：模拟自上而下的光照，避免大色块显得平
    if let g = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            NSColor(white: 1, alpha: 0.26).cgColor,
            NSColor(white: 1, alpha: 0.00).cgColor,
        ] as CFArray,
        locations: [0, 1]
    ) {
        let c = CGPoint(x: plate.midX, y: plate.maxY - side * 0.06)
        ctx.drawRadialGradient(g,
                               startCenter: c, startRadius: 0,
                               endCenter: c, endRadius: side * 0.82,
                               options: [])
    }
    ctx.restoreGState()

    // ---------- 2. 中央符号 ----------
    // 只保留一个主体符号，尺寸取内容区的 62% 并略高于几何中心（重心补偿）。
    let symbolBox = CGRect(
        x: plate.midX - side * 0.32,
        y: plate.midY - side * 0.24,
        width: side * 0.64,
        height: side * 0.50
    )
    var drew = drawSymbol("externaldrive.fill", dest: symbolBox,
                          color: .white, weight: .medium, ctx: ctx)
    if !drew {
        drew = drawSymbol("externaldrive", dest: symbolBox,
                          color: .white, weight: .medium, ctx: ctx)
    }
    if !drew {
        // 最后兜底：手绘一个圆角矩形 + 指示点，形状语言与磁盘一致
        let bar = CGRect(x: plate.midX - side * 0.28,
                         y: plate.midY - side * 0.12,
                         width: side * 0.56, height: side * 0.28)
        fillRoundedRect(bar, radius: side * 0.055,
                        color: NSColor(white: 1, alpha: 0.96), ctx: ctx)
        let dot = CGRect(x: bar.maxX - side * 0.11,
                         y: bar.midY - side * 0.030,
                         width: side * 0.060, height: side * 0.060)
        ctx.saveGState()
        ctx.addEllipse(in: dot)
        ctx.setFillColor(NSColor(srgbRed: 0.20, green: 0.36, blue: 0.95, alpha: 1).cgColor)
        ctx.fillPath()
        ctx.restoreGState()
    }

    // ---------- 3. 底座横线 ----------
    // 一条低对比度的细横线，把重心兜住、给构图一个稳定的落点。
    // 宽度刻意窄于符号，避免与符号争夺注意力。
    let barH = side * 0.020
    let barW = side * 0.34
    let bar = CGRect(x: plate.midX - barW / 2,
                     y: plate.minY + side * 0.190,
                     width: barW, height: barH)
    fillRoundedRect(bar, radius: barH / 2,
                    color: NSColor(white: 1, alpha: 0.52), ctx: ctx)

    return rep
}

// MARK: - 导出 iconset

let variants: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

guard let master = drawMaster(size: 1024) else {
    FileHandle.standardError.write(Data("主图渲染失败\n".utf8))
    exit(1)
}

// 先把 1024 主图落盘，其余尺寸交给 sips 缩放 —— sips 的方向处理可靠，
// 自己在 CoreGraphics 里做多次缩放容易踩坐标翻转的坑。
let fm = FileManager.default
let masterPNG = (outDir as NSString).appendingPathComponent("AppIcon-1024.png")
guard let png = master.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("PNG 编码失败\n".utf8))
    exit(1)
}
try? fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)
do {
    try png.write(to: URL(fileURLWithPath: masterPNG))
} catch {
    FileHandle.standardError.write(Data("写入 \(masterPNG) 失败：\(error)\n".utf8))
    exit(1)
}

try? fm.removeItem(atPath: iconsetDir)
try? fm.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)

for (name, px) in variants {
    let dst = (iconsetDir as NSString).appendingPathComponent(name)
    if px == 1024 {
        try? fm.copyItem(atPath: masterPNG, toPath: dst)
        continue
    }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
    p.arguments = ["-z", "\(px)", "\(px)", masterPNG, "--out", dst]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try? p.run()
    p.waitUntilExit()
    guard p.terminationStatus == 0, fm.fileExists(atPath: dst) else {
        FileHandle.standardError.write(Data("缩放 \(name) 失败\n".utf8))
        exit(1)
    }
}

// MARK: - 打包 icns

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconsetDir, "-o", outPath]
iconutil.standardOutput = FileHandle.nullDevice
iconutil.standardError = FileHandle.nullDevice
try? iconutil.run()
iconutil.waitUntilExit()

guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil 打包失败\n".utf8))
    exit(1)
}

try? fm.removeItem(atPath: iconsetDir)
try? fm.removeItem(atPath: masterPNG)

let attrs = try? fm.attributesOfItem(atPath: outPath)
let bytes = (attrs?[.size] as? NSNumber)?.intValue ?? 0
print("图标已生成：\(outPath)（\(bytes) 字节）")
