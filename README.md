# ProductPageKit

ProductPageKit keeps an app's App Store product page in its repository and
pushes it to App Store Connect from one command-line tool:

- the copy, in an Xcode String Catalog with translation states, and a local
  page for reviewing and editing it
- screenshots captured from the running app on iPhone, iPad, iPhone Duo, Mac and Apple TV
  simulators, then framed in the app's own look by Swift code you write
- the product page header and search result videos, rendered from the same
  captures
- subscriptions and one-time purchases from a product catalogue, and the
  local StoreKit configuration file
- custom product pages
- product page optimization experiments, with up to three screenshot
  treatments
- App Review screenshots of the in-app purchases
- TestFlight builds, archived for every platform and uploaded with the same
  API key

The app decides when a screen is ready, so a capture never waits a fixed
time. Generated files live in `~/Library/Caches`, and archives in Xcode's
Archives folder, never in the repository.
Every command that writes to App Store Connect reads first, prints a plan of
the changes, asks once, then applies exactly that plan.

## Requirements

- macOS 26 and Xcode 26 (Swift 6.2)
- Apps on iOS 26, iPadOS 26, tvOS 26 or macOS 26, built with SwiftUI
- An App Store Connect API key with App Manager access

## How it fits together

ProductPageKit ships two libraries:

| Library | Linked by | Does |
| --- | --- | --- |
| `ProductPageKitCapture` | your app, in Debug only | Names the app's screens as scenes, moves between them on request, and says when each is ready. |
| `ProductPageKit` | a small tools package in your repository | Builds the app, drives simulators and the Mac app, frames and renders, and talks to App Store Connect. |

`ProductPageKitCapture` compiles to nothing outside `DEBUG`, so a Release
build carries none of it. The tools package holds your configuration and your
themes as Swift code.

## Setting it up

### 1. The tools package

Add `Tools/ProductPage` to the app's repository:

```swift
// Tools/ProductPage/Package.swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ProductPage",
    platforms: [.macOS(.v26)],
    dependencies: [.package(url: "https://github.com/jsondergaard/ProductPageKit", from: "1.0.0")],
    targets: [
        .executableTarget(name: "productpage", dependencies: [.product(name: "ProductPageKit", package: "ProductPageKit")]),
    ]
)
```

```swift
// Tools/ProductPage/Sources/productpage/main.swift
import ProductPageKit

await ProductPageKit.main(example)
```

```swift
// Tools/ProductPage/Sources/productpage/Example.swift
import Foundation
import ProductPageKit

let example = Project(
    name: "Example",
    bundleID: "com.example.app",
    xcode: .project("App/Example.xcodeproj", scheme: "Example"),
    locales: [StoreLocale("en", store: "en-US"), StoreLocale("da", store: "da")],
    appearance: .dark,
    platforms: [
        .iPhone(shots: ["inbox", "detail", "settings"]),
        .mac(window: CGSize(width: 1280, height: 800), shots: ["inbox", "detail"]),
    ],
    reviewScreenshots: [.inAppPurchases(test: "ExampleTests/ReviewScreenshot/capture()")],
    frames: ExampleFrames(),
    videos: ExampleMotion(),
    icon: "Assets/icon-1024.png",
    metadata: Metadata(
        urls: URLs(marketing: "https://example.com", support: "https://example.com/support",
                   privacy: "https://example.com/privacy"),
        copyright: "2026 Example",
        requiredLinks: [.description: [Metadata.appleEULA]],
        fallbackKeywords: "notes,tasks",
        reviewAccount: .environment(name: "DEMO_ACCOUNT_EMAIL", password: "DEMO_ACCOUNT_CODE"),
        reviewContact: .environment(prefix: "ASC_CONTACT_")
    ),
    products: Products(
        source: .command("swift run --quiet --package-path Server AppStoreProducts"),
        serverNotifications: URL(string: "https://example.com/v1/app-store/notifications"),
        storeKit: StoreKitFile(path: "App/Example.storekit", teamID: "ABCDE12345")
    ),
    builds: Builds()
)
```

Run it from anywhere in the repository:

```bash
swift run --package-path Tools/ProductPage productpage
```

Paths in the configuration are relative to the repository root. The tools
build in the debug configuration, which `swift run` uses.

