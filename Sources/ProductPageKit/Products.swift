import Foundation
import ProductPageKitASC
import ProductPageKitCore

/// Plans `products push`: App Store Connect's subscriptions and one-time
/// purchases made to match the catalogue. Products App Store Connect has and
/// the catalogue does not are reported, never removed.
struct ProductsPlanner {
    let project: Project
    let products: Products
    let catalogue: ProductCatalogue
    /// Every product's App Review note.
    let reviewNote: String?
    let screenshot: (name: String, data: Data)?
    let asc: AppStoreConnect

    func plan() async throws -> Plan {
        let app = try await asc.app(bundleID: project.bundleID)
        var plan = Plan()
        if let url = products.serverNotifications?.absoluteString {
            let wanted = ServerNotifications(url: url, version: "V2", sandboxURL: url, sandboxVersion: "V2")
            let changes = wanted.changes(from: app.notifications)
            if !changes.isEmpty {
                // The plan shows what changes, but App Store Connect takes a URL
                // only with its version, so every field goes.
                plan.add(Change(action: .update, subject: "App Store Server Notifications",
                                fields: changes.fieldChanges(from: app.notifications)) { run in
                    try await run.asc.updateNotifications(appID: app.id, wanted)
                })
            }
        }
        let territories = try await asc.territories()
        let live = try await asc.subscriptionGroups(appID: app.id)
        for group in catalogue.subscriptionGroups {
            plan = plan + (try await planGroup(group, live: live.first { $0.referenceName == group.referenceName },
                                               appID: app.id, territories: territories))
        }
        let purchases = try await asc.inAppPurchases(appID: app.id)
        for purchase in catalogue.inAppPurchases {
            plan = plan + (try await planPurchase(purchase, live: purchases.first { $0.productID == purchase.productID },
                                                  appID: app.id, territories: territories))
        }
        let known = Set(catalogue.inAppPurchases.map(\.productID))
        for extra in purchases where !known.contains(extra.productID) {
            plan.warn("\(extra.productID) is in App Store Connect and not in the catalogue")
        }
        return plan
    }

    func planPurchase(_ purchase: ProductCatalogue.InAppPurchase, live: InAppPurchase?, appID: String,
                      territories: [String]) async throws -> Plan {
        var plan = Plan()
        let subject = purchase.productID
        let wanted = InAppPurchaseSettings(referenceName: purchase.referenceName, reviewNote: reviewNote)
        let ref: Ref
        if let live {
            if let kind = live.kind, kind != purchase.kind.rawValue {
                throw Stopped(description: "\(subject) is \(kind) in App Store Connect and \(purchase.kind.rawValue) in the catalogue. A kind cannot change once created, so this needs a new product.")
            }
            if live.familySharable, !purchase.familySharable {
                plan.warn("\(subject) has Family Sharing on, which App Store Connect cannot turn off")
            }
            ref = .existing(live.id)
            let changes = wanted.changes(from: live.settings)
            let sharing = purchase.familySharable && !live.familySharable
            if !changes.isEmpty || sharing {
                var fields = changes.fieldChanges(from: live.settings)
                if sharing { fields.append(FieldChange(name: "familySharable", old: "false", new: "true")) }
                plan.add(Change(action: .update, subject: subject, fields: fields) { run in
                    try await run.asc.updateInAppPurchase(id: live.id, changes, familySharable: sharing ? true : nil)
                })
            }
        } else {
            let key = "in-app purchase \(subject)"
            ref = .planned(key)
            var fields = wanted.fieldChanges(from: nil)
            fields.insert(FieldChange(name: "kind", old: nil, new: purchase.kind.rawValue), at: 0)
            if purchase.familySharable { fields.append(FieldChange(name: "familySharable", old: nil, new: "true")) }
            plan.add(Change(action: .create, subject: subject, fields: fields, creates: key) { run in
                await run.record(key, id: try await run.asc.createInAppPurchase(
                    appID: appID, productID: subject, kind: purchase.kind.rawValue, familySharable: purchase.familySharable,
                    settings: wanted))
            })
        }

        let localizations = try await live.asyncMap { try await asc.inAppPurchaseLocalizations(purchaseID: $0.id) } ?? [:]
        for (code, text) in purchase.localizations.sorted(by: { $0.key < $1.key }) {
            guard let locale = storeLocale(code) else { continue }
            let wantedText = ProductText(name: text.name, description: text.description)
            if let existing = localizations[locale.store] {
                let changes = wantedText.changes(from: existing.text)
                guard !changes.isEmpty else { continue }
                plan.add(Change(action: .update, subject: "\(subject) · \(locale.store)", fields: changes.fieldChanges(from: existing.text)) { run in
                    try await run.asc.updateInAppPurchaseLocalization(id: existing.id, changes)
                })
            } else {
                plan.add(Change(action: .create, subject: "\(subject) · \(locale.store)", fields: wantedText.fieldChanges(from: nil)) { run in
                    try await run.asc.createInAppPurchaseLocalization(purchaseID: try await run.id(ref), locale: locale.store, text: wantedText)
                })
            }
        }

        let available = try await live.asyncMap { try await asc.hasInAppPurchaseAvailability(purchaseID: $0.id) } ?? false
        if !available {
            plan.add(Change(action: .create, subject: "\(subject) availability", lines: ["all \(territories.count) territories, and new ones"]) { run in
                try await run.asc.createInAppPurchaseAvailability(purchaseID: try await run.id(ref), territories: territories)
            })
        }
        if let price = try await planPrice(purchase, live: live, ref: ref) { plan.add(price) }
        if let screenshot = try await planPurchaseScreenshot(subject, live: live, ref: ref) { plan.add(screenshot) }
        return plan
    }

