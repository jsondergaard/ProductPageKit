import Foundation

/// The background services a capture's simulators boot without: widgets and
/// wallpaper, Siri and on-device intelligence, Spotlight, Mail and Calendar,
/// Health, Home and Fitness, Photos analysis, News and Maps, messaging,
/// connectivity, telemetry and other daemons no app's own screens draw on. A
/// stock iOS 27 simulator runs about 300 processes and, with the runtime's
/// shared cache mapped privately into each, takes 14 GB; without these it
/// runs about 100 with an app open.
///
/// The labels are SimSlim's (https://github.com/MobAI-App/simslim, MIT,
/// copyright 2026 Interlap), less those an app's screens can need: StoreKit
/// and the App Store for products and prices, iCloud for CloudKit, and
/// `mobileassetd` for the fonts some scripts download.
enum SlimServices {
    static let disabled: [String] = [
        // Widgets and wallpaper.
        "com.apple.PosterBoard", "com.apple.chronod", "com.apple.liveactivitiesd", "com.apple.navd",
        // Siri and intelligence. `assistantd` stays: it hosts dictation, and
        // the Spotlight app leaks memory without it.
        "com.apple.assistant_cdmd", "com.apple.assistant_service", "com.apple.siriactionsd", "com.apple.siriinferenced",
        "com.apple.siriknowledged", "com.apple.sirittsd", "com.apple.siri.context.service", "com.apple.siri.acousticsignature",
        "com.apple.corespeechd", "com.apple.voiced", "com.apple.voicebankingd", "com.apple.speechmodeltrainingd",
        "com.apple.intelligenceplatformd", "com.apple.intelligencecontextd", "com.apple.intelligenceflowd",
        "com.apple.intelligencetasksd", "com.apple.generativeexperiencesd", "com.apple.knowledgeconstructiond",
        "com.apple.naturallanguaged", "com.apple.textunderstandingd", "com.apple.modelcatalogd", "com.apple.modelmanagerd",
        "com.apple.mlhostd", "com.apple.mlruntimed", "com.apple.suggestd", "com.apple.parsecd", "com.apple.parsec-fbf",
        "com.apple.proactiveeventtrackerd",
        // Spotlight.
        "com.apple.searchd", "com.apple.searchtoold", "com.apple.spotlightknowledged", "com.apple.spotlightknowledged.updater",
        "com.apple.corespotlightservice",
        // Mail, Calendar and Contacts.
        "com.apple.email.maild", "com.apple.exchangesyncd", "com.apple.dataaccess.dataaccessd", "com.apple.calaccessd",
        "com.apple.remindd", "com.apple.contactsd", "com.apple.contacts.postersyncd", "com.apple.peopled",
        // Safari sync and web services.
        "com.apple.SafariBookmarksSyncAgent", "com.apple.Safari.History", "com.apple.Safari.passwordbreachd",
        "com.apple.Safari.SafeBrowsing.Service", "com.apple.safarifetcherd", "com.apple.WebBookmarks.webbookmarksd",
        "com.apple.webkit.adattributiond", "com.apple.webkit.webpushd", "com.apple.webprivacyd", "com.apple.swcd",
        // Family and Screen Time.
        "com.apple.familycircled", "com.apple.FamilyControlsAgent", "com.apple.familynotification", "com.apple.askpermissiond",
        "com.apple.asktod", "com.apple.ScreenTimeAgent", "com.apple.ScreenTimeSettingsAgent", "com.apple.UsageTrackingAgent",
        // Health, Home and Fitness.
        "com.apple.healthd", "com.apple.healthappd", "com.apple.healthcontentd", "com.apple.healtheventsd",
        "com.apple.healthrecordsd", "com.apple.finhealthd", "com.apple.homed", "com.apple.homeeventsd", "com.apple.fitcore",
        "com.apple.fitcore.session", "com.apple.fitnesscoachingd", "com.apple.fitnessintelligenced",
        "com.apple.activityawardsd", "com.apple.activitysharingd",
        // Photos and media analysis.
        "com.apple.photoanalysisd", "com.apple.photosface", "com.apple.mediaanalysisd", "com.apple.mediaanalysisd.service",
        "com.apple.mediastream.mstreamd", "com.apple.medialibraryd", "com.apple.assetsd", "com.apple.assetsd.nebulad",
        // News, Weather, Maps and games. `gamed` stays: UI test launches wait
        // on it.
        "com.apple.newsd", "com.apple.weatherd", "com.apple.Maps.mapssyncd", "com.apple.Maps.mapspushd",
        "com.apple.Maps.geocorrectiond", "com.apple.maps.destinationd", "com.apple.MapKit.SnapshotService",
        "com.apple.jetpackassetd", "com.apple.tipsd", "com.apple.gamesaved", "com.apple.GameController.gamecontrollerd",
        // Messaging and FaceTime.
        "com.apple.identityservicesd", "com.apple.ids_simd", "com.apple.imautomatichistorydeletionagent",
        "com.apple.imcore.imtransferagent", "com.apple.imdpersistence.IMDPersistenceAgent",
        "com.apple.facetimemessagestored", "com.apple.telephonyutilities.callservicesd",
        // Sharing and device connectivity. `sharingd` stays for share sheets.
        "com.apple.rapportd", "com.apple.companiond", "com.apple.carkitd", "com.apple.wcd", "com.apple.tvremoted",
        "com.apple.avatarsd", "com.apple.stickersd", "com.apple.sociallayerd", "com.apple.announced",
        "com.apple.findmy.findmylocated",
        // Ads, diagnostics and telemetry.
        "com.apple.ap.adprivacyd", "com.apple.ap.promotedcontentd", "com.apple.diagnosticextensionsd", "com.apple.feedbackd",
        "com.apple.rtcreportingd", "com.apple.securityuploadd", "com.apple.geoanalyticsd", "com.apple.triald",
        "com.apple.followupd", "com.apple.purplebuddy.budd", "com.apple.devicecheckd",
        // Wallet and other background services.
        "com.apple.financed", "com.apple.passd", "com.apple.merchantd", "com.apple.coreidvd", "com.apple.businessservicesd",
        "com.apple.deviceaccessd", "com.apple.replicatord", "com.apple.linkd", "com.apple.ind", "com.apple.storagedatad",
        "com.apple.StatusKitAgent", "com.apple.countryd", "com.apple.managedconfiguration.passcodenagd",
        // Beyond SimSlim's, measured still running on an iOS 27.2 worker:
        // the Apple Watch companions, Wallet, location history, Image
        // Playground, Clock, Sleep, Biome, calendar and contact sync, Screen
        // Time settings and device management. `nanoregistryd` stays: with
        // it off, the companions hold the boot from ever finishing.
        "com.apple.nanotimekitcompaniond", "com.apple.companionappd", "com.apple.brook.brookcompaniond",
        "com.apple.nanoregistrylaunchd", "com.apple.nanoprefsyncd.2", "com.apple.NPKCompanionAgent",
        "com.apple.routined", "com.apple.imageplaygroundd", "com.apple.mobiletimerd", "com.apple.sleepd", "com.apple.biomed",
        "com.apple.biomesyncd", "com.apple.eventkitsyncd", "com.apple.addressbooksyncd", "com.apple.cmfsyncagent",
        "com.apple.ManagedSettingsAgent", "com.apple.dmd",
    ]

