import Foundation
import Testing
@testable import ProductPageKitASC

/// The experiment requests as App Store Connect takes them, and the states in
/// which one may be edited at all.
@Suite struct ExperimentsClientTests {
    func body(_ transport: ScriptedTransport, _ index: Int = 0) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: transport.sent[index].body) as! [String: Any]
    }

    func data(_ transport: ScriptedTransport, _ index: Int = 0) throws -> [String: Any] {
        try body(transport, index)["data"] as! [String: Any]
    }

    func ids(_ relationship: String, in data: [String: Any]) -> [String: String] {
        let linkage = ((data["relationships"] as! [String: Any])[relationship] as! [String: Any])["data"] as! [String: String]
        return linkage
    }

    func created(_ type: String) -> (Int, String) {
        (201, #"{"data": {"type": "\#(type)", "id": "new"}, "links": {"self": "x"}}"#)
    }

    @Test func anExperimentIsCreatedOnIOSAtItsShareAndWithoutAState() async throws {
        let transport = ScriptedTransport([created("appStoreVersionExperiments")])
        let asc = AppStoreConnect(credentials: credentials(), transport: transport)
        #expect(try await asc.createExperiment(appID: "app1", name: "Story set", trafficProportion: 40) == "new")
        #expect(transport.sent[0].request.method == .post)
        #expect(transport.sent[0].request.path == "/v2/appStoreVersionExperiments")
        let data = try data(transport)
        #expect(data["type"] as? String == "appStoreVersionExperiments")
        let attributes = data["attributes"] as! [String: Any]
        #expect(attributes["name"] as? String == "Story set")
        #expect(attributes["platform"] as? String == "IOS")
        #expect(attributes["trafficProportion"] as? Int == 40)
        #expect(Set(attributes.keys) == ["name", "platform", "trafficProportion"])
        #expect(ids("app", in: data) == ["type": "apps", "id": "app1"])
    }

    /// The one attribute that starts a test is `started`, which is never sent.
    @Test func changingTheShareSendsNothingElse() async throws {
        let transport = ScriptedTransport([(200, #"{"data": {"type": "appStoreVersionExperiments", "id": "e1"}, "links": {"self": "x"}}"#)])
        try await AppStoreConnect(credentials: credentials(), transport: transport).updateExperiment(id: "e1", trafficProportion: 25)
        #expect(transport.sent[0].request.method == .patch)
        #expect(transport.sent[0].request.path == "/v2/appStoreVersionExperiments/e1")
        #expect((try data(transport)["attributes"] as! [String: Any]).keys.sorted() == ["trafficProportion"])
    }

    @Test func aTreatmentAndItsLocalizationHangOffTheirParents() async throws {
        let transport = ScriptedTransport([created("appStoreVersionExperimentTreatments"),
                                           created("appStoreVersionExperimentTreatmentLocalizations"),
                                           created("appScreenshotSets")])
        let asc = AppStoreConnect(credentials: credentials(), transport: transport)
        _ = try await asc.createTreatment(experimentID: "e1", name: "Story")
        _ = try await asc.createTreatmentLocalization(treatmentID: "t1", locale: "da")
        _ = try await asc.createScreenshotSet(.treatment("l1"), displayType: "APP_IPAD_PRO_3GEN_129")

        #expect(transport.sent.map(\.request.path) == ["/v1/appStoreVersionExperimentTreatments",
                                                        "/v1/appStoreVersionExperimentTreatmentLocalizations", "/v1/appScreenshotSets"])
        let treatment = try data(transport, 0)
        #expect((treatment["attributes"] as! [String: Any]).keys.sorted() == ["name"])
        #expect(ids("appStoreVersionExperiment", in: treatment) == ["type": "appStoreVersionExperiments", "id": "e1"])
        let localization = try data(transport, 1)
        #expect((localization["attributes"] as! [String: Any])["locale"] as? String == "da")
        #expect(ids("appStoreVersionExperimentTreatment", in: localization) == ["type": "appStoreVersionExperimentTreatments", "id": "t1"])
        let set = try data(transport, 2)
        #expect((set["attributes"] as! [String: Any])["screenshotDisplayType"] as? String == "APP_IPAD_PRO_3GEN_129")
        #expect(ids("appStoreVersionExperimentTreatmentLocalization", in: set)
            == ["type": "appStoreVersionExperimentTreatmentLocalizations", "id": "l1"])
    }

    @Test func readsAnExperimentsStateAndStartDate() async throws {
        let transport = ScriptedTransport([(200, """
            {"data": [
              {"type": "appStoreVersionExperiments", "id": "e1", "attributes": {"name": "A", "state": "APPROVED", "trafficProportion": 50,
               "startDate": "2026-10-01T10:00:00.000-07:00"}},
              {"type": "appStoreVersionExperiments", "id": "e2", "attributes": {"name": "B", "state": "PREPARE_FOR_SUBMISSION"}}
            ], "links": {"self": "x"}}
            """)])
        let experiments = try await AppStoreConnect(credentials: credentials(), transport: transport).experiments(appID: "app1")
        #expect(transport.sent[0].request.path?.hasPrefix("/v1/apps/app1/appStoreVersionExperimentsV2") == true)
        #expect(experiments.map(\.name) == ["A", "B"])
        #expect(experiments[0].trafficProportion == 50)
        #expect(experiments[0].startDate != nil)
        #expect(experiments[1].startDate == nil)
        #expect(experiments.map(\.isEditable) == [false, true])
    }

    @Test(arguments: ["PREPARE_FOR_SUBMISSION", "READY_FOR_REVIEW", "REJECTED", "DEVELOPER_REJECTED"])
    func anExperimentThatHasNotGoneToReviewMayBeEdited(state: String) throws {
        let record = ExperimentRecord(id: "e", name: "A", state: state, trafficProportion: 50, startDate: nil)
        #expect(record.isEditable)
        try record.requireEditable()
    }

    @Test(arguments: ["WAITING_FOR_REVIEW", "IN_REVIEW", "ACCEPTED", "APPROVED", "COMPLETED", "STOPPED", "", "SOMETHING_NEW"])
    func anyOtherExperimentMayNot(state: String) {
        let record = ExperimentRecord(id: "e", name: "A", state: state, trafficProportion: 50, startDate: nil)
        #expect(!record.isEditable)
        #expect(throws: ExperimentNotEditable.self) { try record.requireEditable() }
        #expect(!ExperimentRecord(id: "e", name: "A", state: nil, trafficProportion: nil, startDate: nil).isEditable)
    }

    @Test func aStartDateMeansItHasRunWhateverItsStateSays() {
        #expect(!ExperimentRecord(id: "e", name: "A", state: "REJECTED", trafficProportion: 50, startDate: Date()).isEditable)
    }

    @Test func refusingSaysWhyAndWhatToDo() {
        let started = Date(timeIntervalSince1970: 1_790_000_000)
        #expect(ExperimentNotEditable(name: "Story set", state: "APPROVED", startDate: started).description
            == "The Story set experiment is APPROVED since 2026-09-21, and changing a treatment would change a test that is running or in review. "
            + "Nothing was written. Stop or delete it in App Store Connect, or give the experiment another name.")
        #expect(ExperimentNotEditable(name: "Story set", state: nil, startDate: nil).description.hasPrefix("The Story set experiment exists and cannot be edited,"))
    }

    @Test func aNameAppStoreConnectAlreadyHasIsAnExperimentItWillNotLetBeEdited() async throws {
        let transport = ScriptedTransport([(409, """
            {"errors": [{"status": "409", "code": "ENTITY_ERROR.ATTRIBUTE.INVALID.DUPLICATE", "title": "Duplicate name"}]}
            """)])
        let asc = AppStoreConnect(credentials: credentials(), transport: transport)
        await #expect(throws: ExperimentNotEditable.self) { try await asc.createExperiment(appID: "app1", name: "Story set", trafficProportion: 50) }
    }

    @Test func anAppNotOnSaleIsSaidSo() async throws {
        let transport = ScriptedTransport([(409, """
            {"errors": [{"status": "409", "code": "STATE_ERROR.PPO_CREATE_ONLY_ALLOWED_WITH_APP_STORE_DISTRIBUTION", "title": "No live version"}]}
            """)])
        let asc = AppStoreConnect(credentials: credentials(), transport: transport)
        await #expect(throws: AppNotOnSale.self) { try await asc.createExperiment(appID: "app1", name: "Story set", trafficProportion: 50) }
    }

    @Test func anyOtherRefusalIsAppStoreConnectsOwn() async throws {
        let transport = ScriptedTransport([(422, #"{"errors": [{"status": "422", "code": "ENTITY_ERROR.ATTRIBUTE.INVALID", "title": "Bad share"}]}"#)])
        let asc = AppStoreConnect(credentials: credentials(), transport: transport)
        await #expect(throws: ASCError.self) { try await asc.createExperiment(appID: "app1", name: "Story set", trafficProportion: 500) }
    }
}