    /// The base territory's price set by hand, which App Store Connect
    /// equalises everywhere else. A new purchase's price points can only be
    /// read once it exists, so they are looked up when the change is applied.
    func planPrice(_ purchase: ProductCatalogue.InAppPurchase, live: InAppPurchase?, ref: Ref) async throws -> Change? {
        let base = products.baseTerritory
        let price = purchase.price
        let subject = "\(purchase.productID) price"
        let line = "\(price) in \(base), equalised in every other territory"
        guard let live else {
            return Change(action: .create, subject: subject, lines: [line]) { run in
                let id = try await run.id(ref)
                let point = try await Self.pricePoint(run.asc, purchaseID: id, price: price, base: base)
                try await run.asc.setInAppPurchasePrice(purchaseID: id, territory: base, pricePointID: point)
            }
        }
        let point = try await Self.pricePoint(asc, purchaseID: live.id, price: price, base: base)
        let current = try await asc.inAppPurchaseBasePrice(purchaseID: live.id)
        guard current?.territory != base || current?.pricePointID != point else { return nil }
        return Change(action: current == nil ? .create : .update, subject: subject, lines: [line]) { run in
            try await run.asc.setInAppPurchasePrice(purchaseID: live.id, territory: base, pricePointID: point)
        }
    }

    /// The purchase's price point at `price` in the base territory.
    static func pricePoint(_ asc: AppStoreConnect, purchaseID: String, price: String, base: String) async throws -> String {
        // Compared as amounts: App Store Connect writes 79 kroner as "79.0".
        guard let point = try await asc.inAppPurchasePricePoints(purchaseID: purchaseID, territory: base)
            .first(where: { $0.customerPrice.flatMap { Decimal(string: $0) } == Decimal(string: price) }) else {
            throw Stopped(description: "App Store Connect has no \(price) price point in \(base).")
        }
        return point.id
    }

