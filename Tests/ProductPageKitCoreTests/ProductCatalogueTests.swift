import Foundation
import Testing
@testable import ProductPageKitCore

let catalogueJSON = """
    {"subscriptionGroups": [{
      "referenceName": "Example Plus",
      "localizations": {"en": {"name": "Example Plus"}},
      "subscriptions": [
        {"productID": "com.example.plus.monthly", "referenceName": "Plus Monthly", "level": 1, "period": "P1M",
         "price": "4.99", "localizations": {"en": {"name": "Plus", "description": "Every month."}}},
        {"productID": "com.example.plus.annual", "referenceName": "Plus Annual", "level": 1, "period": "P1Y",
         "price": "49.00", "localizations": {"en": {"name": "Plus", "description": "Every year."}}}
      ]
    }]}
    """

func catalogueProject(command: String) -> Project {
    project(products: Products(
        source: .command(command),
        storeKit: StoreKitFile(path: "Example.storekit", teamID: "TEAM123456")
    ))
}

@Suite struct ProductCatalogueTests {
    let catalogue = try! JSONDecoder().decode(ProductCatalogue.self, from: Data(catalogueJSON.utf8))

    @Test func loadsWhatTheCommandPrints() async throws {
        let repository = try TemporaryRepository()
        try repository.write(catalogueJSON, to: "catalogue.json")
        let loaded = try await ProductCatalogue.load(catalogueProject(command: "cat catalogue.json"), root: repository.url)
        #expect(loaded == catalogue)
        #expect(loaded.subscriptionGroups[0].subscriptions.map(\.period) == [.month, .year])
    }

    @Test func aCatalogueInTheConfigurationRunsNothing() async throws {
        let repository = try TemporaryRepository()
        let project = project(products: Products(source: .catalogue(catalogue)))
        #expect(try await ProductCatalogue.load(project, root: repository.url) == catalogue)
    }

    @Test func aFailingCommandReportsItsError() async throws {
        let repository = try TemporaryRepository()
        do {
            _ = try await ProductCatalogue.load(catalogueProject(command: "echo broken >&2; exit 3"), root: repository.url)
            Issue.record("expected the command to fail")
        } catch let error as ShellError {
            #expect(error.status == 3)
            #expect(error.stderr == "broken\n")
        }
    }

    @Test func aValidCatalogueHasNoProblems() {
        #expect(catalogue.problems(project: project()) == [])
    }

    @Test func refusesWhatAppStoreConnectWould() {
        var broken = catalogue
        broken.subscriptionGroups[0].subscriptions[1].productID = "com.example.plus.monthly"
        broken.subscriptionGroups[0].subscriptions[0].price = "4.9"
        broken.subscriptionGroups[0].subscriptions[0].level = 0
        broken.subscriptionGroups[0].subscriptions[1].localizations = ["fr": .init(name: "Plus", description: "Chaque année.")]
        let problems = broken.problems(project: project())
        #expect(problems.contains(.error("com.example.plus.monthly is listed twice")))
        #expect(problems.contains(.error("com.example.plus.monthly: price 4.9 is not a price like 4.99")))
        #expect(problems.contains(.error("com.example.plus.monthly: level starts at 1")))
        #expect(problems.contains(.error("com.example.plus.monthly has no en text")))
        #expect(problems.contains(.error("com.example.plus.monthly has fr, which is not a configured locale")))
    }

    /// A catalogue that sells only subscriptions need not list one-time
    /// purchases, and the other way round.
    @Test func eitherListMayBeLeftOut() throws {
        #expect(catalogue.inAppPurchases.isEmpty)
        let purchases = try JSONDecoder().decode(ProductCatalogue.self, from: Data("""
            {"inAppPurchases": [{"productID": "com.example.lifetime", "referenceName": "Lifetime", "kind": "NON_CONSUMABLE",
              "price": "99.99", "familySharable": true, "localizations": {"en": {"name": "Lifetime", "description": "For good."}}}]}
            """.utf8))
        #expect(purchases.subscriptionGroups.isEmpty)
        #expect(purchases.inAppPurchases.first?.kind == .nonConsumable)
        #expect(purchases.problems(project: project()).isEmpty)
    }

