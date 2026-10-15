import Foundation
import Testing
@testable import ProductPageKit
import ProductPageKitASC

@Suite struct ProductsTests {
    @Test func pushSetsUpEverySubscriptionThenFindsNothingToChange() async throws {
        let fixture = try Fixture()
        let screenshot = Data(repeating: 7, count: 100)
        try fixture.writeReviewScreenshot(screenshot)

        try await Commands.pushProducts(fixture.session, options: apply)

        let app = try #require(fixture.fake.resource("app"))
        #expect(app.attributes["subscriptionStatusUrl"] as? String == "https://example.com/v1/notifications")
        #expect(app.attributes["subscriptionStatusUrlVersionForSandbox"] as? String == "V2")
        #expect(fixture.fake.all("subscriptionGroups").map { $0.attributes["referenceName"] as? String } == ["Example Plus"])
        #expect(fixture.fake.all("subscriptionGroupLocalizations").map { $0.attributes["locale"] as? String } == ["da", "en-US"])

        let subscriptions = fixture.fake.all("subscriptions")
        #expect(subscriptions.map { $0.attributes["productId"] as? String } == ["com.example.plus.monthly", "com.example.plus.annual"])
        #expect(subscriptions.map { $0.attributes["subscriptionPeriod"] as? String } == ["ONE_MONTH", "ONE_YEAR"])
        #expect(subscriptions.map { $0.attributes["name"] as? String } == ["Plus Monthly", "Plus Annual"])
        #expect(subscriptions.allSatisfy { $0.attributes["reviewNote"] as? String == "Buy with the demo account." })
        #expect(subscriptions.allSatisfy { $0.attributes["familySharable"] as? Bool == false })

        let localizations = fixture.fake.all("subscriptionLocalizations")
        #expect(localizations.map { "\($0.attributes["locale"]!) \($0.attributes["description"]!)" }
                == ["en-US Every month.", "da Hvert år.", "en-US Every year."])
        #expect(fixture.fake.all("subscriptionPlanAvailabilities").count == 2)