    func planPurchaseScreenshot(_ subject: String, live: InAppPurchase?, ref: Ref) async throws -> Change? {
        guard let screenshot else { return nil }
        let current = try await live.asyncMap { try await asc.inAppPurchaseReviewScreenshot(purchaseID: $0.id) } ?? nil
        if let current, current.checksum == AppStoreConnect.md5(screenshot.data) { return nil }
        return Change(action: current == nil ? .upload : .replace, subject: "\(subject) App Review screenshot",
                      lines: [screenshot.name]) { run in
            if let current { try await run.asc.deleteInAppPurchaseReviewScreenshot(id: current.id) }
            try await run.asc.uploadInAppPurchaseReviewScreenshot(purchaseID: try await run.id(ref),
                                                                  fileName: screenshot.name, data: screenshot.data)
        }
    }

    func storeLocale(_ code: String) -> StoreLocale? { project.locale(code) }

    func planGroup(_ group: ProductCatalogue.SubscriptionGroup, live: SubscriptionGroup?, appID: String,
                   territories: [String]) async throws -> Plan {
        var plan = Plan()
        let subject = "Group \(group.referenceName)"
        let ref: Ref
        if let live {
            ref = .existing(live.id)
        } else {
            let key = "group \(group.referenceName)"
            ref = .planned(key)
            plan.add(Change(action: .create, subject: subject, creates: key) { run in
                await run.record(key, id: try await run.asc.createSubscriptionGroup(appID: appID, referenceName: group.referenceName))
            })
        }

        let localizations = try await live.asyncMap { try await asc.subscriptionGroupLocalizations(groupID: $0.id) } ?? []
        for (code, text) in group.localizations.sorted(by: { $0.key < $1.key }) {
            guard let locale = storeLocale(code) else { continue }
            let field = [FieldChange(name: "name", old: nil, new: text.name, isSecret: false)]
            if let existing = localizations.first(where: { $0.locale == locale.store }) {
                guard existing.name != text.name else { continue }
                plan.add(Change(action: .update, subject: "\(subject) · \(locale.store)",
                                fields: [FieldChange(name: "name", old: existing.name, new: text.name, isSecret: false)]) { run in
                    try await run.asc.renameSubscriptionGroupLocalization(id: existing.id, name: text.name)
                })
            } else {
                plan.add(Change(action: .create, subject: "\(subject) · \(locale.store)", fields: field) { run in
                    try await run.asc.createSubscriptionGroupLocalization(groupID: try await run.id(ref), locale: locale.store, name: text.name)
                })
            }
        }

        let subscriptions = try await live.asyncMap { try await asc.subscriptions(groupID: $0.id) } ?? []
        for subscription in group.subscriptions {
            plan = plan + (try await planSubscription(subscription, live: subscriptions.first { $0.productID == subscription.productID },
                                                      group: ref, territories: territories))
        }
        let known = Set(group.subscriptions.map(\.productID))
        for extra in subscriptions where !known.contains(extra.productID) {
            plan.warn("\(extra.productID) is in App Store Connect and not in the catalogue")
        }
        return plan
    }

