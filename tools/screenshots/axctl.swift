// Pid-precise accessibility driver (System Events resolves same-named
// processes by name, which is ambiguous with two Clocktopus instances).
// usage: axctl PID windows | resize TITLE W H | tab TITLE INDEX | scroll TITLE VALUE | statusitem | statusframe | press TITLE BUTTON | focus TITLE BUTTON | unfocus TITLE | dump TITLE
import ApplicationServices
import Foundation

let args = CommandLine.arguments
let pid = pid_t(args[1])!
let app = AXUIElementCreateApplication(pid)

func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
}
func children(_ e: AXUIElement) -> [AXUIElement] { (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
func role(_ e: AXUIElement) -> String { attr(e, kAXRoleAttribute) as? String ?? "" }
func title(_ e: AXUIElement) -> String { attr(e, kAXTitleAttribute) as? String ?? "" }
func desc(_ e: AXUIElement) -> String { attr(e, kAXDescriptionAttribute) as? String ?? "" }
func windows() -> [AXUIElement] { (attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? [] }
func window(_ t: String) -> AXUIElement {
    guard let w = windows().first(where: { title($0) == t }) else { fatalError("no window \(t): \(windows().map(title))") }
    return w
}
func find(_ e: AXUIElement, depth: Int = 0, _ pred: (AXUIElement) -> Bool) -> AXUIElement? {
    if pred(e) { return e }
    for c in children(e) { if let f = find(c, depth: depth + 1, pred) { return f } }
    return nil
}
func findAll(_ e: AXUIElement, _ pred: (AXUIElement) -> Bool) -> [AXUIElement] {
    var out: [AXUIElement] = []
    if pred(e) { out.append(e) }
    for c in children(e) { out += findAll(c, pred) }
    return out
}
func dump(_ e: AXUIElement, _ indent: Int = 0) {
    print(String(repeating: "  ", count: indent) + role(e) + " '" + title(e) + "' '" + desc(e) + "'")
    for c in children(e) { dump(c, indent + 1) }
}

switch args[2] {
case "windows":
    for w in windows() {
        var pos = CGPoint.zero, size = CGSize.zero
        if let p = attr(w, kAXPositionAttribute) { AXValueGetValue(p as! AXValue, .cgPoint, &pos) }
        if let s = attr(w, kAXSizeAttribute) { AXValueGetValue(s as! AXValue, .cgSize, &size) }
        print(title(w), pos, size)
    }
case "resize":
    let w = window(args[3])
    var size = CGSize(width: Double(args[4])!, height: Double(args[5])!)
    AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &size)!)
case "tab":
    let w = window(args[3])
    let buttons = findAll(w) { role($0) == kAXRadioButtonRole }
    AXUIElementPerformAction(buttons[Int(args[4])!], kAXPressAction as CFString)
case "scroll":
    let w = window(args[3])
    guard let bar = find(w, { role($0) == kAXScrollBarRole }) else { fatalError("no scroll bar") }
    AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString, NSNumber(value: Double(args[4])!))
case "statusitem":
    guard let bar = attr(app, "AXExtrasMenuBar") else { fatalError("no extras menu bar") }
    let item = children(bar as! AXUIElement)[0]
    AXUIElementPerformAction(item, kAXPressAction as CFString)
case "statusframe":
    guard let bar = attr(app, "AXExtrasMenuBar") else { fatalError("no extras menu bar") }
    let item = children(bar as! AXUIElement)[0]
    var pos = CGPoint.zero, size = CGSize.zero
    if let p = attr(item, kAXPositionAttribute) { AXValueGetValue(p as! AXValue, .cgPoint, &pos) }
    if let sz = attr(item, kAXSizeAttribute) { AXValueGetValue(sz as! AXValue, .cgSize, &size) }
    print(Int(pos.x), Int(pos.y), Int(size.width), Int(size.height))
case "press":
    let w = window(args[3])
    guard let b = find(w, { role($0) == kAXButtonRole && (title($0) == args[4] || desc($0) == args[4]) }) else { fatalError("no button \(args[4])") }
    AXUIElementPerformAction(b, kAXPressAction as CFString)
case "focus":   // move keyboard focus to a button (e.g. away from a text field's selection)
    let w = window(args[3])
    guard let b = find(w, { role($0) == kAXButtonRole && (title($0) == args[4] || desc($0) == args[4]) }) else { fatalError("no button \(args[4])") }
    print(AXUIElementSetAttributeValue(b, kAXFocusedAttribute as CFString, kCFBooleanTrue).rawValue)
case "unfocus":   // resign a text field's focus so no selection or focus ring shows
    let w = window(args[3])
    for f in findAll(w, { role($0) == kAXTextFieldRole }) {
        AXUIElementSetAttributeValue(f, kAXFocusedAttribute as CFString, kCFBooleanFalse)
    }
case "dump":
    dump(window(args[3]))
default: fatalError("unknown")
}
