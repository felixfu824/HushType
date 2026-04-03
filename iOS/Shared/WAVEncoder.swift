import Foundation

enum WAVEncoder {
    /// Encode Float32 samples (16kHz mono) to WAV Data
    static func encode(samples: [Float], sampleRate: Int = 16000) -> Data {
        let numChannels: Int = 1
        let bitsPerSample: Int = 16
        let bytesPerSample = bitsPerSample / 8
        let dataSize = samples.count * bytesPerSample
        let fileSize = 36 + dataSize

        var data = Data()

        // RIFF header
        data.append(contentsOf: "RIFF".utf8)
        data.append(UInt32(fileSize).littleEndianData)
        data.append(contentsOf: "WAVE".utf8)

        // fmt chunk
        data.append(contentsOf: "fmt ".utf8)
        data.append(UInt32(16).littleEndianData)           // chunk size
        data.append(UInt16(1).littleEndianData)            // PCM format
        data.append(UInt16(numChannels).littleEndianData)
        data.append(UInt32(sampleRate).littleEndianData)
        data.append(UInt32(sampleRate * numChannels * bytesPerSample).littleEndianData) // byte rate
        data.append(UInt16(numChannels * bytesPerSample).littleEndianData) // block align
        data.append(UInt16(bitsPerSample).littleEndianData)

        // data chunk
        data.append(contentsOf: "data".utf8)
        data.append(UInt32(dataSize).littleEndianData)

        // Convert Float32 [-1.0, 1.0] to Int16
        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            let int16 = Int16(clamped * Float(Int16.max))
            data.append(int16.littleEndianData)
        }

        return data
    }
}

// MARK: - Helpers

private extension UInt32 {
    var littleEndianData: Data {
        var value = self.littleEndian
        return Data(bytes: &value, count: 4)
    }
}

private extension UInt16 {
    var littleEndianData: Data {
        var value = self.littleEndian
        return Data(bytes: &value, count: 2)
    }
}

private extension Int16 {
    var littleEndianData: Data {
        var value = self.littleEndian
        return Data(bytes: &value, count: 2)
    }
}