    func planSubscription(_ subscription: ProductCatalogue.Subscription, live: Subscription?, group: Ref,
                          territories: [String]) async throws -> Plan {
        var plan = Plan()
        let subject = subscription.productID
        let wanted = SubscriptionSettings(referenceName: subscription.referenceName, level: subscription.level, reviewNote: reviewNote)
        let ref: Ref
        if let live {
            if let period = live.period, period != subscription.period.rawValue {
                throw Stopped(description: "\(subject) is \(period) in App Store Connect and \(subscription.period.rawValue) in the catalogue. A period cannot change once created, so this needs a new product.")
            }
            if live.familySharable, !subscription.familySharable {
                plan.warn("\(subject) has Family Sharing on, which App Store Connect cannot turn off")
            }
            ref = .existing(live.id)
            let changes = wanted.changes(from: live.settings)
            let sharing = subscription.familySharable && !live.familySharable
            if !changes.isEmpty || sharing {
                var fields = changes.fieldChanges(from: live.settings)
                if sharing { fields.append(FieldChange(name: "familySharable", old: "false", new: "true")) }
                plan.add(Change(action: .update, subject: subject, fields: fields) { run in
                    try await run.asc.updateSubscription(id: live.id, changes, familySharable: sharing ? true : nil)
                })
            }
        } else {
            let key = "subscription \(subject)"
            ref = .planned(key)
            var fields = wanted.fieldChanges(from: nil)
            fields.insert(FieldChange(name: "period", old: nil, new: subscription.period.rawValue, isSecret: false), at: 0)
            if subscription.familySharable { fields.append(FieldChange(name: "familySharable", old: nil, new: "true")) }
            plan.add(Change(action: .create, subject: subject, fields: fields, creates: key) { run in
                await run.record(key, id: try await run.asc.createSubscription(
                    groupID: try await run.id(group), productID: subscription.productID,
                    period: subscription.period.rawValue, familySharable: subscription.familySharable, settings: wanted))
            })
        }

        let localizations = try await live.asyncMap { try await asc.subscriptionLocalizations(subscriptionID: $0.id) } ?? [:]
        for (code, text) in subscription.localizations.sorted(by: { $0.key < $1.key }) {
            guard let locale = storeLocale(code) else { continue }
            let wantedText = ProductText(name: text.name, description: text.description)
            if let existing = localizations[locale.store] {
                let changes = wantedText.changes(from: existing.text)
                guard !changes.isEmpty else { continue }
                plan.add(Change(action: .update, subject: "\(subject) · \(locale.store)", fields: changes.fieldChanges(from: existing.text)) { run in
                    try await run.asc.updateSubscriptionLocalization(id: existing.id, changes)
                })
            } else {
                plan.add(Change(action: .create, subject: "\(subject) · \(locale.store)", fields: wantedText.fieldChanges(from: nil)) { run in
                    try await run.asc.createSubscriptionLocalization(subscriptionID: try await run.id(ref), locale: locale.store, text: wantedText)
                })
            }
        }

        let available = try await live.asyncMap { try await asc.hasSubscriptionAvailability(subscriptionID: $0.id) } ?? false
        if !available { plan.add(availability(subject, ref: ref, territories: territories)) }

        if let prices = try await planPrices(subscription, live: live, ref: ref) { plan.add(prices) }
        plan = plan + (try await planIntroductoryOffer(subscription, live: live, ref: ref, territories: territories))
        if let screenshot = try await planScreenshot(subject, live: live, ref: ref) { plan.add(screenshot) }
        return plan
    }

    /// The catalogue's free trial in every territory the subscription is sold
    /// in. An offer App Store Connect can't edit is replaced: a trial of
    /// another length, or a paid offer. Without one in the catalogue, any
    /// App Store Connect has is reported and left alone.
    func planIntroductoryOffer(_ subscription: ProductCatalogue.Subscription, live: Subscription?, ref: Ref,
                               territories: [String]) async throws -> Plan {
        var plan = Plan()
        let subject = "\(subscription.productID) introductory offer"
        let current = try await live.asyncMap { try await asc.introductoryOffers(subscriptionID: $0.id) } ?? []
        guard let offer = subscription.introductoryOffer else {
            if !current.isEmpty {
                plan.warn("\(subscription.productID) has introductory offers in App Store Connect and none in the catalogue")
            }
            return plan
        }
        let duration = offer.duration.rawValue
        let stale = current.filter {
            $0.mode != ProductCatalogue.IntroductoryOffer.freeTrialMode || $0.duration != duration || $0.numberOfPeriods != 1
        }
        let covered = Set(current.filter { !stale.contains($0) }.compactMap(\.territory))
        let missing = territories.filter { !covered.contains($0) }
        guard !missing.isEmpty || !stale.isEmpty else { return plan }
        var lines = ["free trial, \(duration), in \(missing.count) territories"]
        if !stale.isEmpty { lines.append("replacing \(stale.count) other offers") }
        plan.add(Change(action: current.isEmpty ? .create : .update, subject: subject, lines: lines) { run in
            for old in stale { try await run.asc.deleteIntroductoryOffer(id: old.id) }
            let id = try await run.id(ref)
            for territory in missing {
                try await run.asc.createFreeTrial(subscriptionID: id, territory: territory, duration: duration)
            }
        })
        return plan
    }

