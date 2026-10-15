import Foundation
import Testing
import ProductPageKitASC
import ProductPageKitCore

/// Reads a real app through the real API and decodes every kind of response
/// the commands read. Writes nothing. Runs only with
/// `PRODUCTPAGE_LIVE_ASC=1`, `PRODUCTPAGE_LIVE_BUNDLE_ID` and the `ASC_*`
/// key variables set.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PRODUCTPAGE_LIVE_ASC"] == "1"))
struct LiveTests {
    @Test func readsEverythingTheCommandsRead() async throws {
        let environment = Environment(values: ProcessInfo.processInfo.environment)
        let bundleID = try #require(environment["PRODUCTPAGE_LIVE_BUNDLE_ID"])
        let asc = AppStoreConnect(credentials: try Credentials(environment: environment))

        let app = try await asc.app(bundleID: bundleID)
        let info = try #require(try await asc.appInfo(appID: app.id))
        #expect(!(try await asc.appInfoLocalizations(appInfoID: info.id)).isEmpty)

        let versions = try await asc.versions(appID: app.id)
        let version = try #require(versions.first)
        let localizations = try await asc.versionLocalizations(versionID: version.id)
        #expect(!localizations.isEmpty)
        _ = try await asc.reviewDetail(versionID: version.id)
        for localization in localizations.values {
            for setID in try await asc.screenshotSets(.version(localization.id)).values {
                _ = try await asc.screenshots(setID: setID)
            }
            _ = try await asc.placements(localizationID: localization.id, type: "PRODUCT_PAGE_HEADER_ASSET")
        }
        _ = try await asc.assetLibraryID(appID: app.id)
        #expect(try await asc.territories().contains("USA"))

        for group in try await asc.subscriptionGroups(appID: app.id) {
            _ = try await asc.subscriptionGroupLocalizations(groupID: group.id)
            for subscription in try await asc.subscriptions(groupID: group.id) {
                _ = try await asc.subscriptionLocalizations(subscriptionID: subscription.id)
                _ = try await asc.hasSubscriptionAvailability(subscriptionID: subscription.id)
                _ = try await asc.prices(subscriptionID: subscription.id)
                if let point = try await asc.pricePoints(subscriptionID: subscription.id, territory: "USA").first {
                    _ = try await asc.equalizations(pricePointID: point.id)
                }
                _ = try await asc.subscriptionReviewScreenshot(subscriptionID: subscription.id)
            }
        }
    }
}