### 2. Credentials

Put the API key's details in the repository's `.env`, which belongs in
`.gitignore`. Exported variables take priority over the file.

```bash
ASC_ISSUER_ID=…
ASC_KEY_ID=…
ASC_KEY_PATH=…/AuthKey_XXXXXXXXXX.p8
```

The App Review account and contact details are read from variables the
configuration names, and plans never print the password.

### 3. The app

Add the package to the app's Xcode project and link `ProductPageKitCapture`
to the app target. Then describe the app's screens as scenes, each backed by
fixture data, so a capture needs no server and no account:

```swift
#if DEBUG
import ProductPageKitCapture

enum Scene: String, CaptureScene {
    case inbox, detail, settings

    // Drawn from a launch of its own, because the app decides it at launch.
    var launchPolicy: CaptureLaunchPolicy { self == .settings ? .relaunch : .inProcess }

    @MainActor static let director = CaptureDirector<Scene>()
}
#endif
```

The root view hands the director a closure that puts the app in a scene:

```swift
WindowGroup {
    RootView(model: model)
        #if DEBUG
        .captureDirector(Scene.director) { scene, variant in
            model = .fixture(scene, variant: variant)
        }
        .captureReady(model.hasLoaded)
        #endif
}
```

`productpage doctor` then checks Xcode, the simulators, Screen Recording and
the credentials.

## Commands

Run with no arguments in a terminal, `productpage` opens a menu of the
commands the project can run. Arrow keys move, return chooses, left arrow or
Escape goes back, and q quits. A command then asks for its options:
platforms, locales and shots are ticked with space, all of them to start, and
a push asks whether to show the plan and ask, show it only, or apply it
straight away. The menu prints the command line before running it, then
comes back to where it was.
Outside a terminal, no arguments prints the help.

| Command | Does |
| --- | --- |
| `screenshots capture` | Builds the app and captures every platform's shots in every locale, and the App Review screenshots, into the cache. |
| `screenshots frame` | Frames the captures with the project's theme, into the cache. |
| `screenshots edit` | Serves the theme's layout editor on 127.0.0.1 and opens it in the browser. |
| `screenshots push` | Frames, then makes each screenshot set hold exactly the framed screenshots, uploading only files App Store Connect does not have. |
| `videos render` | Renders the header and search result videos from the captures, into the cache. |
| `videos push` | Renders, then uploads changed videos, waits for processing and places them on the editable iOS version. |
| `pages push` | Frames, then makes each custom product page match: promotional text, keywords and screenshots. Never submits. |
| `experiments push` | Frames, then makes each experiment hold its treatments' screenshots in every locale on iPhone and iPad. Never starts or submits. |
| `metadata check` | Checks the copy against Apple's limits and the configuration. No network. |
| `metadata push` | Makes the editable versions' text match the catalog. |
| `metadata pull` | Writes App Store Connect's text into the catalog, What's New for every version included. |
| `release new <version>` | Adds What's New for a version, empty in every locale. |
| `review` | Opens the copy, screenshots and videos in the browser for reviewing and editing. |
| `products check` | Checks the product catalogue. |
| `products push` | Makes the in-app products match the catalogue: groups, subscriptions, one-time purchases, names, availability, prices, free trials, App Review screenshots and server notification URLs. |
| `products storekit` | Writes the StoreKit configuration file from the catalogue. |
| `builds list` | Lists the builds App Store Connect has, newest first: version, platform, processing state and who can test them. |
| `builds upload` | Archives every platform as the next build, then uploads each to TestFlight. Never submits for review. |
| `export <dir>` | Copies the framed screenshots, the videos and the renders out of the cache. A custom page's or treatment's screenshots go in a folder of their own. `--platforms` and `--locales` narrow it; videos come only with an iOS platform. |
| `cache size`, `cache prune` | Shows what the cache holds; deletes the build, its logs, and files nothing points to. |
| `doctor` | Checks Xcode, the simulators, Screen Recording and the App Store Connect credentials. |

Pushes take `--dry-run` to print the plan and stop, and `--yes` to apply
without asking; without a terminal, `--yes` is required. Commands that work
per locale take `--locales`, and those that work on screenshots take
`--platforms`, except `experiments push`, which always writes iPhone and iPad.