    func availability(_ subject: String, ref: Ref, territories: [String]) -> Change {
        Change(action: .create, subject: "\(subject) availability", lines: ["all \(territories.count) territories, and new ones"]) { run in
            try await run.asc.createSubscriptionAvailability(subscriptionID: try await run.id(ref), territories: territories)
        }
    }

    /// The base territory's price and Apple's equalised price everywhere
    /// else. For a new subscription the price points can only be read once it
    /// exists, so they are looked up when the change is applied.
    func planPrices(_ subscription: ProductCatalogue.Subscription, live: Subscription?, ref: Ref) async throws -> Change? {
        let base = products.baseTerritory
        let price = subscription.price
        let subject = "\(subscription.productID) prices"
        guard let live else {
            return Change(action: .create, subject: subject, lines: ["\(price) in \(base), equalised in every other territory"]) { run in
                let id = try await run.id(ref)
                let wanted = try await Self.wantedPrices(run.asc, subscriptionID: id, price: price, base: base)
                for (territory, point) in wanted.sorted(by: { $0.key < $1.key }) {
                    try await run.asc.createSubscriptionPrice(subscriptionID: id, pricePointID: point.id, territory: territory)
                }
            }
        }
        let wanted = try await Self.wantedPrices(asc, subscriptionID: live.id, price: price, base: base)
        let current = try await asc.prices(subscriptionID: live.id)
        let changed = wanted.filter { current[$0.key]?.id != $0.value.id }.sorted { $0.key < $1.key }
        guard !changed.isEmpty else { return nil }
        // Each territory with what new subscribers pay now and would pay.
        let lines = changed.map { territory, point in
            "\(territory): \(current[territory]?.customerPrice ?? "no price") → \(point.customerPrice ?? "?")"
        }
        return Change(action: .update, subject: subject, lines: ["\(price) in \(base), equalised elsewhere"] + lines) { run in
            for (territory, point) in changed {
                try await run.asc.createSubscriptionPrice(subscriptionID: live.id, pricePointID: point.id, territory: territory)
            }
        }
    }

    /// Price point by territory: the base territory's point at `price`, and
    /// its equalisations.
    static func wantedPrices(_ asc: AppStoreConnect, subscriptionID: String, price: String, base: String) async throws -> [String: PricePoint] {
        // Compared as amounts: App Store Connect writes 79 kroner as "79.0".
        guard let point = try await asc.pricePoints(subscriptionID: subscriptionID, territory: base)
            .first(where: { $0.customerPrice.flatMap { Decimal(string: $0) } == Decimal(string: price) }) else {
            throw Stopped(description: "App Store Connect has no \(price) price point in \(base).")
        }
        var wanted = [base: point]
        for equalization in try await asc.equalizations(pricePointID: point.id) {
            if let territory = equalization.territory { wanted[territory] = equalization }
        }
        return wanted
    }

    func planScreenshot(_ subject: String, live: Subscription?, ref: Ref) async throws -> Change? {
        guard let screenshot else { return nil }
        let current = try await live.asyncMap { try await asc.subscriptionReviewScreenshot(subscriptionID: $0.id) } ?? nil
        if let current, current.checksum == AppStoreConnect.md5(screenshot.data) { return nil }
        return Change(action: current == nil ? .upload : .replace, subject: "\(subject) App Review screenshot",
                      lines: [screenshot.name]) { run in
            if let current { try await run.asc.deleteProductReviewScreenshot(id: current.id) }
            try await run.asc.uploadProductReviewScreenshot(subscriptionID: try await run.id(ref),
                                                                 fileName: screenshot.name, data: screenshot.data)
        }
    }
}
