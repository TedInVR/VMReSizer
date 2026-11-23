import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

let frameRatio = 1112.0 / 955.0

struct ChipSize {
    let width: Int
    let height: Int
}

final class StereoModel: ObservableObject {
    @Published var left: CGImage?
    @Published var right: CGImage?
    @Published var sourceURL: URL?
    @Published var zoom: Double = 1
    @Published var stereoWindow: Double = 0
    @Published var background = Color.black
    @Published var swapped = false
    @Published var nativeExport = true
    @Published var image3DExport = true
    @Published var myOwnReelExport = true
    @Published var format = 0
    @Published var status = "Import a full-width side-by-side stereo pair to begin."
    @Published var busy = false
    @Published var targeted = false

    var nativeSize: ChipSize {
        guard let image = left else { return ChipSize(width: 1112, height: 955) }
        // At this canvas size the source is drawn at approximately one pixel per pixel.
        // Zooming out grows padding; zooming in crops without inventing source detail.
        let naturalWidth = max(Double(image.width), Double(image.height) * frameRatio)
        let width = max(1, Int((naturalWidth / zoom).rounded()))
        return ChipSize(width: width, height: max(1, Int((Double(width) / frameRatio).rounded())))
    }

    var outputDescription: String {
        guard left != nil else { return "Full-resolution dimensions appear after import." }
        return "Full resolution: \(nativeSize.width) × \(nativeSize.height) pixels per eye"
    }

    func report(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "VM Re-Sizer"
        alert.informativeText = message
        alert.runModal()
    }

