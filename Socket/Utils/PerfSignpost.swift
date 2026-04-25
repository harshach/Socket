//
//  PerfSignpost.swift
//  Socket
//
//  Centralized OSSignposter instances for performance instrumentation.
//  Zero cost when Instruments isn't attached; view intervals via the
//  Points of Interest track in Instruments (Time Profiler, Leaks, etc.).
//
//  Usage:
//      let state = PerfSignpost.shields.beginInterval("Compile")
//      defer { PerfSignpost.shields.endInterval("Compile", state) }
//

import Foundation
import OSLog

enum PerfSignpost {
    private static let subsystem = "com.socket.browser"
    // Instruments' "Points of Interest" instrument only renders signposts
    // whose category is the literal string "PointsOfInterest". Custom
    // categories require the more general "os_signpost" instrument with
    // a subsystem filter. We keep three logical OSSignposter handles so
    // call sites stay self-documenting; the signpost *name* is what
    // distinguishes intervals in the timeline.
    private static let category = "PointsOfInterest"

    static let shields = OSSignposter(subsystem: subsystem, category: category)
    static let navigation = OSSignposter(subsystem: subsystem, category: category)
    static let webView = OSSignposter(subsystem: subsystem, category: category)
}
