import Foundation

struct Item: Codable { let name: String; let count: Int; let when: Date }
let enc = JSONEncoder()
enc.outputFormatting = [.sortedKeys]
enc.dateEncodingStrategy = .iso8601
let data = try enc.encode([Item(name: "apple", count: 3, when: Date(timeIntervalSince1970: 0))])
let json = String(decoding: data, as: UTF8.self)
print("JSON:", json)
let back = try JSONDecoder().decode([Item].self, from: try JSONEncoder().encode([Item(name: "x", count: 1, when: Date())]))
precondition(back.count == 1)
let fm = FileManager.default
let url = fm.temporaryDirectory.appendingPathComponent("portable-swift-\(ProcessInfo.processInfo.processIdentifier).txt")
try json.write(to: url, atomically: true, encoding: .utf8)
let read = try String(contentsOf: url, encoding: .utf8)
precondition(read == json)
try fm.removeItem(at: url)
print("Date:", Date(), "cwd:", fm.currentDirectoryPath)
print("FOUNDATION OK")