    func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg, .png, .tiff, .heic, .bmp]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { load(url) }
    }

    func load(_ url: URL) {
        do {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let rawWidth = properties[kCGImagePropertyPixelWidth] as? Int,
                  let rawHeight = properties[kCGImagePropertyPixelHeight] as? Int else {
                throw AppError.message("This file could not be read as an image.")
            }
            guard rawWidth > 1, rawHeight > 0, Double(rawWidth) * Double(rawHeight) < 160_000_000 else {
                throw AppError.message("Please use an image smaller than 160 megapixels.")
            }
            // ImageIO applies EXIF rotation before splitting the stereo pair.
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(rawWidth, rawHeight),
                kCGImageSourceShouldCacheImmediately: true
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                throw AppError.message("The image could not be decoded.")
            }
            guard image.width % 2 == 0 else {
                throw AppError.message("This image has an odd pixel width (\(image.width)). Please remove the extra column first so both eye images have exactly the same width.")
            }
            let half = image.width / 2
            guard let l = image.cropping(to: CGRect(x: 0, y: 0, width: half, height: image.height)),
                  let r = image.cropping(to: CGRect(x: half, y: 0, width: half, height: image.height)) else {
                throw AppError.message("The stereo pair could not be split.")
            }
            left = l; right = r; sourceURL = url; zoom = 1; stereoWindow = 0; swapped = false
            status = "\(url.lastPathComponent) • \(half) × \(image.height) per eye"
        } catch { report(error.localizedDescription) }
    }

    func fill() {
        guard let image = left else { return }
        let w = Double(image.width), h = Double(image.height)
        zoom = max(frameRatio / w, 1 / h) / min(frameRatio / w, 1 / h)
    }

    func changeWindow(_ amount: Double) { stereoWindow = min(0.2, max(-0.2, stereoWindow + amount)) }

    func changeZoom(_ factor: Double) { zoom = min(16, max(0.05, zoom * factor)) }

    func export() {
        guard let l = left, let r = right, let sourceURL = sourceURL else { return }
        guard nativeExport || image3DExport || myOwnReelExport else { report("Choose at least one export option."); return }
        let sizes: [(String, ChipSize)] = (nativeExport ? [("Full_Resolution", nativeSize)] : []) +
            (image3DExport ? [("Ready_for_Image3D", ChipSize(width: 1112, height: 955))] : [])
        let pairSize = nativeSize
        let exportPair = myOwnReelExport
        guard (!exportPair || Double(pairSize.width) * Double(pairSize.height) * 2 <= 100_000_000), sizes.allSatisfy({ Double($0.1.width) * Double($0.1.height) <= 100_000_000 }) else {
            report("This zoom would create an output larger than 100 megapixels. Increase the zoom or choose only the Image3D output.")
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        panel.directoryURL = sourceURL.deletingLastPathComponent()
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        let stem = sourceURL.deletingPathExtension().lastPathComponent
        var destination = parent.appendingPathComponent(stem + " VM Exports", isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = parent.appendingPathComponent(stem + " VM Exports \(suffix)", isDirectory: true)
            suffix += 1
        }
        let images = swapped ? [r, l] : [l, r]
        let bg = NSColor(background).usingColorSpace(.sRGB) ?? .black
        let color = CGColor(srgbRed: bg.redComponent, green: bg.greenComponent, blue: bg.blueComponent, alpha: 1)
        let currentZoom = zoom, currentFormat = format, currentWindow = stereoWindow
        busy = true
        status = "Exporting…"
        DispatchQueue.global(qos: .userInitiated).async {
            let staging = parent.appendingPathComponent(".vm-resizer-" + UUID().uuidString, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
                for (label, size) in sizes {
                    for eye in 0...1 {
                        let name = "\(stem)_\(label)_\(eye == 0 ? "Left" : "Right").\(currentFormat == 0 ? "jpg" : "png")"
                        try Self.write(images[eye], size: size, zoom: currentZoom,
                                       horizontalShift: (eye == 0 ? 1 : -1) * currentWindow / 2, color: color,
                                       format: currentFormat, url: staging.appendingPathComponent(name))
                    }
                }
                if exportPair {
                    let name = "\(stem)_Ready_for_MyOwnReel.\(currentFormat == 0 ? "jpg" : "png")"
                    try Self.write(images, size: pairSize, zoom: currentZoom, stereoWindow: currentWindow, color: color,
                                   format: currentFormat, url: staging.appendingPathComponent(name))
                }
                try FileManager.default.moveItem(at: staging, to: destination)
                DispatchQueue.main.async {
                    self.busy = false
                    self.status = "Exported \(sizes.count * 2 + (exportPair ? 1 : 0)) images to \(destination.lastPathComponent)."
                }
            } catch {
                try? FileManager.default.removeItem(at: staging)
                DispatchQueue.main.async {
                    self.busy = false; self.status = "Export failed. Your source image is unchanged."
                    self.report(error.localizedDescription)
                }
            }
        }
    }

    static func write(_ image: CGImage, size: ChipSize, zoom: Double, horizontalShift: Double = 0, color: CGColor, format: Int, url: URL) throws {
        try write([image], size: size, zoom: zoom, horizontalShift: horizontalShift, color: color, format: format, url: url)
    }

    static func write(_ images: [CGImage], size: ChipSize, zoom: Double, stereoWindow: Double = 0, horizontalShift: Double = 0, color: CGColor, format: Int, url: URL) throws {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: size.width * images.count, height: size.height,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw AppError.message("Not enough memory to render this output size.")
        }
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: size.width * images.count, height: size.height))
        for (eye, image) in images.enumerated() {
            context.saveGState()
            context.translateBy(x: CGFloat(eye * size.width), y: 0)
            context.clip(to: CGRect(x: 0, y: 0, width: size.width, height: size.height))
            let s = min(Double(size.width) / Double(image.width), Double(size.height) / Double(image.height)) * zoom
            let w = Double(image.width) * s, h = Double(image.height) * s
            context.interpolationQuality = .high
            let shift = images.count == 1 ? horizontalShift : (eye == 0 ? 1 : -1) * stereoWindow / 2
            context.draw(image, in: CGRect(x: (Double(size.width)-w)/2 + shift * Double(size.width), y: (Double(size.height)-h)/2, width: w, height: h))
            context.restoreGState()
        }
        guard let rendered = context.makeImage(),
              let output = CGImageDestinationCreateWithURL(url as CFURL, (format == 0 ? UTType.jpeg.identifier : UTType.png.identifier) as CFString, 1, nil) else {
            throw AppError.message("The output file could not be created.")
        }
        CGImageDestinationAddImage(output, rendered, [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
        guard CGImageDestinationFinalize(output) else { throw AppError.message("The image could not be saved.") }
    }


}

enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}

struct EyePreview: View {
    let image: CGImage?
    let zoom: Double
    let color: Color
    let label: String
    let horizontalShift: Double
    var body: some View {
        VStack(spacing: 10) {
            Text(label).font(.headline).foregroundColor(.secondary)
            GeometryReader { g in
                ZStack {
                    color
                    if let image = image {
                        let s = min(g.size.width / CGFloat(image.width), g.size.height / CGFloat(image.height)) * CGFloat(zoom)
                        Image(decorative: image, scale: 1)
                            .resizable().interpolation(.high)
                            .frame(width: CGFloat(image.width)*s, height: CGFloat(image.height)*s)
                            .position(x: g.size.width/2 + CGFloat(horizontalShift) * g.size.width, y: g.size.height/2)
                    } else {
                        Text("Import stereo photo").foregroundColor(.gray)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: min(g.size.width, g.size.height)*0.12))
                .overlay(RoundedRectangle(cornerRadius: min(g.size.width, g.size.height)*0.12).stroke(Color.white.opacity(0.25), lineWidth: 1))
            }
            .aspectRatio(frameRatio, contentMode: .fit)
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: StereoModel
    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("VM Re-Sizer").font(.largeTitle.bold())
                    Text("Prepare your stereo photos for a reel.").foregroundColor(.secondary)
                }
                Spacer()
                Button("Import Stereo Pair…") { model.chooseImage() }.keyboardShortcut("o")
            }
            HStack(spacing: 24) {
                EyePreview(image: model.swapped ? model.right : model.left, zoom: model.zoom, color: model.background, label: "LEFT EYE", horizontalShift: model.stereoWindow / 2)
                EyePreview(image: model.swapped ? model.left : model.right, zoom: model.zoom, color: model.background, label: "RIGHT EYE", horizontalShift: -model.stereoWindow / 2)
            }
            .padding(20)
            .background(Color.black.opacity(0.20))
            .cornerRadius(16)
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(model.targeted ? Color.accentColor : .clear, lineWidth: 3))
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: $model.targeted) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url = url { DispatchQueue.main.async { model.load(url) } }
                }
                return true
            }
            Text("Curved corners are a preview guide. Exports always have square corners.")
                .font(.callout).foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 12) {
                Text("1  Adjust the stereo window").font(.title3.bold())
                HStack(spacing: 16) {
                    Button("Push Back") { model.changeWindow(-0.002) }
                        .controlSize(.large).frame(minWidth: 120)
                    Slider(value: $model.stereoWindow, in: -0.2...0.2)
                        .accessibilityLabel("Stereo window. Left pushes back, right pulls forward.")
                    Button("Pull Forward") { model.changeWindow(0.002) }
                        .controlSize(.large).frame(minWidth: 120)
                }
                Text("Both eyes move horizontally in opposite directions. The center keeps the original stereo window. Importing a photo resets this adjustment.")
                    .font(.caption).foregroundColor(.secondary)
            }
            .padding(16).background(Color.orange.opacity(0.07)).cornerRadius(12)
            VStack(alignment: .leading, spacing: 12) {
                Text("2  Frame your photo").font(.title3.bold())
                HStack {
                    Button("Fit Entire Image") { model.zoom = 1 }.keyboardShortcut("0")
                    Button("Fill Frame") { model.fill() }
                    Button("−") { model.changeZoom(1/1.01) }
                    Slider(value: $model.zoom, in: 0.05...max(4, model.zoom))
                    Button("+") { model.changeZoom(1.01) }
                    Text(String(format: "%.1f%%", model.zoom*100)).monospacedDigit().frame(width: 70)
                }
                HStack {
                    ColorPicker("Background", selection: $model.background, supportsOpacity: false).fixedSize()
                    Button("Black") { model.background = .black }
                    Button("White") { model.background = .white }
                    Spacer()
                    Toggle("Swap left / right", isOn: $model.swapped).toggleStyle(.checkbox)
                }
                Text("Both eyes scale together. Stereo window adjustment remains applied. Full-width SBS input; half-width SBS must be expanded first.")
                    .font(.caption).foregroundColor(.secondary)
            }
            .padding(16).background(Color.blue.opacity(0.07)).cornerRadius(12)
            VStack(alignment: .leading, spacing: 10) {
                Text("3  Export").font(.title3.bold())
                Toggle("Full resolution — retain source detail", isOn: $model.nativeExport).toggleStyle(.checkbox)
                Text(model.outputDescription).font(.caption).foregroundColor(.secondary).padding(.leading, 20)
                Toggle("Image3D — 1112 × 955 pixels per eye", isOn: $model.image3DExport).toggleStyle(.checkbox)
                Toggle("MyOwnReel — full-resolution side-by-side pair", isOn: $model.myOwnReelExport).toggleStyle(.checkbox)
                HStack {
                    Picker("File format", selection: $model.format) {
                        Text("JPEG · maximum quality").tag(0)
                        Text("PNG · lossless").tag(1)
                    }.frame(width: 285)
                    Spacer()
                    if model.busy { ProgressView().controlSize(.small) }
                    Button("Export…") { model.export() }
                        .keyboardShortcut("e").disabled(model.left == nil || (!model.nativeExport && !model.image3DExport && !model.myOwnReelExport))
                }
                Text("Choose any combination. MyOwnReel places the left eye first and retains your framing. Each export gets a new folder; existing files are never overwritten.")
                    .font(.caption).foregroundColor(.secondary)
            }
            .padding(16).background(Color.green.opacity(0.07)).cornerRadius(12)
            Text(model.status).font(.callout).foregroundColor(.secondary).lineLimit(2)
        }
        .padding(24)
        }
        .frame(minWidth: 790, idealWidth: 920, minHeight: 700, idealHeight: 900)
        .disabled(model.busy)
        .onOpenURL { model.load($0) }
    }
}

