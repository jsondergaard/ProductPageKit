import Foundation
import Testing
@testable import ProductPageKitCore

@Suite struct StoreCopyTests {
    let en = StoreLocale("en", store: "en-US")
    let da = StoreLocale("da", store: "da")

    func copy() -> StoreCopy {
        var copy = StoreCopy(project: project(locales: [en, da]), catalog: StringCatalog(sourceLanguage: "en"))
        copy.set("Example", field: .name, locale: en)
        copy.set("Alerts that ring", field: .subtitle, locale: en)
        copy.set("push,pager", field: .keywords, locale: en)
        copy.set("New.", field: .promotionalText, locale: en)
        copy.set("Terms: https://example.com/terms", field: .description, locale: en)
        copy.set("Sign in with the demo account.", field: .reviewNotes, locale: en)
        copy.set("Eksempel", field: .name, locale: da)
        copy.set("Alarmer der ringer", field: .subtitle, locale: da)
        copy.set("push,personsøger", field: .keywords, locale: da)
        copy.set("Nyt.", field: .promotionalText, locale: da)
        copy.set("Vilkår: https://example.com/terms", field: .description, locale: da)
        return copy
    }

    @Test func aCompleteCatalogHasNoProblems() {
        #expect(copy().problems() == [])
    }

    @Test func onlyTranslatedValuesCount() {
        var copy = copy()
        copy.catalog.set("Eksempel 2", for: "name", language: "da", state: .needsReview)
        #expect(copy.value(.name, locale: da) == nil)
        #expect(copy.problems().contains(.warning("name: needs review in da, so it is not uploaded")))
        copy.approve(.name, locale: da)
        #expect(copy.value(.name, locale: da) == "Eksempel 2")
    }

    @Test func missingTranslationsAreOneWarningPerField() {
        let sv = StoreLocale("sv", store: "sv"), fi = StoreLocale("fi", store: "fi")
        var copy = StoreCopy(project: project(locales: [en, da, sv, fi]), catalog: copy().catalog)
        copy.set("Exempel", field: .name, locale: sv)
        #expect(copy.problems().contains(.warning("name: not translated in fi")))
        #expect(copy.problems().contains(.warning("subtitle: not translated in sv, fi")))
    }

    @Test func changingTheSourceMarksTranslationsForReview() {
        var copy = copy()
        copy.set("Example Pro", field: .name, locale: en)
        #expect(copy.catalog.unit("name", language: "da")?.state == "needs_review")
        #expect(copy.value(.name, locale: da) == nil)
        copy.set("Example", field: .subtitle, locale: en)
        #expect(copy.catalog.unit("subtitle", language: "da")?.state == "needs_review")
    }

    @Test func settingTheSameSourceValueKeepsTranslations() {
        var copy = copy()
        copy.set("Example", field: .name, locale: en)
        #expect(copy.catalog.unit("name", language: "da")?.state == "translated")
    }

    @Test func untranslatedFieldsUseTheSourceInEveryLocale() {
        let copy = copy()
        #expect(copy.value(.reviewNotes, locale: da) == "Sign in with the demo account.")
        #expect(copy.catalog.strings["reviewNotes"]?.shouldTranslate == false)
    }

    @Test func aValueOverItsCapIsAnErrorNamingFieldLanguageAndCap() {
        var copy = copy()
        copy.set(String(repeating: "x", count: 31), field: .name, locale: da)
        #expect(copy.problems().contains(.error("name · da: 31 characters, App Store Connect caps App name at 30")))
        #expect(throws: ProblemsError.self) { try copy.problems().check() }
    }

    @Test func aRequiredLinkIsCheckedInEveryUploadedValue() {
        var copy = copy()
        copy.set("No link", field: .description, locale: da)
        #expect(copy.problems().contains(.error("description · da: must link https://example.com/terms")))
    }

    @Test func missingAndUnknownKeysAreErrors() {
        var copy = copy()
        copy.catalog.strings["subtitle"] = nil
        copy.catalog.strings["subtitel"] = StringCatalog.Entry(comment: nil)
        let problems = copy.problems()
        #expect(problems.contains(.error("subtitle is missing")))
        #expect(problems.contains(.error("subtitel is not App Store copy ProductPageKit knows")))
    }

    @Test func aTranslationOfAnUntranslatedFieldIsAnError() {
        var copy = copy()
        copy.catalog.set("Noter", for: "reviewNotes", language: "da")
        #expect(copy.problems().contains(.error("reviewNotes is not translated in App Store Connect, so its da value would never upload")))
    }

    @Test func keywordsRepeatedOrInTheNameAreWarnings() {
        var copy = copy()
        copy.set("push, Pager,pager,example", field: .keywords, locale: en)
        let problems = copy.problems()
        #expect(problems.contains(.warning("keywords · en: pager is listed twice")))
        #expect(problems.contains(.warning("keywords · en: example is already in the name or subtitle")))
    }

    @Test func keywordsFallBackWhenALocaleHasNone() {
        var copy = copy()
        copy.catalog.strings["keywords"]?.localizations?["da"] = nil
        #expect(copy.value(.keywords, locale: da) == nil)
        #expect(copy.keywords(locale: da) == "fallback,keywords")
    }

    @Test func releasesAreAddedEmptyAndSortedByVersion() throws {
        var copy = copy()
        try copy.addRelease("1.10")
        try copy.addRelease("1.9")
        #expect(copy.releases == ["1.9", "1.10"])
        #expect(copy.catalog.unit("whatsNew.1.9", language: "da")?.state == "new")
        #expect(copy.problems().contains(.error("whatsNew.1.9 has no en value")))
        #expect(throws: ReleaseExists.self) { try copy.addRelease("1.9") }
        #expect(throws: InvalidVersion.self) { try copy.addRelease("next") }
    }

    @Test func whatsNewKeysNameAVersion() {
        #expect(Field.version(ofWhatsNew: "whatsNew.1.2.3") == "1.2.3")
        #expect(Field.version(ofWhatsNew: "whatsNew.1..2") == nil)
        #expect(Field.version(ofWhatsNew: "description") == nil)
        #expect(StoreCopy(project: project(), catalog: StringCatalog(sourceLanguage: "en")).field("whatsNew.2.0")?.maxLength == 4000)
    }

    @Test func aCatalogInAnotherLanguageIsAnError() {
        let copy = StoreCopy(project: project(), catalog: StringCatalog(sourceLanguage: "da"))
        #expect(copy.problems().contains(.error("AppStore.xcstrings is in da, and the primary locale is en")))
    }

    @Test func roundTripsInXcodesLayout() throws {
        let repository = try TemporaryRepository()
        let copy = copy()
        #expect(try copy.write(root: repository.url))
        #expect(try !copy.write(root: repository.url))
        let text = try repository.read("AppStore.xcstrings")
        #expect(text.hasPrefix("{\n  \"sourceLanguage\" : \"en\",\n  \"strings\" : {\n"))
        #expect(text.contains("\"comment\" : \"App name, up to 30 characters.\""))
        #expect(try StoreCopy.load(copy.project, root: repository.url).catalog == copy.catalog)
    }
}
