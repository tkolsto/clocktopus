import CoreGraphics
import Foundation
let pid = Int32(CommandLine.arguments[1])!
let title = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : nil
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
for w in list where (w["kCGWindowOwnerPID"] as? Int32) == pid {
    let b = w["kCGWindowBounds"] as! [String: Any]
    let name = w["kCGWindowName"] as? String ?? ""
    guard (b["Width"] as! Double) > 100 else { continue }
    if let title, name != title { continue }
    print(w["kCGWindowNumber"]!, name, b["X"]!, b["Y"]!, b["Width"]!, b["Height"]!)
}