        let prices = fixture.fake.all("subscriptionPrices")
        #expect(prices.count == 6)
        let monthly = subscriptions[0].id
        #expect(Set(prices.filter { $0.relationships["subscription"]?.id == monthly }.compactMap { $0.relationships["subscriptionPricePoint"]?.id })
                == ["point-\(monthly)-USA-0", "point-\(monthly)-DNK-0", "point-\(monthly)-GBR-0"])

        let screenshots = fixture.fake.all("subscriptionAppStoreReviewScreenshots")
        #expect(screenshots.count == 2)
        #expect(screenshots.allSatisfy { $0.attributes["sourceFileChecksum"] as? String == AppStoreConnect.md5(screenshot) })

        fixture.fake.clearWrites()
        let second = try fixture.again()
        try await Commands.pushProducts(second.session, options: apply)
        #expect(second.console.output.contains("Nothing to change."))
        #expect(fixture.fake.writes.isEmpty)
    }

    /// A new price shows what new subscribers pay now and would pay in each
    /// territory. A price kept for existing subscribers, or one that has not
    /// started, is not what they pay now.
    @Test func aPriceChangeNamesEveryTerritorysPrices() async throws {
        let fixture = try Fixture()
        try await Commands.pushProducts(fixture.session, options: apply)
        let monthly = try #require(fixture.fake.all("subscriptions").first).id
        fixture.fake.add("subscriptionPrices", ["preserved": true, "startDate": "2026-01-01"],
                         relationships: ["subscription": ("subscriptions", monthly), "territory": ("territories", "DNK"),
                                         "subscriptionPricePoint": ("subscriptionPricePoints", "point-\(monthly)-DNK-1")])
        fixture.fake.add("subscriptionPrices", ["startDate": "2099-01-01"],
                         relationships: ["subscription": ("subscriptions", monthly), "territory": ("territories", "GBR"),
                                         "subscriptionPricePoint": ("subscriptionPricePoints", "point-\(monthly)-GBR-1")])
        let unchanged = try fixture.again()
        try await Commands.pushProducts(unchanged.session, options: dryRun)
        #expect(unchanged.console.output.contains("Nothing to change."))

        let dearer = try fixture.again()
        try dearer.write(try dearer.read("catalogue.json").replacingOccurrences(of: "\"4.99\"", with: "\"49.00\""), to: "catalogue.json")
        try await Commands.pushProducts(dearer.session, options: dryRun)
        let output = dearer.console.output
        #expect(output.contains("com.example.plus.monthly prices"))
        #expect(output.contains("49.00 in USA, equalised elsewhere"))
        #expect(output.contains("USA: 4.99 → 49.0"))
        #expect(output.contains("DNK: 35.0 → 349.0"))
        #expect(output.contains("GBR: 4.99 → 49.99"))
    }

    /// Family Sharing a subscription declares is turned on; App Store Connect
    /// cannot turn it off again, so a catalogue without it only warns.
    @Test func familySharingTurnsOnAndOnlyWarnsWhenDropped() async throws {
        let fixture = try Fixture()
        try await Commands.pushProducts(fixture.session, options: apply)
        let monthly = try #require(fixture.fake.all("subscriptions").first)
        #expect(monthly.attributes["familySharable"] as? Bool == false)

        let shared = try fixture.again()
        try shared.write(try shared.read("catalogue.json").replacingOccurrences(
            of: "\"price\": \"4.99\",", with: "\"price\": \"4.99\", \"familySharable\": true,"), to: "catalogue.json")
        fixture.fake.clearWrites()
        try await Commands.pushProducts(shared.session, options: apply)
        #expect(shared.console.output.contains("familySharable: false → true"))
        #expect(fixture.fake.writes == ["PATCH /v1/subscriptions/\(monthly.id)"])
        #expect(fixture.fake.resource(monthly.id)?.attributes["familySharable"] as? Bool == true)

        let dropped = try fixture.again()
        try await Commands.pushProducts(dropped.session, options: dryRun)
        #expect(dropped.console.output.contains("warning: com.example.plus.monthly has Family Sharing on, which App Store Connect cannot turn off"))
        #expect(dropped.console.output.contains("Nothing to change."))
    }

    /// A one-time purchase: made with its text, sold everywhere, priced in
    /// the base territory for App Store Connect to equalise, and given the
    /// review screenshot and note.
    @Test func pushSetsUpAOneTimePurchase() async throws {
        let fixture = try Fixture()
        let screenshot = Data(repeating: 7, count: 100)
        try fixture.writeReviewScreenshot(screenshot)
        try await Commands.pushProducts(fixture.session, options: apply)

        let purchase = try #require(fixture.fake.all("inAppPurchases").first)
        #expect(purchase.attributes["productId"] as? String == "com.example.lifetime")
        #expect(purchase.attributes["inAppPurchaseType"] as? String == "NON_CONSUMABLE")
        #expect(purchase.attributes["familySharable"] as? Bool == true)
        #expect(purchase.attributes["reviewNote"] as? String == "Buy with the demo account.")
        #expect(fixture.fake.all("inAppPurchaseLocalizations").map { $0.attributes["description"] as? String } == ["Every alert, for good."])
        #expect(fixture.fake.all("inAppPurchaseAvailabilities").count == 1)
        let schedule = try #require(fixture.fake.all("inAppPurchasePriceSchedules").first)
        #expect(schedule.relationships["baseTerritory"]?.id == "USA")
        #expect(fixture.fake.all("inAppPurchasePrices").map { $0.relationships["inAppPurchasePricePoint"]?.id }
                == ["iap-point-\(purchase.id)-1"])
        #expect(fixture.fake.all("inAppPurchaseAppStoreReviewScreenshots").first?.attributes["sourceFileChecksum"] as? String
                == AppStoreConnect.md5(screenshot))

        // A new price replaces the schedule.
        let cheaper = try fixture.again()
        try cheaper.write(try cheaper.read("catalogue.json").replacingOccurrences(of: "\"99.99\"", with: "\"49.99\""), to: "catalogue.json")
        fixture.fake.clearWrites()
        try await Commands.pushProducts(cheaper.session, options: apply)
        #expect(fixture.fake.writes == ["POST /v1/inAppPurchasePriceSchedules"])
        #expect(fixture.fake.all("inAppPurchasePrices").last?.relationships["inAppPurchasePricePoint"]?.id == "iap-point-\(purchase.id)-0")
    }

    @Test func aDryRunDescribesEveryStepWithoutWriting() async throws {
        let fixture = try Fixture()
        try await Commands.pushProducts(fixture.session, options: dryRun)
        #expect(fixture.fake.writes.isEmpty)
        let output = fixture.console.output
        #expect(output.contains("create  Group Example Plus"))
        #expect(output.contains("create  com.example.plus.annual"))
        #expect(output.contains("period: P1Y"))
        #expect(output.contains("4.99 in USA, equalised in every other territory"))
        #expect(output.contains("warning: there is no App Review screenshot of the in-app purchases yet"))
    }

    @Test func aChangedScreenshotIsReplaced() async throws {
        let fixture = try Fixture()
        try fixture.writeReviewScreenshot(Data(repeating: 1, count: 10))
        try await Commands.pushProducts(fixture.session, options: apply)
        let before = Set(fixture.fake.all("subscriptionAppStoreReviewScreenshots").map(\.id))

        let changed = try fixture.again()
        try changed.writeReviewScreenshot(Data(repeating: 2, count: 10))
        try await Commands.pushProducts(changed.session, options: apply)
        #expect(changed.console.output.contains("replace com.example.plus.monthly App Review screenshot"))
        let after = fixture.fake.all("subscriptionAppStoreReviewScreenshots")
        #expect(after.count == 2)
        #expect(Set(after.map(\.id)).isDisjoint(with: before))
    }

    @Test func aChangedPeriodNeedsANewProduct() async throws {
        let fixture = try Fixture()
        try await Commands.pushProducts(fixture.session, options: apply)
        let changed = try fixture.again()
        try changed.write(try changed.read("catalogue.json").replacingOccurrences(of: "\"P1M\"", with: "\"P3M\""), to: "catalogue.json")
        await #expect(throws: Stopped.self) { try await Commands.pushProducts(changed.session, options: dryRun) }
    }

    @Test func aProductMissingFromTheCatalogueIsReportedNotRemoved() async throws {
        let fixture = try Fixture()
        try await Commands.pushProducts(fixture.session, options: apply)
        let group = try #require(fixture.fake.all("subscriptionGroups").first)
        fixture.fake.add("subscriptions", ["productId": "com.example.old", "name": "Old", "subscriptionPeriod": "ONE_MONTH"],
                         relationships: ["group": ("subscriptionGroups", group.id)])
        let again = try fixture.again()
        try await Commands.pushProducts(again.session, options: dryRun)
        #expect(again.console.output.contains("warning: com.example.old is in App Store Connect and not in the catalogue"))
    }

    @Test func checkAndStoreKit() async throws {
        let fixture = try Fixture()
        try await Commands.checkProducts(fixture.session)
        #expect(fixture.console.output.contains("The catalogue is ready: 2 subscriptions in 1 group and 1 in-app purchase."))
        try await Commands.writeStoreKit(fixture.session)
        let file = try fixture.read("Example.storekit")
        #expect(file.contains("\"productID\" : \"com.example.plus.annual\""))
        #expect(file.contains("\"type\" : \"NonConsumable\""))
        #expect(file.contains("\"familyShareable\" : true"))
        try await Commands.writeStoreKit(fixture.session)
        #expect(fixture.console.output.contains("Example.storekit already matches the catalogue."))
    }
}
