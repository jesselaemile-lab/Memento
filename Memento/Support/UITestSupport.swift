import Foundation
import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

// MARK: - App data location

/// Where Memento keeps its own data (runs, rules, people, journals, library index).
/// UI-test launches get a throwaway directory so they never touch the real library.
nonisolated enum AppDirectories {
    static func applicationSupport() throws -> URL {
        if UITestSupport.isActive {
            let dir = UITestSupport.supportURL
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        return try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
    }
}

// MARK: - UI test mode

/// Hooks used only when the UI tests launch the app with `--uitesting`.
///
/// The app is sandboxed, so the test runner can't hand it folders or inspect its files.
/// Instead the app builds its own sample source folder inside its container, pre-fills the
/// New run screen with it, and publishes file counts through an on-screen status label.
nonisolated enum UITestSupport {
    static let launchArgument = "--uitesting"
    static let isActive = ProcessInfo.processInfo.arguments.contains(launchArgument)

    static let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("MementoUITests", isDirectory: true)
    static var supportURL: URL     { rootURL.appendingPathComponent("Support", isDirectory: true) }
    static var sourceURL: URL      { rootURL.appendingPathComponent("Source", isDirectory: true) }
    static var destinationURL: URL { rootURL.appendingPathComponent("Library", isDirectory: true) }
    private static var manifestURL: URL { rootURL.appendingPathComponent("manifest.json") }

    /// Capture dates for the sample photos — days apart so none of them read as a burst.
    private static let fixtureDates = [
        "2024:03:03 10:00:00", "2024:03:17 12:30:00", "2024:03:29 18:45:00",
        "2024:07:04 09:15:00", "2024:07:18 14:00:00", "2024:07:30 20:10:00"
    ]

    /// Wipes the previous test session and writes a fresh source folder of sample photos.
    static func prepare() {
        let fm = FileManager.default
        try? fm.removeItem(at: rootURL)
        try? fm.createDirectory(at: sourceURL, withIntermediateDirectories: true)
        try? fm.createDirectory(at: destinationURL, withIntermediateDirectories: true)

        var manifest: [String: Int64] = [:]
        for (i, date) in fixtureDates.enumerated() {
            let url = sourceURL.appendingPathComponent(String(format: "IMG_%04d.jpg", i + 1))
            guard writeSamplePhoto(to: url, index: i, exifDate: date) else { continue }
            manifest[url.lastPathComponent] = fileSize(url)
        }
        if let data = try? JSONEncoder().encode(manifest) {
            try? data.write(to: manifestURL, options: .atomic)
        }
    }

    /// One-line summary the UI tests assert on, e.g. "source=6 library=0 intact=yes".
    /// `intact` means every sample photo is back at its original path with its original size.
    static func fileStatus() -> String {
        let manifest = (try? Data(contentsOf: manifestURL))
            .flatMap { try? JSONDecoder().decode([String: Int64].self, from: $0) } ?? [:]
        let intact = !manifest.isEmpty && manifest.allSatisfy { name, size in
            fileSize(sourceURL.appendingPathComponent(name)) == size
        }
        let source  = AppViewModel.countFiles(in: sourceURL)
        let library = AppViewModel.countFiles(in: destinationURL)
        return "source=\(source) library=\(library) intact=\(intact ? "yes" : "no")"
    }

    // MARK: Fixture helpers

    /// Solid-colour 64×64 JPEG with an EXIF capture date. Same dimensions for every photo so
    /// none are flagged as a lower-resolution copy; different colours so none are byte-identical.
    private static func writeSamplePhoto(to url: URL, index: Int, exifDate: String) -> Bool {
        let size = 64
        guard let ctx = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return false }
        let hue = CGFloat(index) / CGFloat(fixtureDates.count)
        let color = NSColor(hue: hue, saturation: 0.7, brightness: 0.9, alpha: 1)
        ctx.setFillColor(color.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        // A stripe whose position depends on the index keeps the perceptual hashes apart too.
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(CGRect(x: index * 8, y: 0, width: 8, height: size))
        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return false }
        let props: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: exifDate,
                kCGImagePropertyExifDateTimeDigitized: exifDate
            ]
        ]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }

    private static func fileSize(_ url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64
    }
}

// MARK: - Status label

/// Small corner label shown only in UI-test mode; polls the sample folders twice a second.
struct UITestStatusLabel: View {
    @State private var status = ""

    var body: some View {
        Text(status)
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(Color.mText.opacity(0.6))
            .padding(6)
            .accessibilityIdentifier("uitest.fileStatus")
            .accessibilityValue(status)
            .task {
                while !Task.isCancelled {
                    status = await Task.detached(priority: .utility) { UITestSupport.fileStatus() }.value
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
    }
}
