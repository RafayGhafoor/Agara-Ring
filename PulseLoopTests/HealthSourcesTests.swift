import XCTest
@testable import PulseLoop

/// App Review 1.4.1 (2026-10-20): every health range or explanation the store build shows on Vitals and Sleep
/// must cite a source the user can easily find. The list is generated from `docs/strings/sources.yaml`
/// (`AgaraSources`); these fail when a section loses its sources, a link is not https, or an interpreted
/// metric has no section behind its detail screen.
final class HealthSourcesTests: XCTestCase {

    /// Metrics whose detail screen shows reference zones / "what this means" in the store build.
    private static let interpretedMetrics: [MetricKind] = [.heartRate, .spo2, .hrv, .stress]

    func testEverySectionHasAtLeastOneSource() {
        XCTAssertFalse(AgaraSources.sections.isEmpty)
        for section in AgaraSources.sections {
            XCTAssertFalse(AgaraSources.forSection(section).isEmpty, "section \(section) has no sources")
        }
        // …and no source sits in a section the screen never lists.
        for source in AgaraSources.all {
            XCTAssertTrue(AgaraSources.sections.contains(source.section), "\(source.id): unknown section \(source.section)")
        }
    }

    func testEverySourceIsACompleteHttpsLink() {
        XCTAssertEqual(Set(AgaraSources.all.map(\.id)).count, AgaraSources.all.count, "duplicate source ids")
        for source in AgaraSources.all {
            let url = HealthSources.url(source)
            XCTAssertNotNil(url, "\(source.id): not a URL")
            XCTAssertEqual(url?.scheme, "https", "\(source.id): \(source.url) is not https")
            XCTAssertFalse(url?.host?.isEmpty ?? true, "\(source.id): no host")
            XCTAssertFalse(source.title.isEmpty, "\(source.id): no title")
            XCTAssertFalse(source.publisher.isEmpty, "\(source.id): no publisher")
            XCTAssertFalse(source.supports.isEmpty, "\(source.id): no 'supports' sentence")
        }
    }

    func testEveryInterpretedMetricAndSleepHasASection() {
        for metric in Self.interpretedMetrics {
            guard let section = HealthSources.section(for: metric) else {
                return XCTFail("\(metric) shows ranges but maps to no sources section")
            }
            XCTAssertTrue(AgaraSources.sections.contains(section), "\(metric) → \(section) is not a listed section")
            XCTAssertFalse(AgaraSources.forSection(section).isEmpty, "\(metric) → \(section) has no sources")
        }
        XCTAssertTrue(AgaraSources.sections.contains(HealthSources.sleepSection))
        XCTAssertFalse(AgaraSources.forSection(HealthSources.sleepSection).isEmpty)
    }

    func testSectionHeadingsReuseMetricTitles() {
        XCTAssertEqual(HealthSources.title(for: "heart_rate"), MetricKind.heartRate.title)
        XCTAssertEqual(HealthSources.title(for: "spo2"), MetricKind.spo2.title)
        XCTAssertEqual(HealthSources.title(for: "hrv"), MetricKind.hrv.title)
        XCTAssertEqual(HealthSources.title(for: "stress"), MetricKind.stress.title)
        XCTAssertEqual(HealthSources.title(for: "sleep"), "Sleep")
        for section in AgaraSources.sections {
            XCTAssertNotEqual(HealthSources.title(for: section), section, "section \(section) has no heading")
        }
    }

    func testCopyIsPresent() {
        XCTAssertEqual(AgaraCopy.sourcesTitle, "Sources & references")
        XCTAssertFalse(AgaraCopy.sourcesIntro.isEmpty)
        XCTAssertFalse(AgaraCopy.sourcesMetricFooter.isEmpty)
    }
}

/// App Review 5.2.5 tripwire (2026-10-20): the store build must not link WeatherKit (the app shows no weather and
/// carries no Apple Weather attribution). WeatherKit code may only exist inside `#if AGARA_WEATHERKIT`, and no
/// build configuration may define that flag. Re-enabling weather means changing this test on purpose.
final class WeatherKitTripwireTests: XCTestCase {