    @Test func refusesAOneTimePurchaseAppStoreConnectWould() {
        let lifetime = ProductCatalogue.InAppPurchase(productID: "com.example.plus.monthly", referenceName: "Lifetime", kind: .consumable,
                                                      price: "99", familySharable: true, localizations: ["da": .init(name: "x", description: "y")])
        var broken = catalogue
        broken.inAppPurchases = [lifetime]
        #expect(broken.problems(project: project()).map(\.message).sorted() == [
            "com.example.plus.monthly has da, which is not a configured locale",
            "com.example.plus.monthly has no en text",
            "com.example.plus.monthly is listed twice",
            "com.example.plus.monthly: only a non-consumable can be shared with a family",
            "com.example.plus.monthly: price 99 is not a price like 4.99",
        ])
    }

    @Test func periodsAreISO8601() {
        #expect(ProductCatalogue.Period.allCases.map(\.rawValue) == ["P1W", "P1M", "P2M", "P3M", "P6M", "P1Y"])
    }
}

@Suite struct StoreKitConfigurationTests {
    let catalogue = try! JSONDecoder().decode(ProductCatalogue.self, from: Data(catalogueJSON.utf8))
    let example = catalogueProject(command: "true")

    func json(_ data: Data) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    @Test func writesTheCatalogueAsSubscriptions() throws {
        let file = try json(StoreKitConfiguration.data(catalogue: catalogue, project: example, existing: nil))
        let settings = file["settings"] as! [String: Any]
        #expect(settings["_developerTeamID"] as? String == "TEAM123456")
        #expect(settings["_locale"] as? String == "en_US")
        #expect(settings["_storefront"] as? String == "USA")
        let group = (file["subscriptionGroups"] as! [[String: Any]])[0]
        #expect(group["name"] as? String == "Example Plus")
        #expect((group["localizations"] as! [[String: Any]]).map { $0["displayName"] as? String } == ["Example Plus"])
        let subscriptions = group["subscriptions"] as! [[String: Any]]
        #expect(subscriptions.map { $0["productID"] as? String } == ["com.example.plus.monthly", "com.example.plus.annual"])
        #expect(subscriptions.map { $0["recurringSubscriptionPeriod"] as? String } == ["P1M", "P1Y"])
        #expect(subscriptions.map { $0["displayPrice"] as? String } == ["4.99", "49.00"])
        #expect(subscriptions.allSatisfy { $0["subscriptionGroupID"] as? String == group["id"] as? String })
        #expect(subscriptions.allSatisfy { $0["introductoryOffer"] is NSNull })
        #expect(Set(subscriptions.compactMap { $0["internalID"] as? String }).count == 2)
        #expect(subscriptions.map { $0["familyShareable"] as? Bool } == [false, false])
    }

    /// A subscription shared with a family says so in the StoreKit file too.
    @Test func aSharedSubscriptionIsSharedInTheFile() throws {
        var shared = catalogue
        shared.subscriptionGroups[0].subscriptions[0].familySharable = true
        let file = try json(StoreKitConfiguration.data(catalogue: shared, project: example, existing: nil))
        let subscriptions = (file["subscriptionGroups"] as! [[String: Any]])[0]["subscriptions"] as! [[String: Any]]
        #expect(subscriptions.map { $0["familyShareable"] as? Bool } == [true, false])
    }

    @Test func idsAreDerivedFromTheBundleIDWhenThereIsNoFile() throws {
        let first = try StoreKitConfiguration.data(catalogue: catalogue, project: example, existing: nil)
        #expect(first == (try StoreKitConfiguration.data(catalogue: catalogue, project: example, existing: nil)))
    }

    @Test func idsAreKeptFromTheFileBeingReplaced() throws {
        let existing = Data("""
            {"identifier": "6C1E2A7B", "subscriptionGroups": [{"id": "21794310", "name": "Example Plus", "subscriptions": [
              {"productID": "com.example.plus.monthly", "internalID": "6740000001"}
            ]}]}
            """.utf8)
        let file = try json(StoreKitConfiguration.data(catalogue: catalogue, project: example, existing: existing))
        #expect(file["identifier"] as? String == "6C1E2A7B")
        let group = (file["subscriptionGroups"] as! [[String: Any]])[0]
        #expect(group["id"] as? String == "21794310")
        #expect((group["subscriptions"] as! [[String: Any]]).map { $0["internalID"] as? String } == ["6740000001", "6740000002"])
    }

    @Test func rewritingTheSameCatalogueChangesNothing() throws {
        let repository = try TemporaryRepository()
        #expect(try StoreKitConfiguration.write(catalogue: catalogue, project: example, root: repository.url))
        #expect(try !StoreKitConfiguration.write(catalogue: catalogue, project: example, root: repository.url))
    }
}
