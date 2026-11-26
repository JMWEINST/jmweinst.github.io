import Cocoa

// Command-line modes (converting, tests, icon rendering) run and exit here.
// With no arguments, or a GUI test mode, Morph starts as a menu-bar app.
if let code = Debug.runCommandLine(Array(CommandLine.arguments.dropFirst())) {
    exit(code)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
