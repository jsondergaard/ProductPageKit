# ProductPageKit

ProductPageKit keeps an app's App Store product page in its repository and
pushes it to App Store Connect from one command-line tool:

- the copy, in an Xcode String Catalog with translation states, and a local
  page for reviewing and editing it
- screenshots captured from the running app on iPhone, iPad, Mac and Apple TV
  simulators, then framed in the app's own look by Swift code you write
- the product page header and search result videos, rendered from the same
  captures
- subscriptions and one-time purchases from a product catalogue, and the
  local StoreKit configuration file
- custom product pages
- App Review screenshots of the in-app purchases

The app decides when a screen is ready, so a capture never waits a fixed
time. Generated files live in `~/Library/Caches`, never in the repository.
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
    )
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
| `screenshots push` | Frames, then makes each screenshot set hold exactly the framed screenshots, uploading only files App Store Connect does not have. |
| `videos render` | Renders the header and search result videos from the captures, into the cache. |
| `videos push` | Renders, then uploads changed videos, waits for processing and places them on the editable iOS version. |
| `pages push` | Frames, then makes each custom product page match: promotional text, keywords and screenshots. Never submits. |
| `metadata check` | Checks the copy against Apple's limits and the configuration. No network. |
| `metadata push` | Makes the editable versions' text match the catalog. |
| `metadata pull` | Writes App Store Connect's text into the catalog, What's New for every version included. |
| `release new <version>` | Adds What's New for a version, empty in every locale. |
| `review` | Opens the copy, screenshots and videos in the browser for reviewing and editing. |
| `products check` | Checks the product catalogue. |
| `products push` | Makes the in-app products match the catalogue: groups, subscriptions, one-time purchases, names, availability, prices, App Review screenshots and server notification URLs. |
| `products storekit` | Writes the StoreKit configuration file from the catalogue. |
| `export <dir>` | Copies the framed screenshots, the videos and the renders out of the cache. |
| `cache size`, `cache prune` | Shows what the cache holds; deletes the build, its logs, and files nothing points to. |
| `doctor` | Checks Xcode, the simulators, Screen Recording and the App Store Connect credentials. |

Pushes take `--dry-run` to print the plan and stop, and `--yes` to apply
without asking; without a terminal, `--yes` is required. Commands that work
per locale take `--locales`, and those that work on screenshots take
`--platforms`.

A locale pairs the catalog's code with App Store Connect's:
`StoreLocale("nb", store: "no")`. A storefront the app has no localization
for names the language its screenshots are captured in:
`StoreLocale("es-MX", store: "es-MX", app: "es-419")`.

## Capturing screenshots

`screenshots capture` builds each platform once, then launches the app once
per locale and moves it between scenes in process. After each move the app
reports ready: every `.captureReady` is true, the scene is active, and on a
Mac the window is key. The runner then takes frames until two in a row
match, so animations and late images settle without a fixed wait. A view
that loops on purpose holds still when `\.isCapturingScreenshots` is true;
one that cannot, such as playing video, is marked `.captureMoving()` and left
out of the comparison.

- iPhone, iPad and Apple TV run on cloned simulators, one for every four
  cores and at most one per locale, with 9:41 in the status bar.
- The app runs in each locale it captures. The simulator itself, which
  draws the status bar and the system's own screens, stays in the primary
  locale unless `simulatorLocale: .captured` moves it to each in turn. That
  shows 09.41 in a Danish clock, but costs a reboot per locale on an iPad.
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
takes exactly what the frames and videos list.

Frames are cached under a hash of everything drawn into them: the capture,
its highlights, the caption and the tools executable. Editing a caption
redraws that frame only, editing a theme redraws them all, and framing an
unchanged set takes no time. Without a theme, the captures are uploaded as
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
| `screenshot.<shot>.kicker`, `.headline`, `.subline` | A screenshot's caption | none |
| `video.<kind>.kicker`, `.headline`, `.subline` | A video's caption | none |
| `page.<page>.promotionalText` | A custom product page's promotional text | 170 |
| `page.<page>.screenshot.<shot>.kicker`, `.headline`, `.subline` | A custom page's screenshot caption | none |

The source language's values always upload. A translation uploads once its
state is *translated*; a new one, or one that needs review, leaves App Store
Connect's value as it is. Changing a source value marks its translations as
needing review. A caption needs a headline in the source language; a caption
line without a translation shows the source language's, with a warning. Each
key's comment says how to write it, and Xcode and the review page show it.

`metadata check` runs offline, so it fits in CI. It checks every value
against Apple's cap, required links, untranslatable fields, unknown keys,
missing or unreviewed translations, and keywords that repeat each other or
the name.

## Review

`productpage review` serves a page on 127.0.0.1 and opens it. Its sidebar
lists:

- Copy: the product page, search keywords, What's New one release at a
  time, and the App Review notes
- Screenshots: each platform's screenshots, and each custom page with its
  promotional text and screenshots
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
- Products App Store Connect has and the catalogue does not are reported,
  never removed.

## The cache

```
~/Library/Caches/ProductPageKit/<bundle id>/
  derived/      one DerivedData for every platform
  raw/          the latest capture of each shot
  review/       the latest App Review screenshots
  components/   the latest component exports
  framed/       framed screenshots, named by what was drawn into them
  videos/       rendered videos, likewise
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
frame and render it, and check that a Release build of the app contains none
of ProductPageKit. The Mac capture needs Screen Recording permission for the
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
