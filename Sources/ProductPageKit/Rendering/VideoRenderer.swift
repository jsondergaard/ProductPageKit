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
/// the caption stops the run. The check places things without drawing them,
/// and each video's images and movies are opened only while it encodes, so
/// memory holds one video's at a time however many are stale.
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
        var problems: [RenderProblem<VideoItem>] = []
        var untranslated: [String] = []
    }

    /// A stale video, checked: where its devices and caption sit, with
    /// nothing drawn or opened yet.
    private struct Plan {
        let source: Source
        let stage: any MotionStage
        let devices: [PlacedDevice]
        let layout: VideoLayout
    }

    /// One device of a plan, placed.
    private struct PlacedDevice {
        let look: any DeviceLook
        let screens: [Screen]
        let schedule: ScreenSchedule
        let drift: CGVector
        let phase: Double

        var reach: CGRect { FloatingDevice.reach(of: look, drift: drift) }
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
        var problems: [RenderProblem<VideoItem>] = []
        for asset in theme.assets {
            for locale in locales {
                let item = VideoItem(kind: asset.kind, locale: locale)
                let caption: Caption
                switch captions.caption(.video(asset.kind), locale: locale) {
                case .success(let read): caption = read
                case .failure(let missing):
                    problems.append(RenderProblem(missing.description, asset: asset, locale: locale))
                    continue
                }
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
                                problems.append(RenderProblem("no \(platform.name) capture of \(shot)", asset: asset, locale: locale))
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
                    item: item,
                    video: RenderedVideo(asset: asset, locale: locale, url: cache.videos.appending(path: "\(key.finalize()).mp4")),
                    caption: caption, screens: screens))
            }
        }
        return Sources(sources: sources, problems: problems, untranslated: captions.untranslated)
    }

    func render(locales: [StoreLocale], progress: (String) -> Void) async throws -> Report {
        let inputs = try await sources(locales: locales)
        let sources = inputs.sources
        var problems = inputs.problems
        var stages: [CreativeAsset.Kind: any MotionStage] = [:]
        var plans: [Plan] = []
        for source in sources where !FileManager.default.fileExists(atPath: source.video.url.path) {
            let asset = source.video.asset
            let stage = stages[asset.kind] ?? theme.stage(for: asset)
            stages[asset.kind] = stage
            let (plan, found) = try self.plan(source, on: stage)
            problems += found.map { RenderProblem($0, asset: asset, locale: source.video.locale) }
            plans.append(plan)
        }
        guard problems.isEmpty else {
            throw Stopped(description: "Nothing rendered:\n" + problems.map { "  \($0)" }.joined(separator: "\n"))
        }

        try FileManager.default.createDirectory(at: cache.videos, withIntermediateDirectories: true)
        let motion = theme.motion
        for plan in plans {
            let video = plan.source.video
            progress("Rendering the \(video.asset.kind.title) video in \(video.locale.code)…")
            let job = try await job(for: plan)
            let partial = FileManager.default.temporaryDirectory.appending(path: "productpage-\(UUID().uuidString).mp4")
            defer { try? FileManager.default.removeItem(at: partial) }
            try await VideoEncoder.encode(to: partial, size: video.asset.size, fps: motion.fps, frames: motion.frames) { index in
                let time = Double(index) / Double(motion.fps)
                var image = job.stage.background(at: time, layout: job.layout)
                for device in job.devices { image = device.composited(over: image, at: time) }
                return job.stage.foreground(over: image, caption: job.caption, layout: job.layout, at: time)
            }
            try FileManager.default.moveItem(at: partial, to: video.url)
        }

        let codes = Set(locales.map(\.code))
        let configured = Set(project.locales.map(\.code))
        let kinds = Set(theme.assets.map(\.kind.rawValue))
        try CacheIndex.update(in: cache.videos, with: sources.map { ($0.item, $0.video.url.lastPathComponent) }) {
            codes.contains($0.locale) || !configured.contains($0.locale) || !kinds.contains($0.kind)
        }
        return Report(videos: sources.map(\.video), drawn: plans.count, untranslated: inputs.untranslated)
    }

    /// Places `source`'s devices and caption on `stage`, and what is wrong
    /// with where they sit. Captures are read for their size alone.
    private func plan(_ source: Source, on stage: any MotionStage) throws -> (Plan, [String]) {
        let asset = source.video.asset
        let locale = source.video.locale
        let size = asset.size
        let mirrored = theme.motion.mirrorsRightToLeft && locale.isRightToLeft
        var devices: [PlacedDevice] = []
        var found: [String] = []
        for (index, (layer, screens)) in zip(asset.devices, source.screens).enumerated() {
            let captures = try screens.compactMap { screen -> (shot: Shot, image: CGImage)? in
                guard case .capture(let shot, let data, let url) = screen else { return nil }
                return (shot, try CGImage.read(data, from: url))
            }
            let first = captures[0]
            let aspect = CGFloat(first.image.height) / CGFloat(first.image.width)
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
            devices.append(PlacedDevice(
                look: stage.device(layer.platform, screen: screen), screens: screens, schedule: layer.schedule(theme.motion),
                drift: CGVector(dx: layer.drift.dx * size.width * (mirrored ? -1 : 1), dy: -layer.drift.dy * size.height),
                phase: theme.motion.floatPhase(index, of: asset.devices.count)))
        }
        let bounds = caption(of: source, on: stage).bounds
        if !asset.kind.safeArea.contains(bounds) {
            let top = size.height - bounds.maxY
            found.append("the caption leaves the safe area: it covers x \(Int(bounds.minX))–\(Int(bounds.maxX)), "
                         + "y \(Int(top))–\(Int(top + bounds.height)) from the top")
        }
        for (index, device) in devices.enumerated() where device.reach.intersects(bounds) {
            found.append("device \(index + 1) floats over the caption")
        }
        let layout = VideoLayout(caption: bounds, devices: devices.map(\.reach), locale: locale)
        return (Plan(source: source, stage: stage, devices: devices, layout: layout), found)
    }

    /// Draws `plan`'s devices and caption, and opens its movies.
    private func job(for plan: Plan) async throws -> Job {
        let stage = plan.stage
        var devices: [FloatingDevice] = []
        for device in plan.devices {
            var shown: [FloatingDevice.Screen] = []
            for (position, screen) in device.screens.enumerated() {
                switch screen {
                case .capture(_, let data, let url):
                    shown.append(.still(try CGImage.read(data, from: url)))
                case .movie(let url, let start):
                    let window = device.schedule.window(of: position)
                    shown.append(.movie(try await MovieReel(url, from: start, seconds: window.upperBound - window.lowerBound)))
                }
            }
            let lights = shown.map { screen -> CIImage? in
                switch screen {
                case .still(let image): stage.light(from: image, of: device.look)
                case .movie(let reel): stage.light(from: reel.poster, of: device.look)
                }
            }
            devices.append(FloatingDevice(
                look: device.look, screens: shown, lights: lights, glow: stage.deviceGlow, schedule: device.schedule,
                drift: device.drift, phase: device.phase))
        }
        let (canvas, bounds) = caption(of: plan.source, on: stage)
        return Job(video: plan.source.video, stage: stage, devices: devices,
                   caption: CaptionLayer(image: CIImage(cgImage: canvas.image()), bounds: bounds), layout: plan.layout)
    }

    /// `source`'s caption set by `stage` on a canvas the asset's size, and
    /// what its text covers.
    private func caption(of source: Source, on stage: any MotionStage) -> (canvas: Canvas, bounds: CGRect) {
        let canvas = Canvas(size: source.video.asset.size)
        return (canvas, stage.drawCaption(source.caption, on: canvas, locale: source.video.locale))
    }
}

extension RenderProblem<VideoItem> {
    /// `product page header · da: no iPhone 6.9" capture of list`.
    init(_ reason: String, asset: CreativeAsset, locale: StoreLocale) {
        self.init(item: VideoItem(kind: asset.kind, locale: locale), reason: reason,
                  description: "\(asset.kind.title) · \(locale.code): \(reason)")
    }
}
