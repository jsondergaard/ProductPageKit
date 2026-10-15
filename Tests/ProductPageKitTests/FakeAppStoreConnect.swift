import Foundation
import HTTPTypes
import OpenAPIRuntime

/// App Store Connect in memory, at the HTTP level: JSON:API resources, their
/// relationships, paging two at a time, asset reservations with upload
/// operations, and the side effects the real service has that the commands
/// depend on.
final class FakeAppStoreConnect: ClientTransport, @unchecked Sendable {
    struct Resource {
        let type: String
        let id: String
        var attributes: [String: Any]
        /// To-one relationships: name to (type, id).
        var relationships: [String: (type: String, id: String)]
    }

    private let lock = NSLock()
    private var resources: [String: Resource] = [:]
    private var order: [String] = []
    private var nextID = 1
    /// Screenshot ids by set, in display order.
    private var setOrder: [String: [String]] = [:]
    /// Bytes received by upload URL.
    private(set) var uploaded: [String: Data] = [:]
    /// Every write, as `METHOD /path`.
    private(set) var writes: [String] = []
    /// GETs a video stays processing for after its upload is committed.
    var processingReads = 1
    /// The terms each locale's live iOS keywords offer a custom page.
    var keywordPools: [String: [String]] = [:]
    /// Keywords assigned to each custom page localization.
    private var assigned: [String: [String]] = [:]

    static let pageSize = 2

    // MARK: - Seeding

    @discardableResult
    func add(_ type: String, id: String? = nil, _ attributes: [String: Any] = [:],
             relationships: [String: (type: String, id: String)] = [:]) -> String {
        lock.withLock {
            let id = id ?? newID()
            resources[id] = Resource(type: type, id: id, attributes: attributes, relationships: relationships)
            order.append(id)
            return id
        }
    }

    private func newID() -> String {
        defer { nextID += 1 }
        return "id\(nextID)"
    }

    func all(_ type: String) -> [Resource] {
        lock.withLock { order.compactMap { resources[$0] }.filter { $0.type == type } }
    }

    func resource(_ id: String) -> Resource? { lock.withLock { resources[id] } }

    func screenshots(inSet id: String) -> [Resource] {
        lock.withLock { (setOrder[id] ?? []).compactMap { resources[$0] } }
    }

    func clearWrites() { lock.withLock { writes = [] } }

    /// Changes a resource as App Store Connect would on its own, such as App
    /// Review approving it.
    func change(_ id: String, _ attributes: [String: Any]) {
        lock.withLock { for (key, value) in attributes { resources[id]?.attributes[key] = value } }
    }

    func keywords(assignedTo localization: String) -> [String] { lock.withLock { assigned[localization] ?? [] } }

    func assign(_ keywords: [String], to localization: String) { lock.withLock { assigned[localization] = keywords } }

    /// An app with an editable iOS version, a Mac version on sale, an asset
    /// library, and three territories with two price tiers each.
    static func seeded(bundleID: String = "com.example.app") -> FakeAppStoreConnect {
        let fake = FakeAppStoreConnect()
        let app = fake.add("apps", id: "app", ["bundleId": bundleID, "name": "Example"])
        fake.add("appInfos", id: "info", ["appStoreState": "PREPARE_FOR_SUBMISSION"], relationships: ["app": ("apps", app)])
        fake.add("appStoreVersions", id: "ios", ["platform": "IOS", "versionString": "1.2", "appStoreState": "PREPARE_FOR_SUBMISSION"],
                 relationships: ["app": ("apps", app)])
        fake.add("appStoreVersions", id: "mac", ["platform": "MAC_OS", "versionString": "1.1", "appStoreState": "READY_FOR_SALE"],
                 relationships: ["app": ("apps", app)])
        fake.add("appAssetLibraries", id: "library", relationships: ["app": ("apps", app)])
        for territory in ["USA", "DNK", "GBR"] { fake.add("territories", id: territory) }
        return fake
    }

    // MARK: - Transport

