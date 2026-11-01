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
