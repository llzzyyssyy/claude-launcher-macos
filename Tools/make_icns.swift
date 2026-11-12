import Foundation

func bigEndianUInt32(_ value: UInt32) -> Data {
    var bigEndian = value.bigEndian
    return Data(bytes: &bigEndian, count: MemoryLayout<UInt32>.size)
}

guard CommandLine.arguments.count == 3 else {
    fputs("usage: make_icns <iconset-directory> <output.icns>\n", stderr)
    exit(2)
}

let iconset = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let entries: [(type: String, file: String)] = [
    ("icp4", "icon_16x16.png"),
    ("ic11", "icon_16x16@2x.png"),
    ("icp5", "icon_32x32.png"),
    ("ic12", "icon_32x32@2x.png"),
    ("icp6", "icon_32x32@2x.png"),
    ("ic07", "icon_128x128.png"),
    ("ic13", "icon_128x128@2x.png"),
    ("ic08", "icon_256x256.png"),
    ("ic14", "icon_256x256@2x.png"),
    ("ic09", "icon_512x512.png"),
    ("ic10", "icon_512x512@2x.png")
]

var body = Data()
for entry in entries {
    let fileURL = iconset.appendingPathComponent(entry.file)
    guard let png = try? Data(contentsOf: fileURL) else {
        fputs("missing icon asset: \(fileURL.path)\n", stderr)
        exit(3)
    }
    guard let typeData = entry.type.data(using: .ascii), typeData.count == 4 else {
        fputs("invalid ICNS type: \(entry.type)\n", stderr)
        exit(4)
    }
    body.append(typeData)
    body.append(bigEndianUInt32(UInt32(png.count + 8)))
    body.append(png)
}

var result = Data("icns".utf8)
result.append(bigEndianUInt32(UInt32(body.count + 8)))
result.append(body)

do {
    try result.write(to: output, options: .atomic)
    print(output.path)
} catch {
    fputs("failed to write ICNS: \(error.localizedDescription)\n", stderr)
    exit(5)
}

