import Foundation
import AppKit
import ImageIO

@main
struct Tests {
    static func main() throws {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ text: String) {
            precondition(condition(), text); count += 1
        }
        check(isNewer("0.2.0", than: "0.1.0"), "version upgrade")
        check(isNewer("0.10.0", than: "0.9.9"), "numeric version")
        check(!isNewer("0.2.0", than: "0.2.0"), "equal release")
        check(!isNewer("0.1.0", than: "0.2.0"), "no downgrade")
        check(!isNewer("oops", than: "0.2.0"), "malformed release")
        let hash = sha256(Data("abc".utf8))
        check(hash == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "known SHA256")
        let parsed = try expectedChecksum("\(hash)  \(releaseArchive)\n")
        check(parsed == hash, "checksum parsing")
        for bad in ["", "abc", "\(hash)  wrong.zip", "z\(hash)  \(releaseArchive)"] {
            do { _ = try expectedChecksum(bad); preconditionFailure("bad checksum accepted") }
            catch { count += 1 }
        }
        let shared = try ApplicationLock(exclusive: false)
        do { _ = try ApplicationLock(exclusive: true); preconditionFailure("updater acquired open-app lock") }
        catch { count += 1 }
        shared.release()
        let exclusive = try ApplicationLock(exclusive: true)
        do { _ = try ApplicationLock(exclusive: false); preconditionFailure("app acquired installing lock") }
        catch { count += 1 }
        exclusive.release()
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temp) }
        // A non-symmetric RGB source tests top/bottom orientation, padding and output size.
        let ctx = CGContext(data: nil, width: 400, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(NSColor.red.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
        ctx.setFillColor(NSColor.green.cgColor); ctx.fill(CGRect(x: 0, y: 100, width: 400, height: 100))
        let image = ctx.makeImage()!
        let sourceRep = NSBitmapImageRep(cgImage: image)
        let sourceTop = sourceRep.colorAt(x: 200, y: 80)!.usingColorSpace(.sRGB)!
        let sourceBottom = sourceRep.colorAt(x: 200, y: 120)!.usingColorSpace(.sRGB)!
        let model = StereoModel(); model.left = image; model.right = image
        for zoom in [0.25, 0.75, 1.0, 1.5, 3.0] {
            model.zoom = zoom
            let size = model.nativeSize
            let scale = min(Double(size.width)/400, Double(size.height)/200)*zoom
            check(abs(scale-1)<0.01, "native pixel scale")
            let file = temp.appendingPathComponent("output-\(zoom).png")
            try StereoModel.write(image, size: size, zoom: zoom,
                                  color: NSColor.blue.cgColor, format: 1, url: file)
            let src = CGImageSourceCreateWithURL(file as CFURL, nil)!
            let result = CGImageSourceCreateImageAtIndex(src, 0, nil)!
            check(result.width == size.width && result.height == size.height, "actual export dimensions")
            let rep = NSBitmapImageRep(cgImage: result)
            let centerTop = rep.colorAt(x: size.width/2, y: max(0,size.height/2-20))!.usingColorSpace(.sRGB)!
            let centerBottom = rep.colorAt(x: size.width/2, y: min(size.height-1,size.height/2+20))!.usingColorSpace(.sRGB)!
            check(abs(centerTop.greenComponent-sourceTop.greenComponent) < 0.02 && abs(centerBottom.redComponent-sourceBottom.redComponent) < 0.02, "export orientation")
            if zoom == 1 {
                let corner = rep.colorAt(x: 0, y: 0)!.usingColorSpace(.sRGB)!
                check(corner.blueComponent > 0.9, "square corners preserve padding")
            }
        }
        // Different eye colors expose ordering and cross-eye bleed when zoomed.
        ctx.setFillColor(NSColor.blue.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
        let blueEye = ctx.makeImage()!
        for zoom in [0.5, 1.0, 3.0] {
            let size = ChipSize(width: 200, height: 172)
            let file = temp.appendingPathComponent("pair-\(zoom).png")
            try StereoModel.write([image, blueEye], size: size, zoom: zoom,
                                  color: NSColor.black.cgColor, format: 1, url: file)
            let result = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(file as CFURL, nil)!, 0, nil)!
            check(result.width == 400 && result.height == 172, "SBS dimensions")
            let rep = NSBitmapImageRep(cgImage: result)
            let leftCenter = rep.colorAt(x: 100, y: 96)!.usingColorSpace(.sRGB)!
            let rightCenter = rep.colorAt(x: 300, y: 96)!.usingColorSpace(.sRGB)!
            check(leftCenter.blueComponent < 0.05 && rightCenter.blueComponent > 0.9, "SBS left/right order")
            if zoom == 3 {
                let seam = rep.colorAt(x: 201, y: 96)!.usingColorSpace(.sRGB)!
                check(seam.blueComponent > 0.9, "zoom clips each eye independently")
            }
        }
        // A narrow marker checks disparity direction and identical chip/SBS transforms.
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 196, y: 0, width: 8, height: 200))
        let marker = ctx.makeImage()!
        for depth in [-0.1, 0.0, 0.1] {
            let size = ChipSize(width: 200, height: 172)
            let pair = temp.appendingPathComponent("window-\(depth).png")
            try StereoModel.write([marker, marker], size: size, zoom: 1,
                                  stereoWindow: depth, color: NSColor.black.cgColor, format: 1, url: pair)
            let pairImage = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(pair as CFURL, nil)!, 0, nil)!
            let pairRep = NSBitmapImageRep(cgImage: pairImage)
            for eye in 0...1 {
                let shift = (eye == 0 ? 1.0 : -1.0) * depth / 2
                let chip = temp.appendingPathComponent("window-\(depth)-\(eye).png")
                try StereoModel.write(marker, size: size, zoom: 1, horizontalShift: shift,
                                      color: NSColor.black.cgColor, format: 1, url: chip)
                let chipImage = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(chip as CFURL, nil)!, 0, nil)!
                let chipRep = NSBitmapImageRep(cgImage: chipImage)
                var total = 0.0, weighted = 0.0
                for x in 0..<200 {
                    let value = chipRep.colorAt(x: x, y: 86)!.usingColorSpace(.sRGB)!.redComponent
                    let packed = pairRep.colorAt(x: eye * 200 + x, y: 86)!.usingColorSpace(.sRGB)!.redComponent
                    check(abs(value - packed) < 0.01, "chip and SBS stereo window match")
                    total += value; weighted += Double(x) * value
                }
                check(total > 0 && abs(weighted / total - (99.5 + shift * 200)) < 1,
                      "push back and pull forward disparity direction")
            }
        }
        model.stereoWindow = 0.2; model.changeWindow(0.002)
        check(model.stereoWindow == 0.2, "forward window limit")
        model.stereoWindow = -0.2; model.changeWindow(-0.002)
        check(model.stereoWindow == -0.2, "back window limit")
        let target = temp.appendingPathComponent("Original.app")
        let next = temp.appendingPathComponent("Next.app")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: next, withIntermediateDirectories: false)
        try Data("old".utf8).write(to: target.appendingPathComponent("version"))
        try Data("new".utf8).write(to: next.appendingPathComponent("version"))
        try VMUpdater.install(next, to: target)
        let installed = try String(contentsOf: target.appendingPathComponent("version"), encoding: .utf8)
        check(installed == "new", "app replacement")
        do { try VMUpdater.install(temp.appendingPathComponent("Missing.app"), to: target); preconditionFailure("missing source accepted") }
        catch { count += 1 }
        let preserved = try String(contentsOf: target.appendingPathComponent("version"), encoding: .utf8)
        check(preserved == "new", "failed update preserves app")
        print("Passed \(count) macOS export and updater checks.")
    }
}
