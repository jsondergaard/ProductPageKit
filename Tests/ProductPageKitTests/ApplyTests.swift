import CryptoKit
import Foundation
import Testing
@testable import ProductPageKit
import ProductPageKitASC

/// When each change of a plan started and ended, in the order they did.
actor Timeline {
    private(set) var events: [String] = []
    private var running = 0
    private(set) var mostAtOnce = 0

    func start(_ name: String) {
        events.append("start \(name)")
        running += 1
        mostAtOnce = max(mostAtOnce, running)
    }

    func end(_ name: String) {
        events.append("end \(name)")
        running -= 1
    }

    func index(of event: String) -> Int { events.firstIndex(of: event)! }
}

@Suite struct ApplyTests {
    func change(_ name: String, concurrent: Bool, on timeline: Timeline, failing: Bool = false) -> Change {
        Change(action: .upload, subject: name, concurrent: concurrent) { _ in
            await timeline.start(name)
            try await Task.sleep(for: .milliseconds(50))
            await timeline.end(name)
            if failing { throw Stopped(description: "\(name) failed") }
        }
    }

    var asc: AppStoreConnect {
        AppStoreConnect(credentials: Credentials(issuerID: "issuer", keyID: "KEY", privateKey: P256.Signing.PrivateKey()),
                        transport: FakeAppStoreConnect.seeded())
    }

    /// Concurrent changes overlap; one that is not waits for everything
    /// before it, and everything after it waits for it.
    @Test func aChangeThatIsNotConcurrentRunsAlone() async throws {
        let fixture = try Fixture()
        let timeline = Timeline()
        let plan = Plan(changes: [
            change("a", concurrent: true, on: timeline), change("b", concurrent: true, on: timeline),
            change("create", concurrent: false, on: timeline),
            change("c", concurrent: true, on: timeline),
        ])
        try await fixture.session.apply(plan, asc: asc)
        #expect(await timeline.index(of: "start b") < timeline.index(of: "end a"))
        #expect(await timeline.index(of: "start create") > max(timeline.index(of: "end a"), timeline.index(of: "end b")))
        #expect(await timeline.index(of: "start c") > timeline.index(of: "end create"))
        #expect(fixture.console.output.contains("Applied 4 changes."))
    }

    @Test func noMoreThanTheWidthRunAtOnce() async throws {
        let fixture = try Fixture()
        let timeline = Timeline()
        let plan = Plan(changes: (1...5).map { change("\($0)", concurrent: true, on: timeline) })
        try await fixture.session.apply(plan, asc: asc, width: 2)
        #expect(await timeline.mostAtOnce == 2)
        #expect(await timeline.events.count == 10)
    }

    /// A failed change is reported and the others still run.
    @Test func aFailedConcurrentChangeLeavesTheRestRunning() async throws {
        let fixture = try Fixture()
        let timeline = Timeline()
        let plan = Plan(changes: [
            change("a", concurrent: true, on: timeline, failing: true), change("b", concurrent: true, on: timeline),
            change("c", concurrent: false, on: timeline),
        ])
        await #expect(throws: (any Error).self) { try await fixture.session.apply(plan, asc: asc) }
        #expect(await timeline.events.filter { $0.hasPrefix("end") }.count == 3)
        #expect(fixture.console.output.contains("failed  upload a: a failed"))
        #expect(fixture.console.output.contains("2 of 3 changes applied, 1 failed."))
    }
}
