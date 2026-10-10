import Foundation

// Eyes Driven 2me — process entry point.
//
// The diagnostic CLI lives in Diagnostics.swift. The SwiftUI menu-bar app will
// replace the `print` fallback with its launch once it exists.

if !Diagnostics.runIfRequested(CommandLine.arguments) {
    print(Diagnostics.usage)
}
