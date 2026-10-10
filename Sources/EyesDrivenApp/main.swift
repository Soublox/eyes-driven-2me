import Foundation

// Eyes Driven 2me — process entry point.
//
// `EyesDriven2me --help` lists the CLI diagnostics (Diagnostics.swift).
// Without a diagnostic flag the SwiftUI menu-bar app starts.

if !Diagnostics.runIfRequested(CommandLine.arguments) {
    EyesDrivenApp.main()
}