A push uploads screenshot sets six at a time; creating a localization or a
page runs alone, before what goes into it. A request App Store Connect or its
storage answers with 429 is sent again after the wait it asks for, and a read,
update, delete or upload part answered with a 5xx, or not answered in time,
after 2, 4, 8, 16 and 32 seconds; a create is not, since it may have gone
through, and the next push clears what it left. Framed
PNGs with grain run to several megabytes each; `output: .jpeg(quality: 0.95)`
makes them about a fifth of that.

A locale pairs the catalog's code with App Store Connect's:
`StoreLocale("nb", store: "no")`. A storefront the app has no localization
for names the language its screenshots are captured in:
`StoreLocale("es-MX", store: "es-MX", app: "es-419")`.

## Capturing screenshots

`screenshots capture` builds each platform once, then launches the app once
per locale and moves it between scenes in process. After each move the app
reports ready: every `.captureReady` is true, the scene is active, and on a
Mac the window is key. Until then it says which of these it waits for: the
runner brings an app that is not in front forward, and names what a scene
still waited for when it gives up on it. Once the scene is ready, the runner
takes frames until two in a row match, so animations and late images settle
without a fixed wait. An app that left the front while it was photographed
is brought forward and photographed again. A view that loops on purpose
holds still when `\.isCapturingScreenshots` is true; one that cannot, such
as playing video, is marked `.captureMoving()` and left out of the
comparison.

