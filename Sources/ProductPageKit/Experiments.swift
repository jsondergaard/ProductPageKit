import Foundation
import ProductPageKitASC
import ProductPageKitCore

/// Plans `experiments push`: each experiment made to hold its treatments, and
/// each treatment its framed screenshots in every locale, on iPhone and iPad.
///
/// An experiment is found by name and created when missing, as it stands: not
/// started, not submitted. One App Store Connect has started, or has in
/// review or approved, is refused, and nothing is written for any experiment,
/// since a treatment changed under a running test spoils what it has
/// counted. Nothing here starts an experiment, submits one, or sets its state.
struct ExperimentsPlanner {
    let project: Project
    let experiments: [Experiment]
    /// The treatments' framed screenshots.
    let screenshots: [FramedScreenshot]
    /// The locales written. A treatment lacking another locale shows the
    /// control there, which the plan warns of.
    let locales: [StoreLocale]
    let asc: AppStoreConnect

    func plan() async throws -> Plan {
        let app = try await asc.app(bundleID: project.bundleID)
        let records = try await asc.experiments(appID: app.id)
        var plan = Plan()
        for experiment in experiments {
            plan = plan + (try await self.plan(experiment, record: records.first { $0.name == experiment.name }, appID: app.id))
        }
        return plan
    }

    /// What a treatment's localization holds now.
    private struct Current {
        let localization: TreatmentLocalization
        /// By display type.
        let sets: [String: StoredSet]
    }

    private func plan(_ experiment: Experiment, record: ExperimentRecord?, appID: String) async throws -> Plan {
        var plan = Plan()
        let subject = "\(experiment.name) experiment"
        let traffic = "\(experiment.trafficProportion)"
        let experimentRef: Ref
        var treatments: [TreatmentRecord] = []
        if let record {
            try record.requireEditable()
            experimentRef = .existing(record.id)
            treatments = try await asc.treatments(experimentID: record.id)
            if record.trafficProportion != experiment.trafficProportion {
                plan.add(Change(action: .update, subject: subject,
                                fields: [FieldChange(name: "trafficProportion", old: record.trafficProportion.map(String.init), new: traffic)]) { run in
                    try await run.asc.updateExperiment(id: record.id, trafficProportion: experiment.trafficProportion)
                })
            }
        } else {
            experimentRef = .planned(subject)
            plan.add(Change(action: .create, subject: subject, fields: [FieldChange(name: "trafficProportion", old: nil, new: traffic)],
                            lines: ["not started, and not submitted for review"], creates: subject) { run in
                await run.record(subject, id: try await run.asc.createExperiment(
                    appID: appID, name: experiment.name, trafficProportion: experiment.trafficProportion))
            })
        }

        let listed = Set(experiment.treatments.map(\.name))
        let unlisted = treatments.filter { !listed.contains($0.name) }
        guard unlisted.count + experiment.treatments.count <= Experiment.maximumTreatments else {
            throw Stopped(description: "\(subject) in App Store Connect also has \(unlisted.map(\.name).joined(separator: ", ")), "
                          + "which the project does not list, and App Store Connect takes \(Experiment.maximumTreatments) treatments. "
                          + "Nothing was written. Delete them in App Store Connect, or list them in the project.")
        }
        for treatment in unlisted {
            plan.warn("\(subject) · \(treatment.name) is in App Store Connect and not in the project, so it is left as it is")
        }
        for treatment in experiment.treatments {
            plan = plan + (try await self.plan(treatment, of: experiment, ref: experimentRef,
                                               record: treatments.first { $0.name == treatment.name }))
        }
        return plan
    }

    private func plan(_ treatment: Treatment, of experiment: Experiment, ref experimentRef: Ref, record: TreatmentRecord?) async throws -> Plan {
        var plan = Plan()
        let key = "\(experiment.name) experiment · \(treatment.name)"
        let treatmentRef: Ref
        var current: [String: Current] = [:]
        if let record {
            treatmentRef = .existing(record.id)
            current = try await self.current(treatmentID: record.id)
        } else {
            treatmentRef = .planned(key)
            plan.add(Change(action: .create, subject: key, creates: key) { run in
                await run.record(key, id: try await run.asc.createTreatment(experimentID: try await run.id(experimentRef), name: treatment.name))
            })
        }

        for locale in locales {
            let localizationKey = "\(key) · \(locale.store)"
            let localization: Ref
            let stored: StoredSets
            if let now = current[locale.store] {
                localization = .existing(now.localization.id)
                stored = .stored(now.sets)
            } else {
                localization = .planned(localizationKey)
                // App Store Connect fills a new localization with the
                // control's screenshot sets in its locale.
                stored = .filled(by: "the control")
                plan.add(Change(action: .create, subject: localizationKey, creates: localizationKey) { run in
                    await run.record(localizationKey, id: try await run.asc.createTreatmentLocalization(
                        treatmentID: try await run.id(treatmentRef), locale: locale.store))
                })
            }
            plan.syncSets(localizationKey, try screenshots.sets(of: treatment.list, on: project.alternatePlatforms, in: locale),
                          stored: stored, owner: ScreenshotSetOwner.treatment, localization: localization)
        }

        let uncovered = project.locales.filter { locale in
            !locales.contains(locale) && !project.alternatePlatforms.allSatisfy {
                current[locale.store]?.sets[$0.displayType]?.screenshots.isEmpty == false
            }
        }
        if !uncovered.isEmpty {
            plan.warn("\(key) does not cover \(uncovered.map(\.store).joined(separator: ", ")), where visitors shown the treatment "
                      + "see the control but still count in its share of the test; push those locales too")
        }
        return plan
    }

    private func current(treatmentID: String) async throws -> [String: Current] {
        var current: [String: Current] = [:]
        for (locale, localization) in try await asc.treatmentLocalizations(treatmentID: treatmentID) {
            current[locale] = Current(localization: localization, sets: try await asc.storedSets(.treatment(localization.id)))
        }
        return current
    }
}
