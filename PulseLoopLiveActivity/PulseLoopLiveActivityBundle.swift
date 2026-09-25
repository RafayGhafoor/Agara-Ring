//
//  PulseLoopLiveActivityBundle.swift
//  PulseLoopLiveActivity
//
//  Created by Saksham Bhutani on 6/1/26.
//

import WidgetKit
import SwiftUI

@main
struct PulseLoopLiveActivityBundle: WidgetBundle {
    /// The Live Activity renders with Manrope; its fonts ship in this target's asset catalog.
    init() {
        AgaraFontRegistry.registerBundledFonts()
    }

    var body: some Widget {
        // Only the workout Live Activity. The template static/control widgets are omitted
        // so the bundle registers cleanly (a failing template widget can take the whole
        // bundle — including the Live Activity — down with it).
        WorkoutLiveActivityWidget()
    }
}
