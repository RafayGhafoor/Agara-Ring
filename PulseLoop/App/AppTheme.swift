import SwiftUI

enum AppRoute: Hashable {
    case activityDetail(UUID)
    case metricDetail(MetricKind)
    case activityTrends
    case recordSelect
    case logPastActivity
    case recordLive(UUID)
    case recordSummary(UUID)
    case settings
    // Settings detail screens (the top-level `settings` route is the category list).
    case settingsProfile
    case settingsAppearance
    case settingsPhysiology
    case settingsNotifications
    case settingsCoach
    case settingsWearable
    case settingsMeasurement
    case settingsActivityTracking
    case settingsGoals
    case settingsVitals
    case settingsHeartRateZones
    case settingsToday
    case settingsCalibration
    case settingsHealth
    case settingsStrava
    case settingsCloud
    case settingsPrivacyData
    case settingsAbout
    case settingsNutrition
    case nutrition
    case mealDetail(UUID)
    case pairing
    case debug
    case componentGallery
}

enum MainTab: String, CaseIterable, Identifiable {
    case today = "Today"
    case vitals = "Vitals"
    case activity = "Activity"
    case sleep = "Sleep"
    case coach = "Coach"
    case settings = "Settings"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .today: return "circle.circle"
        case .vitals: return "heart"
        case .activity: return "waveform.path.ecg"
        case .sleep: return "moon"
        case .coach: return "sparkles"
        case .settings: return "gearshape"
        }
    }
}

/// The theme in effect. Themes are defined in `docs/config/palette.yaml` and generated into `AgaraTheme.all`;
/// nothing here lists them. Observable: `AppearanceStore` (Settings › Appearance, the system light/dark setting,
/// the profile default) sets it and every view that read a `PulseColors` role in its body re-renders; the root
/// additionally re-identifies its content on a change so cached colours are rebuilt too. Debug builds can pin a
/// theme with `-theme <name>`. The widget and Live Activity extensions never change it (they stay `.dark`).
@Observable
nonisolated final class ThemeStore {
    nonisolated(unsafe) static let shared = ThemeStore()

    var theme: AgaraTheme = .dark

    /// Shorthand for `shared.theme` — what `PulseColors` and the extensions read.
    static var current: AgaraTheme {
        get { shared.theme }
        set { if shared.theme.name != newValue.name { shared.theme = newValue } }
    }

    /// Select a theme by catalog name; unknown names are ignored (the current theme stays).
    static func select(_ name: String?) {
        guard let name, let theme = AgaraTheme.named(name) else { return }
        current = theme
    }
}

/// Colour roles for the current theme — the only way screens get a colour. Values come from the shared
/// palette catalog (`docs/config/palette.yaml` → `AgaraTheme`), the same source Android reads. This file is
/// compiled into the app *and* the widgets extension, and the generated file is a member of both targets.
enum PulseColors {
    private static var t: AgaraTheme { ThemeStore.current }

    // Surfaces
    static var background: Color { t.background }
    static var secondaryBackground: Color { t.secondaryBackground }
    static var card: Color { t.card }
    static var cardSoft: Color { t.cardSoft }
    static var elevated: Color { t.elevated }
    static var borderSubtle: Color { t.borderSubtle }
    static var borderStrong: Color { t.borderStrong }
    // Text
    static var textPrimary: Color { t.textPrimary }
    static var textSecondary: Color { t.textSecondary }
    static var textMuted: Color { t.textMuted }
    // Brand / interactive
    static var accent: Color { t.accent }
    static var onAccent: Color { t.onAccent }
    static var accentSoft: Color { t.accentSoft }
    // Status
    static var success: Color { t.success }
    static var warning: Color { t.warning }
    static var danger: Color { t.danger }
    static var info: Color { t.info }
    // Metric series
    static var steps: Color { t.steps }
    static var heartRate: Color { t.heartRate }
    static var spo2: Color { t.spo2 }
    static var sleep: Color { t.sleep }
    static var calories: Color { t.calories }
    static var distance: Color { t.distance }
    static var readiness: Color { t.readiness }
    static var battery: Color { t.battery }
    static var stress: Color { t.stress }
    static var hrv: Color { t.hrv }
    static var temperature: Color { t.temperature }
    static var macroProtein: Color { t.macroProtein }
    static var macroCarbs: Color { t.macroCarbs }
    static var macroFat: Color { t.macroFat }
    static var bloodPressure: Color { t.bloodPressure }
    static var bloodSugar: Color { t.bloodSugar }
    static var fatigue: Color { t.fatigue }
    static var respiration: Color { t.respiration }
    static var met: Color { t.met }
    static var cardiacLoad: Color { t.cardiacLoad }
    static var bloodComponents: Color { t.bloodComponents }
    // Vitals reference zones. These are the ONLY colors a zone may use, so the chart line, reference band,
    // gauge arc, stat dot, and status label are always identical for the same zone.
    static var zoneBlue: Color { t.zoneBlue }
    static var zoneMint: Color { t.zoneMint }
    static var zoneCyan: Color { t.zoneCyan }
    static var zoneAmber: Color { t.zoneAmber }
    static var zoneSoftAmber: Color { t.zoneSoftAmber }
    static var zoneOrange: Color { t.zoneOrange }
    static var zoneRed: Color { t.zoneRed }
    static var zoneCritical: Color { t.zoneCritical }
    static var zoneDeepRed: Color { t.zoneDeepRed }
    // Sleep stages
    static var stageDeep: Color { t.stageDeep }
    static var stageLight: Color { t.stageLight }
    static var stageRem: Color { t.stageRem }
    static var stageAwake: Color { t.stageAwake }
}

