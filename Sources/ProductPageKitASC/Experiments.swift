public import Foundation
import ProductPageKitCore

/// A product page optimization experiment App Store Connect holds.
public struct ExperimentRecord: Equatable, Sendable {
    public let id: String
    public let name: String
    public let state: String?
    public let trafficProportion: Int?
    public let startDate: Date?

    /// Once an experiment is submitted, approved or started, changing a
    /// treatment changes a test whose visitors are already counted. A start
    /// date means it has run, whatever its state says.
    public var isEditable: Bool { startDate == nil && Self.editableStates.contains(state ?? "") }

    public static let editableStates: Set<String> = ["PREPARE_FOR_SUBMISSION", "READY_FOR_REVIEW", "REJECTED", "DEVELOPER_REJECTED"]

    /// Throws `ExperimentNotEditable` unless the experiment can be edited.
    public func requireEditable() throws {
        guard isEditable else { throw ExperimentNotEditable(name: name, state: state, startDate: startDate) }
    }
}

/// One variant of an experiment's product page.
public struct TreatmentRecord: Equatable, Sendable {
    public let id: String
    public let name: String
}

/// A treatment's screenshots in one locale.
public struct TreatmentLocalization: Equatable, Sendable {
    public let id: String
    public let locale: String
}

/// An experiment that App Store Connect holds in a state that cannot be
/// edited. It is refused while the push is planned, before any write.
public struct ExperimentNotEditable: Error, CustomStringConvertible, Sendable {
    public let name: String
    /// Nil when App Store Connect gave none.
    public let state: String?
    public let startDate: Date?

    public var description: String {
        let started = startDate.map { " since \($0.formatted(.iso8601.year().month().day()))" } ?? ""
        let situation = state.map { "is \($0)\(started)" } ?? "exists and cannot be edited"
        return "The \(name) experiment \(situation), and changing a treatment would change a test that is running or in review. "
            + "Nothing was written. Stop or delete it in App Store Connect, or give the experiment another name."
    }
}

/// A name App Store Connect refused as another experiment's, which it did not
/// list when the push was planned.
public struct ExperimentNameTaken: Error, CustomStringConvertible, Sendable {
    public let name: String

    public var description: String {
        "App Store Connect already has an experiment named \(name), which it did not list when the push was planned, so none was created. "
            + "Run the push again, or give the experiment another name."
    }
}

/// App Store Connect creates an experiment only for an app that is on sale.
public struct AppNotOnSale: Error, CustomStringConvertible, Sendable {
    public var description: String {
        "App Store Connect creates an experiment only once the app has a live iOS version. Nothing was created."
    }
}

extension AppStoreConnect {
    /// The app's experiments, in every state.
    public func experiments(appID: String) async throws -> [ExperimentRecord] {
        try await all { cursor in
            let page = try await client.appsAppStoreVersionExperimentsV2GetToManyRelated(
                .init(path: .init(id: appID), query: .init(limit: 200, cursor: cursor))
            ).ok.body.json
            return (page.data.map { record in
                ExperimentRecord(id: record.id, name: record.attributes?.name ?? "", state: record.attributes?.state,
                                 trafficProportion: record.attributes?.trafficProportion, startDate: record.attributes?.startDate)
            }, page.links.next)
        }
    }

    /// Creates an experiment that has not started, and returns its id. App
    /// Store Connect starts a test only when asked to, which nothing here does.
    public func createExperiment(appID: String, name: String, trafficProportion: Int) async throws -> String {
        do {
            return try await call {
                try await client.appStoreVersionExperimentsV2CreateInstance(.init(body: .json(.init(data: .init(
                    attributes: .init(name: name, platform: StorePlatform.iOS.rawValue, trafficProportion: trafficProportion),
                    relationships: .init(app: .init(data: .init(id: appID, _type: .apps))),
                    _type: .appStoreVersionExperiments
                ))))).created.body.json.data.id
            }
        } catch let error as ASCError {
            if error.isDuplicate { throw ExperimentNameTaken(name: name) }
            if error.hasCode(containing: "PPO_CREATE_ONLY_ALLOWED_WITH_APP_STORE_DISTRIBUTION") { throw AppNotOnSale() }
            throw error
        }
    }

    public func updateExperiment(id: String, trafficProportion: Int) async throws {
        _ = try await call {
            try await client.appStoreVersionExperimentsV2UpdateInstance(.init(path: .init(id: id), body: .json(.init(data: .init(
                attributes: .init(trafficProportion: trafficProportion), id: id, _type: .appStoreVersionExperiments
            ))))).ok
        }
    }

    public func treatments(experimentID: String) async throws -> [TreatmentRecord] {
        try await all { cursor in
            let page = try await client.appStoreVersionExperimentsV2AppStoreVersionExperimentTreatmentsGetToManyRelated(
                .init(path: .init(id: experimentID), query: .init(limit: 200, cursor: cursor))
            ).ok.body.json
            return (page.data.map { TreatmentRecord(id: $0.id, name: $0.attributes?.name ?? "") }, page.links.next)
        }
    }

    public func createTreatment(experimentID: String, name: String) async throws -> String {
        try await call {
            try await client.appStoreVersionExperimentTreatmentsCreateInstance(.init(body: .json(.init(data: .init(
                attributes: .init(name: name),
                relationships: .init(appStoreVersionExperiment: .init(data: .init(id: experimentID, _type: .appStoreVersionExperiments))),
                _type: .appStoreVersionExperimentTreatments
            ))))).created.body.json.data.id
        }
    }

    /// The treatment's localizations, by App Store Connect locale.
    public func treatmentLocalizations(treatmentID: String) async throws -> [String: TreatmentLocalization] {
        let localizations = try await all { cursor in
            let page = try await client.appStoreVersionExperimentTreatmentsAppStoreVersionExperimentTreatmentLocalizationsGetToManyRelated(
                .init(path: .init(id: treatmentID), query: .init(limit: 200, cursor: cursor))
            ).ok.body.json
            return (page.data.map { TreatmentLocalization(id: $0.id, locale: $0.attributes?.locale ?? "") }, page.links.next)
        }
        return Dictionary(localizations.map { ($0.locale, $0) }, uniquingKeysWith: { first, _ in first })
    }

    public func createTreatmentLocalization(treatmentID: String, locale: String) async throws -> String {
        try await call {
            try await client.appStoreVersionExperimentTreatmentLocalizationsCreateInstance(.init(body: .json(.init(data: .init(
                attributes: .init(locale: locale),
                relationships: .init(appStoreVersionExperimentTreatment: .init(data: .init(
                    id: treatmentID, _type: .appStoreVersionExperimentTreatments
                ))),
                _type: .appStoreVersionExperimentTreatmentLocalizations
            ))))).created.body.json.data.id
        }
    }
}