- iPhone, iPad, iPhone Duo and Apple TV run on cloned simulators, one for
  every four cores and every 4 GB of memory past 8, at most one per locale
  and one for the screens tests put up, with 9:41 in the status bar. Each
  boots without the background services no app's own screens draw on
  (widgets, Siri, Spotlight, Health, News and the like, after
  [SimSlim](https://github.com/MobAI-App/simslim)): about 100 processes and
  3 to 4 GB with the app running, rather than 300 and 14 GB. Each takes the
  next locale left, so none waits on the others. Screens a test puts up
  take one of them first, which a fresh clone then replaces for the
  locales, or a clone of their own after the locales when a platform has
  one worker.
  Each runs on the newest runtime that has its device, and iPhone 6.9"
  never on a foldable. iPhone Duo's simulators boot folded, so each is
  opened flat after it boots, by the hinge event Device Hub's slider sends,
  and captured on its inner display, which is landscape.
- The app runs in each locale it captures. The simulator itself, which
  draws the status bar and the system's own screens, stays in the primary
  locale unless `simulatorLocale: .captured` moves it to each in turn. That
  shows 09.41 in a Danish clock, but costs a reboot per locale on an iPad.
- One `xcodebuild` build or archive runs at a time on the Mac, for every
  app: a capture's build waits for another run's archive, and says so,
  since two compiles at once run a Mac out of memory.
- `build: .deleteAfterRun` deletes the build when a run ends, so the cache
  keeps only captures and what is drawn from them. The next run builds from
  scratch.
- The Mac needs Screen Recording permission for the terminal, and the screen
  unlocked.
- Shots are named from their place in the platform's list: `01_inbox.png`. A
  scene the app does not have stops the run before the first capture.
- A shot can carry a variant: `Shot("library", variant: "pro")`.
- `--shots` captures any scene, store list or not, and `--dry-run` prints the
  launches.
- A capture is kept when its app, device and settings are the ones it was
  taken from. The app is every byte of the `.app` bundles the build wrote,
  UI test runners included; the device is the simulator and its runtime, or
  the Mac's system and window; the settings are the project's appearance,
  text size, status bar and locale policy, and the size of each served
  capture file. A platform with nothing left to take neither boots a
  simulator nor launches the app. A status bar that shows the time of the
  run keeps the time of the run that took each capture. `--force` takes
  everything again.
- A capture of one flat colour, or one that shows the same screen as
  another scene's capture in its locale, stops the run and is not kept, so
  the next run takes it again. The second is an app that never reached the
  scene, still showing the one before. Variants of one scene may match.
- `-ProductPageScene <name>` opens the app on a scene without a runner, which
  is how UI tests reach a fixture.

Code that runs at launch reads `Scene.director.launchScene`; anything else
reads `Scene.director.current`. A view marked `.captureHighlight()` is one a
theme may draw attention to, such as a card lifted off the screen; its rect
travels with the capture.

### Screens a test puts up

Some screens the app cannot show by itself. A test puts them up and reports
through a `CaptureDirector(host: .test)`. An App Review screenshot of the
in-app purchases is one, because StoreKit's sheet needs `SKTestSession`:

```swift
@Test(.enabled(if: CaptureHost.test.isControlled))
func capture() async throws {
    let director = CaptureDirector<ReviewScene>(host: .test)
    // put the screen up with .captureDirector(director) { _, _ in }
    await director.untilQuit()
}
```

A UI test that drives the system, such as the Home Screen or Safari, has no
view to report through. It hands the director what to do for each scene, and
the scene is ready when that returns:

```swift
func testRenders() async throws {
    try XCTSkipUnless(CaptureHost.test.isControlled)
    let director = CaptureDirector<Render>(host: .test)
    await director.direct { render, variant in
        // launch apps, press buttons, then say what moves on purpose
        return CaptureShown(moving: [])
    }
}
```

## Framing screenshots

A theme draws each screenshot on a canvas the size App Store Connect takes
for the platform. `ProductPageKitFrames` has the parts: `DeviceBezel` with a
`Style` for your own build of device, `TextColumn` and `TextStyle` with
balanced lines and `*accent*` spans, `Grain`, gradients and glows.

```swift
struct ExampleFrames: FrameTheme {
    func render(_ shot: FramedShot, on canvas: Canvas) throws {
        let size = canvas.size
        drawGradient(in: canvas.context, rect: canvas.bounds, top: .hex(0x1F2A44), bottom: .hex(0x0B0F1A))
        TextColumn(x: size.width * 0.08, top: size.height * 0.93, width: size.width * 0.84)
            .draw(shot.caption.headline, style: TextStyle(size: size.width * 0.09, weight: .bold, color: .hex(0xFFFFFF),
                                                          accent: .color(.hex(0x4F8AE8)), maxLines: 3), in: canvas.context)
        let capture = try shot.capture
        let width = size.width * 0.8
        let height = width * CGFloat(capture.height) / CGFloat(capture.width)
        let screen = CGRect(x: size.width * 0.1, y: size.height * 0.62 - height, width: width, height: height)
        DeviceBezel(shot.platform.bezel, screen: screen).draw(capture, in: canvas.context)
    }
}
```

`FramedShot` has the capture, the shot's place in its set, the platform, the
locale, the caption from the catalog and the highlights. A frame can also
read other captures, files, or components: views drawn on their own on a
transparent background.

```swift
.captureComponents(Scene.director) { request in
    CaptureComponent(width: 390) { PlanCard(plan: .fixture) }
}
```

A theme's `sources(for:)` lists what each frame reads, and a capture run
takes exactly what the frames and videos list. A `FrameSubject` and a
`FramedShot` say which list a frame belongs to in `list`: `.store`,
`.customPage(key)` or `.treatment(key)`, so a theme can lay out a treatment's
shots differently from the store's.

Frames are cached under a hash of everything drawn into them: the capture,
its highlights, the caption, the tools executable and the theme's
`layoutKey(for:)`. Editing a caption redraws that frame only, editing a theme
redraws them all, and framing an unchanged set takes no time. A theme that
reads its layouts from files returns each frame's layout as its key, so
editing one file redraws the frames it lays out.

A theme can give `editor` a `FrameEditor`: a page in the browser that
`productpage screenshots edit` serves, with each request it makes answered
by the editor. Its `FrameStudio` reads any frame's sources and caption as the
framer does, from sources the editor names, so the page can show a layout
drawn by the theme before it is saved. Without a theme, the captures are uploaded as
they are and must be a size App Store Connect takes.

## Videos

A motion theme declares the header and search result videos and draws their
stage. The package floats the devices and dissolves between their captures.

```swift
struct ExampleMotion: MotionTheme {
    let motion = Motion(seconds: 12, fps: 30, dissolve: 0.8)
    let assets = [
        CreativeAsset(.header, poster: 0, devices: [
            DeviceLayer(.iPhone, screens: ["inbox", "detail"], x: 0.75, top: 0.2, width: 0.08, firstChange: 2,
                        drift: CGVector(dx: 0.001, dy: 0.002)),
        ]),
    ]

    func stage(for asset: CreativeAsset) -> any MotionStage { ExampleStage(asset) }
}
```

The `MotionStage` supplies each device's look and glow, the caption, the
ground at a given time, and everything drawn over the devices. A device's
screen can also play a movie. Before anything is encoded, the run stops on a
missing or enlarged capture, a caption outside Apple's safe area, or a device
floating into the caption. The configuration is checked too: the frame rate,
and a poster frame inside the loop and clear of any dissolve.

## The copy

`AppStore.xcstrings` at the repository root is an Xcode String Catalog. Open
it in Xcode to edit every locale side by side, or run `productpage review`.

| Key | Field | Cap |
| --- | --- | --- |
| `name`, `subtitle` | App name and subtitle | 30 |
| `keywords` | Keywords | 100 |
| `promotionalText` | Promotional text | 170 |
| `description` | Description | 4000 |
| `whatsNew.<version>` | What's New for that version | 4000 |
| `reviewNotes` | App Review notes, not translated | 4000 |
| `productReviewNote` | Every in-app product's App Review note, not translated | 4000 |
| `screenshot.<shot>.kicker`, `.headline`, `.subline`, `.checklist` | A screenshot's caption | none |
| `video.<kind>.kicker`, `.headline`, `.subline`, `.checklist` | A video's caption | none |
| `page.<page>.promotionalText` | A custom product page's promotional text | 170 |
| `page.<page>.screenshot.<shot>.kicker`, `.headline`, `.subline`, `.checklist` | A custom page's screenshot caption | none |
| `treatment.<treatment>.screenshot.<shot>.kicker`, `.headline`, `.subline`, `.checklist` | An experiment treatment's screenshot caption | none |

The source language's values always upload. A translation uploads once its
state is *translated*; a new one, or one that needs review, leaves App Store
Connect's value as it is. Changing a source value marks its translations as
needing review. A caption needs a headline in the source language; a caption
line without a translation shows the source language's, with a warning. A
caption's checklist holds one item per line, which a theme reads as
`caption.checklist`. Each key's comment says how to write it, and Xcode and
the review page show it.

`metadata check` runs offline, so it fits in CI. It checks every value
against Apple's cap, required links, untranslatable fields, unknown keys,
missing or unreviewed translations, and keywords that repeat each other or
the name.

## Review

`productpage review` serves a page on 127.0.0.1 and opens it. Its sidebar
lists:

- Copy: the product page, search keywords, What's New one release at a
  time, and the App Review notes
- Screenshots: each platform's screenshots, each custom page with its
  promotional text and screenshots, and each experiment treatment
- Videos: the header and search videos with their captions
- Changes: every value changed since the last commit, the other locales
  with changes, and on request what differs from App Store Connect
- Checks: `metadata check`'s results, each linked to its value

The header picks the locale and counts the translations in each that need
review. Every value shows its character count against Apple's cap, and its
key's guidance on request. A translation sits beside the source language's
text, with Approve when it needs review. Comparing with the last commit or
with App Store Connect marks each value that differs and shows the
difference word by word.

Screenshots are framed when they are first shown, a platform in one locale
or one position across every locale. A screenshot that cannot be framed
names the capture it lacks. A video is marked out of date when its caption
or captures changed since it was rendered.

Edits save to the catalog at once, and an edited caption shows in its frame.
Changes made in Xcode or by an agent appear within two seconds. The address
names the locale, section and screenshot, so the back button and bookmarks
work. The page follows the system's light or dark appearance, fits a phone's
width, and makes no external requests.

## Custom product pages

A custom product page has its own screenshots, promotional text and search
keywords, for the people a particular link or ad sends.

```swift
customPages: [
    CustomPage("teams", name: "Teams", shots: ["shared", "roles", "free"], storeCaptions: ["free"],
               keywords: ["team", "shared"]),
]
```

Its shots are framed like the store's, on iPhone and iPad, with captions
under `page.teams.`; `storeCaptions` reuses the store's. A keyword is
assigned in each locale whose own keywords hold it, since App Store Connect
takes only terms from the live version's keywords. `pages push` finds a page
by `name` and creates it when it is missing. It leaves a page in review
alone, and puts changes to an approved page into a new version. Submitting
stays in App Store Connect.

## Product page optimization

An experiment shows up to three treatments of the product page's screenshots
to a share of its visitors, against the live page, which is the control. A
treatment's shots are framed like a custom page's, on iPhone and iPad, with
captions under `treatment.<key>.`; `storeCaptions` reuses the store's.

```swift
experiments: [
    Experiment("story", name: "Story set", trafficProportion: 50, treatments: [
        Treatment("story-a", name: "Story A", shots: ["trio", "guide", "free"], storeCaptions: ["free"]),
        Treatment("story-b", name: "Story B", shots: ["guide", "trio", "free"], storeCaptions: ["free"]),
    ]),
]
```

`trafficProportion` is the percent of visitors who see a treatment, 1 to 100,
shared evenly between the treatments. A treatment's key is unique in the
project, and `metadata check` refuses more than three treatments, a share
outside 1 to 100, repeated keys or names, and a store caption the store does
not have.

`experiments push` finds an experiment by `name` and creates it when it is
missing, then creates its treatments and, for each locale, a localization with
a screenshot set for iPhone and for iPad that holds exactly the framed shots.
App Store Connect starts a new localization with the control's screenshots,
which the same push replaces; a set of a display type the project does not
configure keeps the control's copy. Files App Store Connect already holds are
not uploaded again, and a changed
traffic proportion is written. `--experiments` names the ones to push by key.
It never starts an experiment, submits it for review or sets its state; that
stays in App Store Connect.

Only an experiment in `PREPARE_FOR_SUBMISSION`, `READY_FOR_REVIEW`, `REJECTED`
or `DEVELOPER_REJECTED`, with no start date, is edited. For any other, the
push stops with nothing written, and the experiment has to be stopped or
deleted in App Store Connect, or renamed in the project. App Store Connect
creates an experiment only for an app that has a live iOS version.

A treatment that leaves a locale or a display type undefined shows the
control there, while its visitors still count in the treatment's share. With
`--locales`, a push warns of each locale the treatment does not yet cover.

## Renders

Images of the app for somewhere other than the App Store, such as a website,
are renders: a scene, a component, or a screen a test puts up, on one
platform, under the file name the site expects.

```swift
renders: [
    Render("plans@yearly", .component(Component("plans", state: "yearly"), on: .iPhone)),
    Render("player@paused", .capture(Shot("player", variant: "paused"), on: .appleTV)),
    Render("home-screen", .test("AppUITests/RenderUITests/testRenders", scene: Shot("homeScreen"), on: .appleTV)),
]
```

`screenshots capture` takes them in the primary locale beside the store's
captures. `export` copies them to `renders/<platform>/<name>.png`.

## The product catalogue

An app whose server defines what it sells prints the catalogue from a
command, which `ProductSource.command` runs at the repository root:

```json
{
  "subscriptionGroups": [{
    "referenceName": "Example Plus",
    "localizations": {"en": {"name": "Example Plus"}},
    "subscriptions": [{
      "productID": "com.example.plus.monthly",
      "referenceName": "Plus Monthly",
      "level": 1,
      "period": "P1M",
      "price": "4.99",
      "localizations": {"en": {"name": "Plus", "description": "Everything, every month."}}
    }]
  }]
}
```

An app whose products nothing else defines holds the same catalogue as Swift
values with `ProductSource.catalogue(ProductCatalogue(...))`.

- `period` is `P1W`, `P1M`, `P2M`, `P3M`, `P6M` or `P1Y`.
- `price` is the customer price in the base territory, `USA` unless
  `Products.baseTerritory` says otherwise. Every other territory gets Apple's
  equalised price.
- One-time purchases sit beside the groups under `inAppPurchases`, each with
  a `kind` (`NON_CONSUMABLE`, `CONSUMABLE` or `NON_RENEWING_SUBSCRIPTION`), a
  `price` and localizations.
- `"familySharable": true` turns on Family Sharing. App Store Connect never
  turns it off again, so a catalogue that drops it gets a warning.
- `"introductoryOffer": {"duration": "ONE_WEEK"}` gives new subscribers a
  free trial of that length in every territory, and writes it to the StoreKit
  file. Free trials are the only kind. An offer of another kind or length is
  replaced, and offers App Store Connect has without one in the catalogue are
  reported, not removed.
- Products App Store Connect has and the catalogue does not are reported,
  never removed.

## TestFlight builds

`Project.builds` archives the app from `xcode` in Release, signed
automatically with the API key, which needs App Manager access. `builds
upload` reads the highest build number App Store Connect has on any platform,
shows a plan with the next one, and asks. It then archives the
platforms one after another, and uploads them all at once after the last, so
a platform that fails to build or a failed `afterArchive` command uploads
nothing. Archives go to
`~/Library/Developer/Xcode/Archives`, where the Organizer lists them.

```swift
builds: Builds(
    platforms: [.iOS, .tvOS, .macOS],
    numbering: .minor,
    audience: .internalOnly,
    afterArchive: ["sentry-cli debug-files upload --wait \"$PRODUCTPAGE_ARCHIVE\""]
)
```

- `platforms` defaults to the product page's App Store platforms.
- `numbering: .next` takes one more than the highest build, 88 after 87.
  `.minor` takes the next minor number, 88.1 after 88, for an app that CI
  also uploads with whole numbers, such as Xcode Cloud; CI's next build, 89,
  still sorts above it.
- `audience: .internalOnly`, the default, offers the build to internal
  testers only, and App Store Connect never offers it for review.
  `.everyone` also allows external testing and App Store submission.
- `afterArchive` commands run at the repository root after each archive,
  with its path in `PRODUCTPAGE_ARCHIVE`, while the next platform archives.

The number is passed to `xcodebuild` as `CURRENT_PROJECT_VERSION`, so the
app's and its extensions' `CFBundleVersion` must come from
`$(CURRENT_PROJECT_VERSION)`. An archive that carries another number stops the
run before anything uploads.

## The cache

```
~/Library/Caches/ProductPageKit/<bundle id>/
  derived/      one DerivedData for every platform
  raw/          the latest capture of each shot
  review/       the latest App Review screenshots
  components/   the latest component exports
  framed/       framed screenshots, named by what was drawn into them
  videos/       rendered videos, likewise
  ledger/       what each capture was taken from, to keep the unchanged ones
  logs/         xcodebuild's output from the latest run
```

Every run deletes what nothing configured needs any more. `cache prune`
also deletes the build and its logs, which the next run makes again.

## Developing

```bash
swift test
```

Unit tests cover the catalog, validation, the product catalogue, the StoreKit
file, token signing, the client, the control protocol, the director, the
capture plan, text layout, and the bezels and a sample theme against golden
images. After a deliberate change to how something draws,
`PRODUCTPAGE_RECORD_GOLDEN=1 swift test` records them again.

Integration tests run every command, and the review server over HTTP,
against an in-memory App Store Connect. They also capture
`Fixtures/SampleApp` on iPhone and Apple TV simulators and on the Mac, then
frame and render it, check that a Release build of the app contains none of
ProductPageKit, and archive it for the Mac as a numbered build. The Mac capture needs Screen Recording permission for the
terminal and the screen unlocked.

An opt-in live test reads a real app and writes nothing:

```bash
PRODUCTPAGE_LIVE_ASC=1 PRODUCTPAGE_LIVE_BUNDLE_ID=com.example.app \
  ASC_ISSUER_ID=… ASC_KEY_ID=… ASC_KEY_PATH=… swift test --filter LiveTests
```

The App Store Connect client is generated from Apple's OpenAPI document with
swift-openapi-generator, filtered to the operations the package calls. To
move to a new version of the document, download Apple's
[specification](https://developer.apple.com/sample-code/app-store-connect/app-store-connect-openapi-specification.zip),
then run:

```bash
swift Scripts/vendor-openapi.swift path/to/openapi.oas.json
```

The script explains each change it makes to Apple's document. A new
operation goes into `Sources/ProductPageKitASC/openapi-generator-config.yaml`
in the same commit as the code that calls it.

## License

MIT with the Commons Clause. You may use, change and ship ProductPageKit in
any app, open or closed source, commercial or not. You may not sell it, or a
product or service whose value comes entirely or substantially from it. See
[LICENSE](LICENSE).
