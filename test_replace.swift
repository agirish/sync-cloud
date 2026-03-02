import Foundation

let fm = FileManager.default
do {
    let url1 = URL(fileURLWithPath: "test1.txt")
    let url2 = URL(fileURLWithPath: "test2.txt")
    try "hello".write(to: url1, atomically: true, encoding: .utf8)
    try "world".write(to: url2, atomically: true, encoding: .utf8)
    let finalURL = try fm.replaceItemAt(url2, withItemAt: url1)
    print("Success: \(finalURL != nil)")
    print("Url1 exists: \(fm.fileExists(atPath: "test1.txt"))") 
} catch {
    print("Error: \(error)")
}
