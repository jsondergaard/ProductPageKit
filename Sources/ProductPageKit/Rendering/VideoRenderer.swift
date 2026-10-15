import CoreGraphics
import CoreImage
import Foundation
import ProductPageKitCore
import ProductPageKitFrames

/// A rendered video in the cache.
struct RenderedVideo: Sendable {
    let asset: CreativeAsset
    let locale: StoreLocale
    let url: URL
}

/// Renders the header and search result videos into the cache, each from the
/// captures it shows, drawing only those whose captures, caption or theme
/// changed.
///
/// Every video is checked before any is encoded: a missing or enlarged
/// capture, a caption outside Apple's safe area, or a device floating into
/// the caption stops the run.
struct VideoRenderer {
    let copy: StoreCopy
    let cache: Cache
    let theme: any MotionTheme
    let files: CaptureFileStore

    init(copy: StoreCopy, cache: Cache, theme: any MotionTheme, log: @escaping @Sendable (String) -> Void) {
        self.copy = copy
        self.cache = cache
        self.theme = theme
        files = CaptureFileStore(project: copy.project, cache: cache, log: log)
    }

    var project: Project { copy.project }

    struct Report {
        var videos: [RenderedVideo]
        var drawn: Int
        var untranslated: [String]
    }

    /// A video's inputs, read and keyed.
    struct Source {
        let item: VideoItem
        let video: RenderedVideo
        let caption: Caption
        /// Each device's screens.
        let screens: [[Screen]]
    }

    /// One screen of a device, read.
    enum Screen {
        case capture(Shot, data: Data, url: URL)
        case movie(URL, from: Double)
    }

    /// Every video's inputs, what is missing, and the caption lines shown in
    /// the source language.
    struct Sources {
        var sources: [Source] = []
        var problems: [String] = []
        var untranslated: [String] = []
    }

    /// A video ready to encode.
    private struct Job {
        let video: RenderedVideo
        let stage: any MotionStage
        let devices: [FloatingDevice]
        let caption: CaptionLayer
        let layout: VideoLayout
    }

    /// Every video's inputs and the file they render to.
    func sources(locales: [StoreLocale]) async throws -> Sources {
        let movies = theme.assets.flatMap(\.devices).flatMap(\.screens).compactMap { screen -> FrameSource? in
            if case .movie(let name, _) = screen { .file(name) } else { nil }
        }
        let digests = try await files.digests(for: movies)
        var sources: [Source] = []
        var captions = CaptionReader(copy)
        var problems: [String] = []
        for asset in theme.assets {
            for locale in locales {
                guard let caption = captions.caption(.video(asset.kind), locale: locale) else { continue }
                var key = RenderKey("video")
                for part in [asset.kind.rawValue, locale.code, "\(asset.poster)", "\(theme.motion)", "\(asset.devices)"] { key.add(part) }
                key.add(caption)
                var screens: [[Screen]] = []
                var complete = true
                for layer in asset.devices {
                    guard let platform = project.platform(layer.platform) else { continue }
                    screens.append(layer.screens.compactMap { screen in
                        switch screen {
                        case .capture(let shot):
                            let url = cache.capture(platform, locale, shot)
                            guard let data = try? Data(contentsOf: url) else {
                                problems.append("\(asset.kind.title) · \(locale.code): no \(platform.name) capture of \(shot)")
                                complete = false
                                return nil
                            }
                            key.add(data)
                            return .capture(shot, data: data, url: url)
                        case .movie(let name, let start):
                            let (url, digest) = digests[name]!
                            key.add(digest)
                            return .movie(url, from: start)
                        }
                    })
                }
                guard complete else { continue }
                sources.append(Source(
                    item: VideoItem(kind: asset.kind, locale: locale),
                    video: RenderedVideo(asset: asset, locale: locale, url: cache.videos.appending(path: "\(key.finalize()).mp4")),
                    caption: caption, screens: screens))
            }
        }
        return Sources(sources: sources, problems: captions.problems + problems, untranslated: captions.untranslated)
    }

