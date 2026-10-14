import Foundation

// ClaudeJump: runs an AppleScript file with Accessibility rights. Lives in its own app so the grant
// survives rebuilds of the widget, and takes the script as an argument so it never needs rebuilding.
// Args: <script path> [script args...]
let args = CommandLine.arguments
guard args.count >= 2 else { exit(1) }

let logPath = NSString(string: "~/.claude-waiting/open.log").expandingTildeInPath
if !FileManager.default.fileExists(atPath: logPath) { FileManager.default.createFile(atPath: logPath, contents: nil) }
let log = FileHandle(forWritingAtPath: logPath)
log?.seekToEndOfFile()
log?.write("jump \(args.dropFirst().joined(separator: " ")) at \(Date())\n".data(using: .utf8)!)
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
p.arguments = Array(args.dropFirst())
p.standardOutput = log
p.standardError = log
try? p.run()
p.waitUntilExit()
log?.write("exit \(p.terminationStatus)\n".data(using: .utf8)!)