    /// Where `launchd_sim`, a host process, keeps a device's disable
    /// overrides: beside its launchd log, keyed by UDID. It reads the file
    /// when the device boots, so one written before the first boot needs no
    /// reboot. A clone starts without one.
    static func store(_ udid: String, root: URL = URL(filePath: "/private/var/tmp")) -> URL {
        root.appending(path: "com.apple.CoreSimulator.SimDevice.\(udid)/disabled.plist")
    }

    /// Writes the overrides for a device that has not booted, keeping any
    /// entry already there.
    static func write(_ udid: String, root: URL = URL(filePath: "/private/var/tmp")) throws {
        let file = store(udid, root: root)
        var entries = (try? PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil)) as? [String: Bool] ?? [:]
        for label in disabled { entries[label] = true }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: entries, format: .xml, options: 0).write(to: file, options: .atomic)
    }

    /// The labels of `disabled` that `launchctl print-disabled system`, as
    /// `output`, does not show disabled: a runtime that ignored the store.
    static func missing(in output: String) -> [String] {
        let off = Set(output.split(separator: "\n").compactMap { line -> String? in
            let parts = line.split(separator: "=>").map { $0.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\""))) }
            guard parts.count == 2, parts[1] == "disabled" || parts[1] == "true" else { return nil }
            return parts[0]
        })
        return disabled.filter { !off.contains($0) }
    }
}