    func render(locales: [StoreLocale], progress: (String) -> Void) async throws -> Report {
        let inputs = try await sources(locales: locales)
        let sources = inputs.sources
        var problems = inputs.problems
        var stages: [CreativeAsset.Kind: any MotionStage] = [:]
        var jobs: [Job] = []
        for source in sources where !FileManager.default.fileExists(atPath: source.video.url.path) {
            let asset = source.video.asset
            let locale = source.video.locale
            let stage = stages[asset.kind] ?? theme.stage(for: asset)
            stages[asset.kind] = stage
            let mirrored = theme.motion.mirrorsRightToLeft && locale.isRightToLeft
            var devices: [FloatingDevice] = []
            var found: [String] = []
            for (index, (layer, screens)) in zip(asset.devices, source.screens).enumerated() {
                let captures = try screens.compactMap { screen -> (shot: Shot, image: CGImage)? in
                    guard case .capture(let shot, let data, let url) = screen else { return nil }
                    return (shot, try CGImage.read(data, from: url))
                }
                let first = captures[0]
                let aspect = CGFloat(first.image.height) / CGFloat(first.image.width)
                let size = asset.size
                let width = size.width * layer.width
                let left = mirrored ? size.width * (1 - layer.x) - width : size.width * layer.x
                let screen = CGRect(x: left, y: size.height * (1 - layer.top) - width * aspect, width: width, height: width * aspect)
                for capture in captures {
                    if abs(CGFloat(capture.image.height) / CGFloat(capture.image.width) - aspect) > aspect * 0.01 {
                        found.append("device \(index + 1): \(capture.shot) is not the shape of \(first.shot)")
                    }
                    if width > CGFloat(capture.image.width) {
                        found.append("device \(index + 1): \(capture.shot) would be enlarged from \(capture.image.width) to \(Int(width)) px")
                    }
                }
                let schedule = layer.schedule(theme.motion)
                var shown: [FloatingDevice.Screen] = []
                for (position, screen) in screens.enumerated() {
                    switch screen {
                    case .capture(_, let data, let url):
                        shown.append(.still(try CGImage.read(data, from: url)))
                    case .movie(let url, let start):
                        let window = schedule.window(of: position)
                        shown.append(.movie(try await MovieReel(url, from: start, seconds: window.upperBound - window.lowerBound)))
                    }
                }
                let look = stage.device(layer.platform, screen: screen)
                let lights = shown.map { screen -> CIImage? in
                    switch screen {
                    case .still(let image): stage.light(from: image, of: look)
                    case .movie(let reel): stage.light(from: reel.poster, of: look)
                    }
                }
                devices.append(FloatingDevice(
                    look: look, screens: shown, lights: lights, glow: stage.deviceGlow, schedule: schedule,
                    drift: CGVector(dx: layer.drift.dx * size.width * (mirrored ? -1 : 1), dy: -layer.drift.dy * size.height),
                    phase: theme.motion.floatPhase(index, of: asset.devices.count)))
            }
            let canvas = Canvas(size: asset.size)
            let bounds = stage.drawCaption(source.caption, on: canvas, locale: locale)
            if !asset.kind.safeArea.contains(bounds) {
                let top = asset.size.height - bounds.maxY
                found.append("the caption leaves the safe area: it covers x \(Int(bounds.minX))–\(Int(bounds.maxX)), "
                             + "y \(Int(top))–\(Int(top + bounds.height)) from the top")
            }
            for (index, device) in devices.enumerated() where device.reach.intersects(bounds) {
                found.append("device \(index + 1) floats over the caption")
            }
            problems += found.map { "\(asset.kind.title) · \(locale.code): \($0)" }
            jobs.append(Job(video: source.video, stage: stage, devices: devices,
                            caption: CaptionLayer(image: CIImage(cgImage: canvas.image()), bounds: bounds),
                            layout: VideoLayout(caption: bounds, devices: devices.map(\.reach), locale: locale)))
        }
        guard problems.isEmpty else {
            throw Stopped(description: "Nothing rendered:\n" + problems.map { "  \($0)" }.joined(separator: "\n"))
        }

        try FileManager.default.createDirectory(at: cache.videos, withIntermediateDirectories: true)
        let motion = theme.motion
        for job in jobs {
            progress("Rendering the \(job.video.asset.kind.title) video in \(job.video.locale.code)…")
            let partial = FileManager.default.temporaryDirectory.appending(path: "productpage-\(UUID().uuidString).mp4")
            defer { try? FileManager.default.removeItem(at: partial) }
            try await VideoEncoder.encode(to: partial, size: job.video.asset.size, fps: motion.fps, frames: motion.frames) { index in
                let time = Double(index) / Double(motion.fps)
                var image = job.stage.background(at: time, layout: job.layout)
                for device in job.devices { image = device.composited(over: image, at: time) }
                return job.stage.foreground(over: image, caption: job.caption, layout: job.layout, at: time)
            }
            try FileManager.default.moveItem(at: partial, to: job.video.url)
        }

        let codes = Set(locales.map(\.code))
        let configured = Set(project.locales.map(\.code))
        let kinds = Set(theme.assets.map(\.kind.rawValue))
        try CacheIndex.update(in: cache.videos, with: sources.map { ($0.item, $0.video.url.lastPathComponent) }) {
            codes.contains($0.locale) || !configured.contains($0.locale) || !kinds.contains($0.kind)
        }
        return Report(videos: sources.map(\.video), drawn: jobs.count, untranslated: inputs.untranslated)
    }
}