/// Corner-radius tokens so peer glass surfaces share one radius instead of the
/// ad-hoc 16/18/20/22/24 mix. `card` for standard glass cards, `compact` for
/// smaller/inset surfaces, `control` for buttons and small controls.
enum PulseRadius {
    static let card: CGFloat = AgaraShape.radiusCard
    static let compact: CGFloat = AgaraShape.radiusCompact
    static let control: CGFloat = AgaraShape.radiusControl
}

extension Color {
    init(hex: String) {
        let trimmed = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: trimmed).scanHexInt64(&value)
        
        let red: UInt64
        let green: UInt64
        let blue: UInt64
        let alpha: UInt64
        
        switch trimmed.count {
        case 3:
            red = (value >> 8) * 17
            green = (value >> 4 & 0xF) * 17
            blue = (value & 0xF) * 17
            alpha = 255
        case 6:
            red = value >> 16
            green = value >> 8 & 0xFF
            blue = value & 0xFF
            alpha = 255
        case 8:
            red = value >> 24
            green = value >> 16 & 0xFF
            blue = value >> 8 & 0xFF
            alpha = value & 0xFF
        default:
            red = 255
            green = 255
            blue = 255
            alpha = 255
        }
        
        self.init(
            .sRGB,
            red: Double(red) / 255,
            green: Double(green) / 255,
            blue: Double(blue) / 255,
            opacity: Double(alpha) / 255
        )
    }
}

struct PulseCard<Content: View>: View {
    var padding: CGFloat = 16
    var cornerRadius: CGFloat = 20
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            // Liquid Glass card surface (glass 26+, Material 18–25, solid on Reduce Transparency).
            .pulseGlass(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

struct MetricTile: View {
    let title: String
    let value: String
    var unit: String?
    var color: Color
    var trend: [Double] = []
    
    var body: some View {
        PulseCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Circle().fill(color).frame(width: 8, height: 8)
                    Text(title.uppercased())
                        .font(PulseFont.caption2)
                        .foregroundStyle(PulseColors.textMuted)
                        .lineLimit(1)
                }
                
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(value)
                        .font(PulseFont.numberXL)
                        .monospacedDigit()
                        .foregroundStyle(PulseColors.textPrimary)
                        .minimumScaleFactor(0.75)
                        .lineLimit(1)
                    if let unit {
                        Text(unit)
                            .font(PulseFont.caption)
                            .foregroundStyle(PulseColors.textMuted)
                    }
                }
                
                MiniSparkline(values: trend, color: color)
                    .frame(height: 34)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct MiniSparkline: View {
    let values: [Double]
    let color: Color
    
    var body: some View {
        GeometryReader { proxy in
            Path { path in
                guard values.count > 1, let minValue = values.min(), let maxValue = values.max() else { return }
                let range = max(maxValue - minValue, 1)
                for index in values.indices {
                    let x = proxy.size.width * CGFloat(index) / CGFloat(values.count - 1)
                    let yRatio = (values[index] - minValue) / range
                    let y = proxy.size.height - proxy.size.height * CGFloat(yRatio)
                    if index == values.startIndex {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
            }
            .stroke(color.opacity(values.count > 1 ? 0.9 : 0.2), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
    }
}

struct PrimaryButton: View {
    let title: String
    var systemImage: String?
    let action: () -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var label: some View {
        Label(title, systemImage: systemImage ?? "arrow.right")
            .labelStyle(.titleAndIcon)
            .font(PulseFont.bodyEmphasis)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
    }

    var body: some View {
        if #available(iOS 26, *), !reduceTransparency {
            // Primary action = translucent Liquid Glass with an accent tint (real
            // lensing, not a flat fill). Glass provides the surface; no manual fill.
            Button(action: action) {
                label.foregroundStyle(PulseColors.textPrimary)
            }
            .buttonStyle(.glass)
            .tint(PulseColors.accent)
            .clipShape(Capsule())
        } else {
            Button(action: action) {
                label
                    .foregroundStyle(PulseColors.textPrimary)
                    .background(PulseColors.accent)
                    .clipShape(Capsule())
            }
        }
    }
}

/// An action that ends or removes something (Disconnect, Forget, Discard): danger text on a faint danger
/// tint, capsule like its siblings. Same role as Android's `DestructiveButton`.
struct DestructiveButton: View {
    let title: String
    var systemImage: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage ?? "xmark.circle")
                .font(PulseFont.callout.weight(.semibold))
                .frame(maxWidth: .infinity)
                .frame(height: AgaraShape.buttonHeight)
                .foregroundStyle(PulseColors.danger)
                .background(PulseColors.danger.opacity(0.12), in: Capsule())
                .overlay { Capsule().stroke(PulseColors.danger.opacity(0.28), lineWidth: 1) }
        }
        .buttonStyle(.plain)
    }
}

struct SecondaryButton: View {
    let title: String
    var systemImage: String?
    let action: () -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var label: some View {
        Label(title, systemImage: systemImage ?? "circle")
            .font(PulseFont.callout.weight(.semibold))
            .frame(maxWidth: .infinity)
            .frame(height: 52)
    }

    var body: some View {
        if #available(iOS 26, *), !reduceTransparency {
            // Secondary action = neutral interactive Liquid Glass.
            Button(action: action) {
                label.foregroundStyle(PulseColors.textPrimary)
            }
            .buttonStyle(.glass)
            .clipShape(Capsule())
        } else {
            Button(action: action) {
                label
                    .foregroundStyle(PulseColors.textPrimary)
                    .background(PulseColors.card)
                    .clipShape(Capsule())
                    .overlay {
                        Capsule().stroke(PulseColors.borderSubtle, lineWidth: 1)
                    }
            }
        }
    }
}