    func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
        var data = Data()
        if let body { data = try await Data(collecting: body, upTo: .max) }
        let (status, json) = lock.withLock { handle(request, body: data, baseURL: baseURL) }
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        let payload = json.map { try! JSONSerialization.data(withJSONObject: $0) } ?? Data()
        return (HTTPResponse(status: .init(code: status), headerFields: headers), HTTPBody(payload))
    }

    private func handle(_ request: HTTPRequest, body: Data, baseURL: URL) -> (Int, Any?) {
        let components = URLComponents(string: "https://host" + (request.path ?? ""))!
        let query = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
        if baseURL.host() == "upload.example" {
            uploaded[components.path] = body
            return (200, nil)
        }
        let parts = components.path.split(separator: "/").map(String.init).dropFirst()
        let method = request.method.rawValue
        if method != "GET" { writes.append("\(method) \(components.path)") }
        let input = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]

        switch (method, parts.count) {
        case ("GET", 1):
            return page(collection(parts[parts.startIndex], query: query), query: query, path: components.path)
        case ("GET", 2):
            guard let resource = resources[parts.last!] else { return notFound() }
            return (200, document(json(advanceProcessing(resource))))
        case ("GET", 3):
            let parent = parts[parts.startIndex + 1]
            let name = parts.last!
            if name == "baseTerritory" {
                return (200, document(resources[parent]?.relationships["baseTerritory"].map { ["type": "territories", "id": $0.id] } ?? NSNull()))
            }
            if let children = toOne[name] {
                let found = order.compactMap { resources[$0] }.first { resource in
                    children.contains { resource.type == $0.type && resource.relationships[$0.key]?.id == parent }
                }
                return (200, document(found.map(json) ?? NSNull()))
            }
            return page(related(name, parent: parent, query: query), query: query, path: components.path)
        case ("POST", 1) where parts.last == "inAppPurchasePriceSchedules":
            return createPriceSchedule(input ?? [:])
        case ("POST", 1) where parts.last == "appCustomProductPages":
            return createCustomPage(input ?? [:])
        case ("POST", 1) where parts.last == "appCustomProductPageVersions":
            return createCustomPageVersion(input?["data"] as? [String: Any] ?? [:])
        case ("POST", 1):
            return create(parts.last!, input?["data"] as? [String: Any] ?? [:])
        case ("PATCH", 2):
            return update(parts.last!, input?["data"] as? [String: Any] ?? [:])
        case ("GET", 4) where parts.last == "searchKeywords":
            let ids = assigned[parts[parts.startIndex + 1]] ?? []
            return (200, ["data": ids.map { ["type": "appKeywords", "id": $0] }, "links": ["self": "https://api.appstoreconnect.apple.com"]])
        case ("POST", 4) where parts.last == "searchKeywords", ("DELETE", 4) where parts.last == "searchKeywords":
            let localization = parts[parts.startIndex + 1]
            let ids = (input?["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
            assigned[localization] = method == "POST" ? (assigned[localization] ?? []) + ids : (assigned[localization] ?? []).filter { !ids.contains($0) }
            return (204, nil)
        case ("PATCH", 4):
            let ids = (input?["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
            setOrder[parts[parts.startIndex + 1]] = ids
            return (204, nil)
        case ("DELETE", 2):
            let id = parts.last!
            guard resources.removeValue(forKey: id) != nil else { return notFound() }
            order.removeAll { $0 == id }
            for key in setOrder.keys { setOrder[key]?.removeAll { $0 == id } }
            return (204, nil)
        default:
            return (405, nil)
        }
    }

    // MARK: - Reads

    /// Relationship name to the child type and the child's key back to its parent.
    private let toOne: [String: [(type: String, key: String)]] = [
        "appStoreReviewDetail": [("appStoreReviewDetails", "appStoreVersion")],
        "assetLibrary": [("appAssetLibraries", "app")],
        "appStoreReviewScreenshot": [("subscriptionAppStoreReviewScreenshots", "subscription"),
                                     ("inAppPurchaseAppStoreReviewScreenshots", "inAppPurchaseV2")],
        "inAppPurchaseAvailability": [("inAppPurchaseAvailabilities", "inAppPurchase")],
        "iapPriceSchedule": [("inAppPurchasePriceSchedules", "inAppPurchase")],
    ]

    private let toMany: [String: (type: String, key: String)] = [
        "appInfos": ("appInfos", "app"),
        "appInfoLocalizations": ("appInfoLocalizations", "appInfo"),
        "appStoreVersions": ("appStoreVersions", "app"),
        "appStoreVersionLocalizations": ("appStoreVersionLocalizations", "appStoreVersion"),
        "appScreenshotSets": ("appScreenshotSets", "appStoreVersionLocalization"),
        "videos": ("appAssetLibraryVideos", "assetLibrary"),
        "placements": ("appAssetLibraryPlacements", "appStoreVersionLocalization"),
        "subscriptionGroups": ("subscriptionGroups", "app"),
        "subscriptionGroupLocalizations": ("subscriptionGroupLocalizations", "subscriptionGroup"),
        "subscriptions": ("subscriptions", "group"),
        "subscriptionLocalizations": ("subscriptionLocalizations", "subscription"),
        "planAvailabilities": ("subscriptionPlanAvailabilities", "subscription"),
        "prices": ("subscriptionPrices", "subscription"),
        "appCustomProductPages": ("appCustomProductPages", "app"),
        "inAppPurchasesV2": ("inAppPurchases", "app"),
        "inAppPurchaseLocalizations": ("inAppPurchaseLocalizations", "inAppPurchaseV2"),
        "manualPrices": ("inAppPurchasePrices", "schedule"),
        "appCustomProductPageVersions": ("appCustomProductPageVersions", "appCustomProductPage"),
        "appCustomProductPageLocalizations": ("appCustomProductPageLocalizations", "appCustomProductPageVersion"),
    ]

    private func collection(_ type: String, query: [String: String]) -> [Resource] {
        order.compactMap { resources[$0] }.filter { resource in
            resource.type == type && (query["filter[bundleId]"].map { resource.attributes["bundleId"] as? String == $0 } ?? true)
        }
    }

    private func related(_ name: String, parent: String, query: [String: String]) -> [Resource] {
        switch name {
        case "appScreenshots":
            return (setOrder[parent] ?? []).compactMap { resources[$0] }
        case "appScreenshotSets":
            // A version's localization or a custom page's.
            return order.compactMap { resources[$0] }.filter {
                $0.type == "appScreenshotSets"
                    && ($0.relationships["appStoreVersionLocalization"]?.id == parent || $0.relationships["appCustomProductPageLocalization"]?.id == parent)
            }
        case "searchKeywords":
            return (keywordPools[query["filter[locale]"] ?? ""] ?? []).map { Resource(type: "appKeywords", id: $0, attributes: [:], relationships: [:]) }
        case "pricePoints":
            let territory = query["filter[territory]"]
            let points = resources[parent]?.type == "inAppPurchases" ? pricePoints(purchase: parent) : pricePoints(subscription: parent)
            return points.filter { territory == nil || $0.relationships["territory"]?.id == territory }
        case "equalizations":
            guard let point = resources[parent], let subscription = point.relationships["subscription"]?.id else { return [] }
            return pricePoints(subscription: subscription).filter {
                $0.attributes["tier"] as? Int == point.attributes["tier"] as? Int && $0.id != point.id
            }
        default:
            guard let child = toMany[name] else { return [] }
            return order.compactMap { resources[$0] }.filter { resource in
                guard resource.type == child.type, resource.relationships[child.key]?.id == parent else { return false }
                for (filter, attribute) in [("filter[referenceName]", "referenceName"), ("filter[placementType]", "placementType")] {
                    if let wanted = query[filter], resource.attributes[attribute] as? String != wanted { return false }
                }
                if let video = query["filter[video]"], resource.relationships["video"]?.id != video { return false }
                return true
            }
        }
    }

    /// Two tiers in every territory, made on first ask, in local currency and
    /// written as App Store Connect writes them: a whole amount with one
    /// decimal.
    private func pricePoints(subscription: String) -> [Resource] {
        let existing = order.compactMap { resources[$0] }.filter {
            $0.type == "subscriptionPricePoints" && $0.relationships["subscription"]?.id == subscription
        }
        guard existing.isEmpty else { return existing }
        let prices = ["USA": ["4.99", "49.0"], "DNK": ["35.0", "349.0"], "GBR": ["4.99", "49.99"]]
        for territory in ["USA", "DNK", "GBR"] {
            for tier in 0..<2 {
                let id = "point-\(subscription)-\(territory)-\(tier)"
                resources[id] = Resource(type: "subscriptionPricePoints", id: id,
                                         attributes: ["customerPrice": prices[territory]![tier], "tier": tier],
                                         relationships: ["subscription": ("subscriptions", subscription), "territory": ("territories", territory)])
                order.append(id)
            }
        }
        return pricePoints(subscription: subscription)
    }

    /// An in-app purchase's points in the base territory, made on first ask.
    private func pricePoints(purchase: String) -> [Resource] {
        let existing = order.compactMap { resources[$0] }.filter {
            $0.type == "inAppPurchasePricePoints" && $0.relationships["inAppPurchase"]?.id == purchase
        }
        guard existing.isEmpty else { return existing }
        for (tier, price) in ["49.99", "99.99"].enumerated() {
            let id = "iap-point-\(purchase)-\(tier)"
            resources[id] = Resource(type: "inAppPurchasePricePoints", id: id, attributes: ["customerPrice": price],
                                     relationships: ["inAppPurchase": ("inAppPurchases", purchase), "territory": ("territories", "USA")])
            order.append(id)
        }
        return pricePoints(purchase: purchase)
    }

    /// A schedule replaces the purchase's last one, with a price for each
    /// inline one the request includes.
    private func createPriceSchedule(_ input: [String: Any]) -> (Int, Any?) {
        let data = input["data"] as? [String: Any] ?? [:]
        let relationships = data["relationships"] as? [String: Any] ?? [:]
        func linked(_ name: String) -> String? { ((relationships[name] as? [String: Any])?["data"] as? [String: Any])?["id"] as? String }
        guard let purchase = linked("inAppPurchase"), let base = linked("baseTerritory") else { return (409, nil) }
        for old in order.compactMap({ resources[$0] }) where old.type == "inAppPurchasePriceSchedules"
            && old.relationships["inAppPurchase"]?.id == purchase {
            resources.removeValue(forKey: old.id)
            order.removeAll { $0 == old.id }
        }
        let schedule = newID()
        resources[schedule] = Resource(type: "inAppPurchasePriceSchedules", id: schedule, attributes: [:],
                                       relationships: ["inAppPurchase": ("inAppPurchases", purchase), "baseTerritory": ("territories", base)])
        order.append(schedule)
        for included in input["included"] as? [[String: Any]] ?? [] {
            let point = (((included["relationships"] as? [String: Any])?["inAppPurchasePricePoint"] as? [String: Any])?["data"]
                as? [String: Any])?["id"] as? String ?? ""
            let price = newID()
            resources[price] = Resource(type: "inAppPurchasePrices", id: price, attributes: ["manual": true],
                                        relationships: ["schedule": ("inAppPurchasePriceSchedules", schedule),
                                                        "inAppPurchasePricePoint": ("inAppPurchasePricePoints", point),
                                                        "territory": ("territories", base)])
            order.append(price)
        }
        return (201, document(json(resources[schedule]!)))
    }

    /// A committed video reads as processing a while, then complete.
    private func advanceProcessing(_ resource: Resource) -> Resource {
        guard resource.type == "appAssetLibraryVideos", resource.attributes["state"] as? String == "UPLOAD_COMPLETE" else { return resource }
        var resource = resource
        let reads = (resource.attributes["reads"] as? Int ?? 0) + 1
        resource.attributes["reads"] = reads
        if reads > processingReads { resource.attributes["state"] = "COMPLETE" }
        resources[resource.id] = resource
        return resource
    }

    private func page(_ items: [Resource], query: [String: String], path: String) -> (Int, Any?) {
        let start = Int(query["cursor"] ?? "0") ?? 0
        let slice = Array(items.dropFirst(start).prefix(Self.pageSize))
        var links: [String: Any] = ["self": "https://api.appstoreconnect.apple.com\(path)"]
        if start + Self.pageSize < items.count {
            links["next"] = "https://api.appstoreconnect.apple.com\(path)?cursor=\(start + Self.pageSize)&limit=50"
        }
        // What `include` asks for, of what the page points at.
        let names = Set((query["include"] ?? "").split(separator: ",").map(String.init))
        let included = Set(slice.flatMap { item in names.compactMap { item.relationships[$0]?.id } }).sorted().compactMap { resources[$0] }
        var document: [String: Any] = ["data": slice.map(json), "links": links]
        if !included.isEmpty { document["included"] = included.map(json) }
        return (200, document)
    }

    // MARK: - Writes

    private static let localizationParents: [String: String] = [
        "appInfoLocalizations": "appInfo",
        "appStoreVersionLocalizations": "appStoreVersion",
        "subscriptionGroupLocalizations": "subscriptionGroup",
        "subscriptionLocalizations": "subscription",
        "appCustomProductPageLocalizations": "appCustomProductPageVersion",
        "inAppPurchaseLocalizations": "inAppPurchaseV2",
    ]

    private func create(_ type: String, _ data: [String: Any]) -> (Int, Any?) {
        var attributes = data["attributes"] as? [String: Any] ?? [:]
        var relationships: [String: (type: String, id: String)] = [:]
        var territories: [String] = []
        for (name, value) in data["relationships"] as? [String: Any] ?? [:] {
            let linkage = (value as? [String: Any])?["data"]
            if let one = linkage as? [String: Any], let type = one["type"] as? String, let id = one["id"] as? String {
                relationships[name] = (type, id)
            } else if let many = linkage as? [[String: Any]] {
                territories = many.compactMap { $0["id"] as? String }
            }
        }
        if let parentKey = Self.localizationParents[type], let locale = attributes["locale"] as? String {
            let parent = relationships[parentKey]?.id
            let duplicate = order.compactMap { resources[$0] }.contains {
                $0.type == type && $0.relationships[parentKey]?.id == parent && $0.attributes["locale"] as? String == locale
            }
            if duplicate {
                return (409, ["errors": [["status": "409", "code": "ENTITY_ERROR.DUPLICATE", "title": "Duplicate",
                                          "detail": "\(locale) already exists."]]])
            }
        }
        let id = newID()
        switch type {
        case "appScreenshots", "subscriptionAppStoreReviewScreenshots", "inAppPurchaseAppStoreReviewScreenshots", "appAssetLibraryVideos":
            let size = attributes["fileSize"] as? Int ?? 0
            let half = (size + 1) / 2
            attributes["uploadOperations"] = [
                ["method": "PUT", "url": "https://upload.example/\(id)/1", "offset": 0, "length": half, "requestHeaders": []],
                ["method": "PUT", "url": "https://upload.example/\(id)/2", "offset": half, "length": size - half, "requestHeaders": []],
            ]
            if type == "appAssetLibraryVideos" { attributes["state"] = "AWAITING_UPLOAD" }
            if type == "appScreenshots", let set = relationships["appScreenshotSet"]?.id { setOrder[set, default: []].append(id) }
        case "subscriptionPlanAvailabilities":
            attributes["territories"] = territories
        default:
            break
        }
        resources[id] = Resource(type: type, id: id, attributes: attributes, relationships: relationships)
        order.append(id)

        // App Store Connect makes the matching version localization when an
        // app info localization is created.
        if type == "appInfoLocalizations", let locale = attributes["locale"] {
            for version in order.compactMap({ resources[$0] }) where version.type == "appStoreVersions"
                && version.attributes["appStoreState"] as? String == "PREPARE_FOR_SUBMISSION" {
                let child = newID()
                resources[child] = Resource(type: "appStoreVersionLocalizations", id: child, attributes: ["locale": locale],
                                            relationships: ["appStoreVersion": ("appStoreVersions", version.id)])
                order.append(child)
            }
        }
        return (201, document(json(resources[id]!)))
    }

    /// A page arrives with its first version and localization, which the
    /// request names by local ids in `included`.
    private func createCustomPage(_ input: [String: Any]) -> (Int, Any?) {
        let data = input["data"] as? [String: Any] ?? [:]
        let attributes = data["attributes"] as? [String: Any] ?? [:]
        let app = ((data["relationships"] as? [String: Any])?["app"] as? [String: Any])?["data"] as? [String: Any]
        let page = newID()
        resources[page] = Resource(type: "appCustomProductPages", id: page,
                                   attributes: ["name": attributes["name"] ?? "", "visible": false,
                                                "url": "https://apps.apple.com/app/id1?ppid=\(page)"],
                                   relationships: ["app": ("apps", app?["id"] as? String ?? "")])
        order.append(page)
        let version = newID()
        resources[version] = Resource(type: "appCustomProductPageVersions", id: version,
                                      attributes: ["version": "1", "state": "PREPARE_FOR_SUBMISSION"],
                                      relationships: ["appCustomProductPage": ("appCustomProductPages", page)])
        order.append(version)
        for included in input["included"] as? [[String: Any]] ?? [] where included["type"] as? String == "appCustomProductPageLocalizations" {
            let localization = newID()
            resources[localization] = Resource(type: "appCustomProductPageLocalizations", id: localization,
                                               attributes: included["attributes"] as? [String: Any] ?? [:],
                                               relationships: ["appCustomProductPageVersion": ("appCustomProductPageVersions", version)])
            order.append(localization)
        }
        return (201, document(json(resources[page]!)))
    }

    /// A new version starts as a copy of the newest: its localizations, their
    /// keywords, and their screenshot sets with the same files.
    private func createCustomPageVersion(_ data: [String: Any]) -> (Int, Any?) {
        let page = (((data["relationships"] as? [String: Any])?["appCustomProductPage"] as? [String: Any])?["data"] as? [String: Any])?["id"] as? String ?? ""
        let versions = order.compactMap { resources[$0] }.filter {
            $0.type == "appCustomProductPageVersions" && $0.relationships["appCustomProductPage"]?.id == page
        }
        guard let newest = versions.last else { return notFound() }
        let version = newID()
        resources[version] = Resource(type: "appCustomProductPageVersions", id: version,
                                      attributes: ["version": "\(versions.count + 1)", "state": "PREPARE_FOR_SUBMISSION"],
                                      relationships: ["appCustomProductPage": ("appCustomProductPages", page)])
        order.append(version)
        for localization in order.compactMap({ resources[$0] }) where localization.type == "appCustomProductPageLocalizations"
            && localization.relationships["appCustomProductPageVersion"]?.id == newest.id {
            let copy = newID()
            resources[copy] = Resource(type: localization.type, id: copy, attributes: localization.attributes,
                                       relationships: ["appCustomProductPageVersion": ("appCustomProductPageVersions", version)])
            order.append(copy)
            assigned[copy] = assigned[localization.id]
            for set in order.compactMap({ resources[$0] }) where set.type == "appScreenshotSets"
                && set.relationships["appCustomProductPageLocalization"]?.id == localization.id {
                let setCopy = newID()
                resources[setCopy] = Resource(type: set.type, id: setCopy, attributes: set.attributes,
                                              relationships: ["appCustomProductPageLocalization": ("appCustomProductPageLocalizations", copy)])
                order.append(setCopy)
                setOrder[setCopy] = (setOrder[set.id] ?? []).compactMap { shot -> String? in
                    guard let screenshot = resources[shot] else { return nil }
                    let shotCopy = newID()
                    resources[shotCopy] = Resource(type: screenshot.type, id: shotCopy, attributes: screenshot.attributes,
                                                   relationships: ["appScreenshotSet": ("appScreenshotSets", setCopy)])
                    order.append(shotCopy)
                    return shotCopy
                }
            }
        }
        return (201, document(json(resources[version]!)))
    }

    private func update(_ id: String, _ data: [String: Any]) -> (Int, Any?) {
        guard var resource = resources[id] else { return notFound() }
        for (key, value) in data["attributes"] as? [String: Any] ?? [:] { resource.attributes[key] = value }
        if resource.attributes["uploaded"] as? Bool == true {
            resource.attributes.removeValue(forKey: "uploaded")
            resource.attributes.removeValue(forKey: "uploadOperations")
            let bytes = (1...2).compactMap { uploaded["/\(id)/\($0)"] }.reduce(Data(), +)
            resource.attributes["bytes"] = bytes.count
            if resource.type == "appAssetLibraryVideos" {
                resource.attributes["state"] = "UPLOAD_COMPLETE"
            } else {
                resource.attributes["assetDeliveryState"] = ["state": "COMPLETE"]
            }
        }
        resources[id] = resource
        return (200, document(json(resource)))
    }

    // MARK: - JSON

    private func json(_ resource: Resource) -> [String: Any] {
        var attributes = resource.attributes
        attributes.removeValue(forKey: "tier")
        attributes.removeValue(forKey: "reads")
        attributes.removeValue(forKey: "bytes")
        attributes.removeValue(forKey: "territories")
        var object: [String: Any] = ["type": resource.type, "id": resource.id, "attributes": attributes]
        if ["subscriptionPrices", "subscriptionPricePoints", "inAppPurchasePrices"].contains(resource.type) {
            object["relationships"] = resource.relationships.mapValues { ["data": ["type": $0.type, "id": $0.id]] }
        }
        return object
    }

    private func document(_ data: Any) -> [String: Any] {
        ["data": data, "links": ["self": "https://api.appstoreconnect.apple.com"]]
    }

    private func notFound() -> (Int, Any?) {
        (404, ["errors": [["status": "404", "code": "NOT_FOUND", "title": "Not found"]]])
    }
}
