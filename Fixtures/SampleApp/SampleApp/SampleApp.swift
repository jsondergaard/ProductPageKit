import SwiftUI
#if DEBUG
import ProductPageKitCapture
#endif

/// The app the integration tests capture: three scenes, the detail scene with
/// a colour variant decided at launch, and a basket component, in English and
/// Danish.
@main
struct SampleApp: App {
    #if DEBUG
    @State private var director: CaptureDirector<SampleScene>
    #endif
    @State private var model: SampleModel

    init() {
        #if DEBUG
        let director = CaptureDirector<SampleScene>()
        _director = State(initialValue: director)
        _model = State(initialValue: SampleModel(scene: director.launchScene ?? .list, variant: director.launchVariant))
        #else
        _model = State(initialValue: SampleModel(scene: .list, variant: nil))
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                #if DEBUG
                .captureDirector(director) { scene, variant in
                    model = SampleModel(scene: scene, variant: variant)
                }
                .captureComponents(director) { request in
                    guard request.name == "basket" else { return nil }
                    let basket = SampleModel(scene: .list, variant: request.variant)
                    return CaptureComponent(width: 300) { BasketView(model: basket) }
                }
                #endif
        }
    }
}

enum SampleScene: String, CaseIterable {
    case list
    case detail
    case settings
}

#if DEBUG
extension SampleScene: CaptureScene {
    /// Settings is drawn from a cold launch, to exercise the relaunch path.
    var launchPolicy: CaptureLaunchPolicy { self == .settings ? .relaunch : .inProcess }

    /// The colour is picked at launch, as an app's data might be.
    static var variantPolicy: CaptureLaunchPolicy { .relaunch }
}
#endif

/// What a scene shows. The fruit arrive a moment after the view appears, as
/// data from a store would.
@MainActor @Observable
final class SampleModel {
    let scene: SampleScene
    let variant: String?
    private(set) var fruit: [LocalizedStringResource] = []

    init(scene: SampleScene, variant: String?) {
        self.scene = scene
        self.variant = variant
    }

    func load() async {
        await Task.yield()
        fruit = ["Apples", "Pears", "Plums", "Cherries"]
    }

    var colour: Color { variant == "blue" ? .blue : .orange }
}

struct RootView: View {
    let model: SampleModel

    var body: some View {
        NavigationStack {
            switch model.scene {
            case .list:
                List(model.fruit, id: \.key) { Text($0) }
                    .navigationTitle("Fruit")
            case .detail:
                DetailView(model: model)
            case .settings:
                Form {
                    Toggle("Notifications", isOn: .constant(true))
                        #if DEBUG
                        .captureHighlight()
                        #endif
                    Toggle("Weekly summary", isOn: .constant(false))
                }
                .navigationTitle("Settings")
            }
        }
        .task { await model.load() }
        #if DEBUG
        .captureReady(!model.fruit.isEmpty)
        #endif
    }
}

/// A plum in a sheet over the list, presented from the first frame. On a Mac
/// the sheet is the key window, which the director counts as its own.
struct DetailView: View {
    let model: SampleModel
    @State private var showsPlum = true

    var body: some View {
        List(model.fruit, id: \.key) { Text($0) }
            .navigationTitle("Plums")
            .sheet(isPresented: $showsPlum) {
                VStack(spacing: 24) {
                    Circle().fill(.white).frame(width: 200, height: 200)
                    Text("Ripe today").font(.largeTitle)
                }
                .frame(minWidth: 400, maxWidth: .infinity, minHeight: 400, maxHeight: .infinity)
                .background(model.colour)
            }
    }
}

/// The fruit in a card, which a theme composes beside a capture. It is
/// ready once the fruit have arrived.
struct BasketView: View {
    let model: SampleModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Basket").font(.headline)
            ForEach(model.fruit, id: \.key) { Text($0) }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(model.colour, in: RoundedRectangle(cornerRadius: 24))
        .task { await model.load() }
        #if DEBUG
        .captureReady(!model.fruit.isEmpty)
        #endif
    }
}

/// The App Review screenshot the review test draws.
struct PurchaseView: View {
    var body: some View {
        VStack(spacing: 16) {
            Text("Sample Plus").font(.largeTitle.bold())
            Text("Every fruit, every day.")
            Button("Subscribe") {}.buttonStyle(.borderedProminent)
        }
        .padding(48)
    }
}
