import XCTest
import SwiftData
@testable import PulseLoop

/// Store launch, phase 1 (iOS lane): the sample-data lifecycle, the one-time disclaimer, release hygiene and the
/// packaging facts a reviewer checks (privacy manifest, background modes, App Group).
@MainActor
final class StoreLaunchPhase1Tests: XCTestCase {

    private func isolatedDefaults() -> UserDefaults {
        let name = "agara.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    // MARK: Sample data ("Explore without ring")

    private func contextWithProfile() throws -> ModelContext {
        let context = try TestSupport.makeContext()
        context.insert(UserProfile(name: "Rae", onboardingCompleted: true, baselineCompleted: true))
        try context.save()
        return context
    }

    func testExploreLoadsALabelledSampleSetWithoutBloodPressureSugarLipidsOrARingDevice() throws {
        let context = try contextWithProfile()
        let store = SampleDataStore(defaults: isolatedDefaults())
        store.markExploring()
        store.activateIfExploring(context: context)

        XCTAssertTrue(store.isActive)
        XCTAssertFalse(store.wantsSampleData, "the intent is consumed")
        let rows = try context.fetch(FetchDescriptor<PulseLoop.Measurement>())
        XCTAssertFalse(rows.isEmpty)
        let forbidden: Set<MeasurementKind> = [.bloodPressureSystolic, .bloodPressureDiastolic, .bloodSugar,
                                               .totalCholesterol, .triglycerides, .hdl, .ldl, .uricAcid,
                                               .fatigue, .temperature]
        XCTAssertTrue(rows.allSatisfy { !forbidden.contains($0.kind) },
                      "no BP / sugar / lipids, and nothing the TK20 ring lacks (fatigue, skin temperature), in the sample set")
        XCTAssertTrue(rows.allSatisfy { $0.sourceRaw == MeasurementSource.mock.rawValue }, "every sample reading is tagged mock (never exported)")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Device>()), 0, "no fake connected ring")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<MealEntry>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CoachConversation>()), 0)
        XCTAssertGreaterThan(try context.fetchCount(FetchDescriptor<ActivityDaily>()), 0)
        XCTAssertGreaterThan(try context.fetchCount(FetchDescriptor<SleepSession>()), 0)
        XCTAssertGreaterThan(try context.fetchCount(FetchDescriptor<ActivitySession>()), 0)
        // The user's own profile is untouched, and the demo name is neutral.
        let profiles = try context.fetch(FetchDescriptor<UserProfile>())
        XCTAssertEqual(profiles.map(\.name), ["Rae"])
        XCTAssertNotEqual(profiles.first?.name, "Saksham")
    }

    func testTheDemoSeedNoLongerUsesAPersonalName() throws {
        let context = try TestSupport.makeContext()
        SeedData.seedDemo(context, completeOnboarding: true)
        XCTAssertEqual(try context.fetch(FetchDescriptor<UserProfile>()).map(\.name), ["Sample"])
    }

    func testPairingARealRingWipesTheSampleRowsAndKeepsTheProfile() throws {
        let context = try contextWithProfile()
        let store = SampleDataStore(defaults: isolatedDefaults())
        store.markExploring()
        store.activateIfExploring(context: context)
        XCTAssertTrue(store.isActive)

        XCTAssertTrue(store.wipeForRealRing(context: context))
        XCTAssertFalse(store.isActive)
        for (name, count) in [
            ("Measurement", try context.fetchCount(FetchDescriptor<PulseLoop.Measurement>())),
            ("ActivityDaily", try context.fetchCount(FetchDescriptor<ActivityDaily>())),
            ("SleepSession", try context.fetchCount(FetchDescriptor<SleepSession>())),
            ("SleepStageBlock", try context.fetchCount(FetchDescriptor<SleepStageBlock>())),
            ("ActivitySession", try context.fetchCount(FetchDescriptor<ActivitySession>())),
            ("ActivityGpsPoint", try context.fetchCount(FetchDescriptor<ActivityGpsPoint>())),
        ] {
            XCTAssertEqual(count, 0, "\(name) rows left after the wipe")
        }
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<UserProfile>()), 1)
        XCTAssertFalse(store.wipeForRealRing(context: context), "nothing to do the second time")
    }

    func testClearFromSettingsRemovesSampleDataOnly() throws {
        let context = try contextWithProfile()
        let store = SampleDataStore(defaults: isolatedDefaults())
        store.markExploring()
        store.activateIfExploring(context: context)
        store.clear(context: context)
        XCTAssertFalse(store.isActive)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PulseLoop.Measurement>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<UserProfile>()), 1)
    }

    func testAPairedRingBlocksTheSampleSet() throws {
        let context = try contextWithProfile()
        context.insert(Device(deviceType: .veepoo, capabilities: [.heartRate]))
        try context.save()
        let store = SampleDataStore(defaults: isolatedDefaults())
        store.markExploring()
        store.activateIfExploring(context: context)
        XCTAssertFalse(store.isActive)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PulseLoop.Measurement>()), 0)
    }

    func testSampleDataCannotBeExported() async throws {
        let context = try contextWithProfile()
        UserDefaults.standard.set(true, forKey: SampleDataStore.activeKey)
        defer { UserDefaults.standard.removeObject(forKey: SampleDataStore.activeKey) }
        do {
            _ = try await DataArchiveService.exportArchive(context: context)
            XCTFail("export must refuse while only sample data is loaded")
        } catch DataArchiveError.sampleDataLoaded {
            // expected
        }
        XCTAssertNil(DiagnosticsExporter.exportFile(context: context))
    }

    // MARK: Disclaimer + legal

    func testDisclaimerIsAcceptedOncePerInstall() {
        let defaults = isolatedDefaults()
        XCTAssertFalse(WellnessDisclaimer.isAccepted(defaults))
        WellnessDisclaimer.accept(defaults)
        XCTAssertTrue(WellnessDisclaimer.isAccepted(defaults))
        XCTAssertFalse(AgaraCopy.wellnessDisclaimerBody.isEmpty)
    }

    func testLegalLinksComeFromTheCatalogAndHideWhenEmpty() {
        XCTAssertEqual(LegalLinks.all.map(\.id), ["privacy", "terms", "support"])
        XCTAssertNil(AboutSettingsView.link("privacy", "Privacy policy", "x", ""), "an empty URL hides its row")
        XCTAssertNil(AboutSettingsView.link("privacy", "Privacy policy", "x", "   "))
    }

    // MARK: Release hygiene

    func testTheStoreBuildsClientAttributionUsesThePublicWebsite() {
        XCTAssertTrue(OpenFoodFactsClient.userAgent.contains("agaralife.com"))
        XCTAssertFalse(OpenFoodFactsClient.userAgent.contains("github"))
    }

    func testDeleteAllMyDataWipesStoreAndSampleState() throws {
        let context = try contextWithProfile()
        SeedData.seedDemo(context, completeOnboarding: false, sample: true)
        UserDefaults.standard.set(true, forKey: SampleDataStore.activeKey)
        AppDataWipe.eraseEverything(context: context)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<UserProfile>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PulseLoop.Measurement>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ActivityDaily>()), 0)
        XCTAssertFalse(UserDefaults.standard.bool(forKey: SampleDataStore.activeKey))
        XCTAssertFalse(SampleDataStore.shared.isActive)
        XCTAssertFalse(AgaraCloud.shared.isSignedIn)
        XCTAssertFalse(WellnessDisclaimer.isAccepted(), "a wiped install shows the disclaimer again")
        XCTAssertEqual(ConfirmAction.deleteAllData {}.title, AgaraCopy.deleteAllDataTitle)
    }

    // MARK: Packaging facts a reviewer checks

    func testPrivacyManifestIsBundled() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
        let plist = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: Any])
        XCTAssertEqual(plist["NSPrivacyTracking"] as? Bool, false)
        let types = try XCTUnwrap(plist["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        let byCategory = Dictionary(uniqueKeysWithValues: types.map {
            ($0["NSPrivacyAccessedAPIType"] as! String, $0["NSPrivacyAccessedAPITypeReasons"] as! [String])
        })
        XCTAssertEqual(Set(byCategory["NSPrivacyAccessedAPICategoryUserDefaults"] ?? []), ["CA92.1", "1C8F.1"])
        XCTAssertEqual(byCategory["NSPrivacyAccessedAPICategorySystemBootTime"], ["35F9.1"])
        // StorageUsage reads free disk space to SHOW it (85F4.1) and to stop writing when it is low (E174.1) — missing
        // since 1.0 (ITMS-91053 risk), added in the 1.1 pre-TestFlight audit.
        XCTAssertEqual(Set(byCategory["NSPrivacyAccessedAPICategoryDiskSpace"] ?? []), ["85F4.1", "E174.1"])
        // 1.1 (Agara Cloud, opt-in): the manifest declares what the cloud collects, all linked, none for tracking.
        // The AI coach is NOT collection in Apple's sense: turns are processed in memory, never stored (contract §12).
        let collected = try XCTUnwrap(plist["NSPrivacyCollectedDataTypes"] as? [[String: Any]])
        XCTAssertEqual(Set(collected.compactMap { $0["NSPrivacyCollectedDataType"] as? String }),
                       ["NSPrivacyCollectedDataTypeEmailAddress", "NSPrivacyCollectedDataTypeHealth",
                        "NSPrivacyCollectedDataTypeFitness", "NSPrivacyCollectedDataTypeUserID"])
        XCTAssertTrue(collected.allSatisfy {
            ($0["NSPrivacyCollectedDataTypeLinked"] as? Bool) == true && ($0["NSPrivacyCollectedDataTypeTracking"] as? Bool) == false
                && ($0["NSPrivacyCollectedDataTypePurposes"] as? [String]) == ["NSPrivacyCollectedDataTypePurposeAppFunctionality"]
        })
    }

    /// The next TestFlight build of the 1.1 train (App Store Connect holds 1.1.0 builds 1–4 as of 2026-10-23).
    func testThisIsTheOneOneBuild() {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String, "1.1.0")
        XCTAssertGreaterThanOrEqual(Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") ?? 0, 5)
    }

    func testBackgroundModesAreBluetoothLocationAndFetchOnly() {
        // `fetch` returned deliberately with Agara Cloud's background sync (see PermissionDeclarationsTests).
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []
        XCTAssertEqual(Set(modes), ["bluetooth-central", "location", "fetch"])
    }

    func testAllThreeTargetsShareTheAgaraAppGroup() {
        XCTAssertEqual(AgaraWidgetStore.suite, "group.com.agara.ring")
        XCTAssertEqual(WorkoutAppGroup.suite, "group.com.agara.ring")
    }

    func testMacIsNotOfferedAndUsageStringsNoLongerNameTheCoachOnly() {
        // Owner decision 2026-09-29: no camera use in the store build, so no camera purpose string
        // (the camera code is compiled out; see `CameraSupport` and `PermissionDeclarationsTests`).
        XCTAssertNil(Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription"))
        let health = Bundle.main.object(forInfoDictionaryKey: "NSHealthUpdateUsageDescription") as? String ?? ""
        XCTAssertFalse(health.localizedCaseInsensitiveContains("temperature"), "skin temperature is no longer written")
        XCTAssertNil(Bundle.main.object(forInfoDictionaryKey: "NSLocationAlwaysAndWhenInUseUsageDescription"))
    }
}
