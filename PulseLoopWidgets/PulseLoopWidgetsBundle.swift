import WidgetKit
import SwiftUI

@main
struct PulseLoopWidgetsBundle: WidgetBundle {
    /// The extension renders with Manrope too; its fonts ship in this target's own asset catalog.
    init() {
        AgaraFontRegistry.registerBundledFonts()
    }

    var body: some Widget {
        PulseLoopActivityWidget()
        PulseLoopMetricWidget()
        PulseLoopDualMetricWidget()
    }
}