    private var iosRoot: URL {
        // …/PulseLoopiOS/PulseLoopTests/<this file> → …/PulseLoopiOS
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func swiftFiles(under folder: String) -> [URL] {
        let base = iosRoot.appendingPathComponent(folder)
        guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { return [] }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    /// Line numbers of `import WeatherKit` that are not inside an `#if AGARA_WEATHERKIT` branch.
    static func unguardedWeatherKitImports(in source: String) -> [Int] {
        // One entry per open `#if`: whether the branch being read is the AGARA_WEATHERKIT-on branch.
        var stack: [Bool] = []
        var hits: [Int] = []
        for (index, raw) in source.components(separatedBy: .newlines).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#if ") || line.hasPrefix("#if\t") {
                let condition = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                stack.append(condition.range(of: #"^\(?\s*AGARA_WEATHERKIT\b"#, options: .regularExpression) != nil)
            } else if line.hasPrefix("#elseif") {
                let condition = line.dropFirst(7).trimmingCharacters(in: .whitespaces)
                if !stack.isEmpty {
                    stack[stack.count - 1] = condition.range(of: #"^\(?\s*AGARA_WEATHERKIT\b"#, options: .regularExpression) != nil
                }
            } else if line.hasPrefix("#else") {
                if !stack.isEmpty { stack[stack.count - 1] = false }
            } else if line.hasPrefix("#endif") {
                _ = stack.popLast()
            } else if line.range(of: #"^(@\w+\s+)*import\s+(\w+\s+)?WeatherKit\b"#, options: .regularExpression) != nil,
                      !stack.contains(true) {
                hits.append(index + 1)
            }
        }
        return hits
    }

    func testDetectorCatchesUnguardedImports() {
        XCTAssertEqual(Self.unguardedWeatherKitImports(in: "import Foundation\nimport WeatherKit\n"), [2])
        XCTAssertEqual(Self.unguardedWeatherKitImports(in: "@preconcurrency import WeatherKit"), [1])
        XCTAssertEqual(Self.unguardedWeatherKitImports(in: "#if AGARA_WEATHERKIT\nimport WeatherKit\n#endif"), [])
        XCTAssertEqual(Self.unguardedWeatherKitImports(in: "#if AGARA_WEATHERKIT\n#else\nimport WeatherKit\n#endif"), [3])
        XCTAssertEqual(Self.unguardedWeatherKitImports(in: "#if DEBUG\nimport WeatherKit\n#endif"), [2])
        XCTAssertEqual(Self.unguardedWeatherKitImports(in: "#if !AGARA_WEATHERKIT\nimport WeatherKit\n#endif"), [2])
    }

    func testNoWeatherKitImportOutsideTheFlag() throws {
        var offenders: [String] = []
        var scanned = 0
        for folder in ["PulseLoop", "PulseLoopWidgets", "PulseLoopLiveActivity"] {
            for file in swiftFiles(under: folder) {
                let text = try String(contentsOf: file, encoding: .utf8)
                scanned += 1
                for line in Self.unguardedWeatherKitImports(in: text) {
                    offenders.append("\(file.path.replacingOccurrences(of: iosRoot.path + "/", with: "")):\(line)")
                }
            }
        }
        XCTAssertGreaterThan(scanned, 100, "source scan found too few files — wrong root \(iosRoot.path)?")
        XCTAssertEqual(offenders, [], "WeatherKit imported outside #if AGARA_WEATHERKIT (App Review 5.2.5)")
    }

    func testNoBuildConfigurationDefinesTheFlag() throws {
        let project = iosRoot.appendingPathComponent("PulseLoop.xcodeproj/project.pbxproj")
        let text = try String(contentsOf: project, encoding: .utf8)
        XCTAssertFalse(text.contains("AGARA_WEATHERKIT"), "project.pbxproj defines AGARA_WEATHERKIT — the build would link WeatherKit")
    }

    func testNoEntitlementRequestsWeatherKit() throws {
        let files = try FileManager.default.subpathsOfDirectory(atPath: iosRoot.path).filter { $0.hasSuffix(".entitlements") }
        XCTAssertFalse(files.isEmpty, "no entitlements files found under \(iosRoot.path)")
        for path in files {
            let text = try String(contentsOf: iosRoot.appendingPathComponent(path), encoding: .utf8)
            XCTAssertFalse(text.contains("com.apple.developer.weatherkit"), "\(path) requests WeatherKit")
        }
    }
}
