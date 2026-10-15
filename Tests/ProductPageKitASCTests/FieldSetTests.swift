import Testing
@testable import ProductPageKitASC

@Suite struct FieldSetTests {
    @Test func changesKeepOnlyWantedValuesThatDiffer() {
        var live = ReviewInfo()
        live.notes = "Old"
        live.demoAccountName = "review@example.com"
        var wanted = ReviewInfo()
        wanted.notes = "New"
        wanted.demoAccountName = "review@example.com"
        wanted.demoAccountRequired = true
        let changes = wanted.changes(from: live)
        #expect(changes.notes == "New")
        #expect(changes.demoAccountName == nil)
        #expect(changes.demoAccountRequired == true)
        #expect(wanted.changes(from: wanted).isEmpty)
    }

    @Test func fieldChangesNameEverySetValueAndHideSecrets() {
        var wanted = ReviewInfo()
        wanted.notes = "New"
        wanted.demoAccountPassword = "s3cret"
        #expect(wanted.fieldChanges(from: nil) == [
            FieldChange(name: "notes", old: nil, new: "New"),
            FieldChange(name: "demoAccountPassword", old: nil, new: "s3cret", isSecret: true),
        ])
    }

    @Test func aWholeLiveRecordIsAChangeFromNothing() {
        var text = ProductText()
        text.name = "Plus"
        #expect(text.changes(from: nil) == text)
    }
}
