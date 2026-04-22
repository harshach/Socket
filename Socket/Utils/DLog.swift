//
//  DLog.swift
//  Socket
//
//  Compile-time-gated debug print helpers. `print()` on macOS is synchronous
//  (stdout buffer flush + os_log serialization) which is too expensive for
//  hot paths like tab switches, message handlers, and SwiftUI updates.
//  In Release builds these become no-ops.
//

import Foundation

/// Debug-only print — compiled out of Release builds.
@inlinable
public func DLog(_ message: @autoclosure () -> String) {
    #if DEBUG
    print(message())
    #endif
}

/// Debug-only labelled print — tag goes before the message. Cheap string work
/// is autoclosure-wrapped so nothing runs in Release.
@inlinable
public func DLog(_ tag: @autoclosure () -> String, _ message: @autoclosure () -> String) {
    #if DEBUG
    print("[\(tag())] \(message())")
    #endif
}