#if !TESTING
@main
#endif
struct VMReSizerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = StereoModel()
    @StateObject private var updater = UpdateController.shared
    var body: some Scene {
        WindowGroup("VM Re-Sizer") {
            ContentView().environmentObject(model)
                .onAppear { AppDelegate.isExporting = { model.busy } }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Import Stereo Pair…") { model.chooseImage() }.keyboardShortcut("o")
            }
            CommandMenu("Image") {
                Button("Fit Entire Image") { model.zoom = 1 }.keyboardShortcut("0")
                Button("Zoom In") { model.changeZoom(1.01) }.keyboardShortcut("+")
                Button("Zoom Out") { model.changeZoom(1/1.01) }.keyboardShortcut("-")
                Divider()
                Button("Export…") { model.export() }.keyboardShortcut("e").disabled(model.left == nil || model.busy)
            }
            CommandGroup(replacing: .help) {
                Button("Keyboard Shortcuts") {
                    model.report("⌘O  Import stereo pair\n⌘0  Fit entire image\n⌘+ / ⌘−  Zoom in / out by 1%\n⌘E  Export both eyes\n⌘W  Close window\n⌘Q  Quit\n\nThe − and + buttons make precise 1% zoom adjustments. Both eyes stay linked.\n\nFull-resolution export uses approximately one source pixel per output pixel, with the new frame aspect ratio. Its dimensions change with zoom; the ratio is rounded to the nearest pixel.\n\nThe preview's rounded corners are approximate and are never burned into your exports.")
                }
                Button(updater.checking ? "Checking for Updates…" : "Check for Updates…") { updater.check() }.disabled(updater.checking)
                Toggle("Automatic Updates", isOn: $updater.automatic)
                Button("Connect GitHub…") { updater.connect() }.disabled(updater.checking)
                Button("Show Update Log") { NSWorkspace.shared.open(UpdatePaths.log) }
            }
        }
    }
}
