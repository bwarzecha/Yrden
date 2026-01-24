/// Test helpers for cross-provider tests.

import Foundation

// MARK: - PNG Generation

/// Creates a small solid-color PNG for testing image input.
func createTestPNG(color: (r: UInt8, g: UInt8, b: UInt8)) -> Data {
    var data = Data()

    // PNG signature
    data.append(contentsOf: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    // IHDR chunk
    let ihdr = createPNGChunk(type: "IHDR", data: Data([
        0x00, 0x00, 0x00, 0x02,
        0x00, 0x00, 0x00, 0x02,
        0x08, 0x02, 0x00, 0x00, 0x00
    ]))
    data.append(ihdr)

    // IDAT chunk
    var rawData = Data()
    for _ in 0..<2 {
        rawData.append(0x00)
        rawData.append(color.r)
        rawData.append(color.g)
        rawData.append(color.b)
        rawData.append(color.r)
        rawData.append(color.g)
        rawData.append(color.b)
    }

    let compressed = compressZlib(rawData)
    let idat = createPNGChunk(type: "IDAT", data: compressed)
    data.append(idat)

    // IEND chunk
    let iend = createPNGChunk(type: "IEND", data: Data())
    data.append(iend)

    return data
}

private func createPNGChunk(type: String, data: Data) -> Data {
    var chunk = Data()
    var length = UInt32(data.count).bigEndian
    chunk.append(Data(bytes: &length, count: 4))
    chunk.append(type.data(using: .ascii)!)
    chunk.append(data)
    var crcData = type.data(using: .ascii)!
    crcData.append(data)
    var crc = crc32(crcData).bigEndian
    chunk.append(Data(bytes: &crc, count: 4))
    return chunk
}

private func compressZlib(_ data: Data) -> Data {
    var result = Data()
    result.append(0x78)
    result.append(0x01)
    result.append(0x01)
    let len = UInt16(data.count)
    result.append(UInt8(len & 0xFF))
    result.append(UInt8(len >> 8))
    result.append(UInt8(~len & 0xFF))
    result.append(UInt8(~len >> 8))
    result.append(data)
    var adler = adler32(data).bigEndian
    result.append(Data(bytes: &adler, count: 4))
    return result
}

private func crc32(_ data: Data) -> UInt32 {
    var crc: UInt32 = 0xFFFFFFFF
    for byte in data {
        crc ^= UInt32(byte)
        for _ in 0..<8 {
            crc = (crc >> 1) ^ (crc & 1 != 0 ? 0xEDB88320 : 0)
        }
    }
    return ~crc
}

private func adler32(_ data: Data) -> UInt32 {
    var a: UInt32 = 1
    var b: UInt32 = 0
    for byte in data {
        a = (a + UInt32(byte)) % 65521
        b = (b + a) % 65521
    }
    return (b << 16) | a
}
