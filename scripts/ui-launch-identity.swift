import Foundation
import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
let args=CommandLine.arguments
guard args.count==3 else { exit(2) }
let bundle=URL(fileURLWithPath:args[1]).resolvingSymlinksInPath()
let fixture=args[2]
let wakeTimer=Timer(timeInterval:0.25,repeats:true) { _ in }
RunLoop.current.add(wakeTimer,forMode:.default)
if fixture == "--snapshot" {
    RunLoop.current.run(until:Date().addingTimeInterval(0.25))
    let matches=NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.resolvingSymlinksInPath()==bundle }
    struct Snapshot: Codable {let exactBundlePath:String;let matchingPIDs:[Int32]}
    FileHandle.standardOutput.write(try JSONEncoder().encode(Snapshot(exactBundlePath:bundle.path,matchingPIDs:matches.map(\.processIdentifier))))
    exit(0)
}
func psExact() throws -> Set<Int32> {
    let p=Process();p.executableURL=URL(fileURLWithPath:"/bin/ps");p.arguments=["-axo","pid=,comm="]
    let output=Pipe();p.standardOutput=output;try p.run();p.waitUntilExit()
    guard p.terminationStatus==0,let text=String(data:output.fileHandleForReading.readDataToEndOfFile(),encoding:.utf8) else { throw NSError(domain:"ps",code:1) }
    let executable=bundle.appendingPathComponent("Contents/MacOS/Spacelyzer").resolvingSymlinksInPath().path
    return Set(text.split(separator:"\n").compactMap { line -> Int32? in
        let parts=line.trimmingCharacters(in:.whitespaces).split(maxSplits:1,whereSeparator: { $0==" " || $0=="\t" })
        guard parts.count==2 else { return nil }
        let raw=String(parts[1]).trimmingCharacters(in:.whitespaces)
        guard URL(fileURLWithPath:raw).resolvingSymlinksInPath().path==executable else { return nil }
        return Int32(parts[0])
    })
}
let before=Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier))
let beforePS=try psExact()
let launch=Process();launch.executableURL=URL(fileURLWithPath:"/usr/bin/open")
launch.arguments=["-n",bundle.path,"--env","SPZ_AUTOSCAN=\(fixture)","--args","-ApplePersistenceIgnoreState","YES"]
let launcherStdout=Pipe(), launcherStderr=Pipe(); launch.standardOutput=launcherStdout; launch.standardError=launcherStderr
try launch.run();launch.waitUntilExit()
let openOut=String(data:launcherStdout.fileHandleForReading.readDataToEndOfFile(),encoding:.utf8) ?? "UNDECODABLE"
let openErr=String(data:launcherStderr.fileHandleForReading.readDataToEndOfFile(),encoding:.utf8) ?? "UNDECODABLE"
let deadline=ProcessInfo.processInfo.systemUptime+30
var matches=[NSRunningApplication]()
repeat {
    matches=NSWorkspace.shared.runningApplications.filter { !before.contains($0.processIdentifier) && $0.bundleURL?.resolvingSymlinksInPath()==bundle }
    if matches.count==1 { break };RunLoop.current.run(until:Date().addingTimeInterval(0.25))
} while ProcessInfo.processInfo.systemUptime<deadline
struct Output: Codable {let pid:Int32?;let matchingNewPIDs:[Int32];let bundlePath:String;let launchExit:Int32;let openStdout:String;let openStderr:String;let postAccess:Bool;let listenAccess:Bool;let axTrusted:Bool;let displayScale:Double;let state:String}
let afterPS=try psExact()
let verifiedPS=afterPS.subtracting(beforePS)
let post=CGPreflightPostEventAccess(), trusted=AXIsProcessTrusted()
let state=launch.terminationStatus != 0 ? "OPEN_FAILED" : matches.count != 1 || verifiedPS != Set(matches.map(\.processIdentifier)) ? "IDENTITY_FAILED" : !post || !trusted ? "BLOCKED_PERMISSION" : "IDENTIFIED"
let output=Output(pid:matches.count==1 ? matches[0].processIdentifier : nil,matchingNewPIDs:Array(verifiedPS.union(Set(matches.map(\.processIdentifier)))),bundlePath:bundle.path,launchExit:launch.terminationStatus,openStdout:openOut,openStderr:openErr,postAccess:post,listenAccess:CGPreflightListenEventAccess(),axTrusted:trusted,displayScale:Double(NSScreen.main?.backingScaleFactor ?? 0),state:state)
FileHandle.standardOutput.write(try JSONEncoder().encode(output))
exit(state == "IDENTIFIED" ? 0 : state == "BLOCKED_PERMISSION" ? 3 : 4)
