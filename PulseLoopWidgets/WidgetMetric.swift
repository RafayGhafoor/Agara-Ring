import AppIntents
import SwiftUI

/// The metrics a user can put on a configurable home-screen widget — every Today-page tile. Raw
/// values are stable identifiers persisted in the user's widget configuration; don't rename them.
enum WidgetMetric: String, CaseIterable, AppEnum {
    case activity
    case nutrition
    case sleep
    case heartRate
    case spo2
    case hrv
    case temperature
    case stress
    case fatigue
    case bloodPressure
    case glucose

    /// Blood pressure and blood sugar are not offered while `vitals_bp` / `vitals_glucose` are off (the store
    /// release, owner 2026-09-29). Skin temperature and fatigue are not offered at all: the Agara (TK20) ring
    /// declares neither (`a7` 3.7 / 1.7 = 0), and the widget extension has no device capabilities to gate on.
    /// The extension does not compile the feature catalog, so the choice list omits them here; the cases stay so
    /// a saved configuration keeps decoding. Re-add them with the flags / a ring that supports them.
    static var allCases: [WidgetMetric] {
        [.activity, .nutrition, .sleep, .heartRate, .spo2, .hrv, .stress]
    }

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Metric"

    static let caseDisplayRepresentations: [WidgetMetric: DisplayRepresentation] = [
        .activity: "Activity",
        .nutrition: "Nutrition",
        .sleep: "Sleep",
        .heartRate: "Heart Rate",
        .spo2: "Blood Oxygen",
        .hrv: "HRV",
        .temperature: "Skin Temperature",
        .stress: "Stress",
        .fatigue: "Fatigue",
        .bloodPressure: "Blood Pressure",
        .glucose: "Blood Sugar",
    ]

    /// The vitals kind whose payload backs this tile; nil for the two non-vitals tiles.
    var metricKind: MetricKind? {
        switch self {
        case .activity, .nutrition, .sleep: return nil
        case .heartRate: return .heartRate
        case .spo2: return .spo2
        case .hrv: return .hrv
        case .temperature: return .temperature
        case .stress: return .stress
        case .fatigue: return .fatigue
        case .bloodPressure: return .bloodPressure
        case .glucose: return .glucose
        }
    }

    /// Which Today tile visual this metric renders as (mirrors `TodayView.tiles`).
    enum TileStyle {
        case rings, nutrition, sleep, chart, gauge, bloodPressure
    }

    var tileStyle: TileStyle {
        switch self {
        case .activity: return .rings
        case .nutrition: return .nutrition
        case .sleep: return .sleep
        case .heartRate, .spo2, .hrv, .temperature: return .chart
        case .stress, .fatigue, .glucose: return .gauge
        case .bloodPressure: return .bloodPressure
        }
    }

    /// Header eyebrow label + dot color, matching the in-app `TodayTile` chrome.
    var headerLabel: String {
        switch self {
        case .activity: return "Activity"
        case .nutrition: return "Nutrition"
        case .sleep: return "Sleep"
        default: return metricKind?.title ?? rawValue
        }
    }

    var accentColor: Color {
        switch self {
        case .activity: return AgaraColors.steps
        case .nutrition: return AgaraColors.calories
        case .sleep: return AgaraColors.sleep
        default: return metricKind?.accentColor ?? AgaraColors.accent
        }
    }
}
