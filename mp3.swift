// MP3 through LAME 4.0 (LGPL, lame.sourceforge.io, a separate library in the bundle): macOS reads MP3 but has no
// encoder for it. Mono, 48 kHz as Siri speaks, VBR quality 2 (LAME's -V 2, its recommended transparent setting), with
// the LAME tag at the start so every player shows the exact length at once, and an ID3v2.4 tag: the title, and a
// comment saying the speech is synthetic.

import CLame
import Foundation

final class MP3Writer {
    private let lame: OpaquePointer
    private let handle: FileHandle
    private var out = [UInt8](repeating: 0, count: 1 << 16)

    private var tagSize = 0

    init(url: URL, sampleRate: Int, title: String) throws {
        guard let l = lame_init() else { throw EngineError(description: "lame_init") }
        lame = l
        lame_set_in_samplerate(l, Int32(sampleRate))
        lame_set_out_samplerate(l, Int32(sampleRate))
        lame_set_num_channels(l, 1)
        lame_set_mode(l, MONO)
        lame_set_VBR(l, vbr_default)
        lame_set_VBR_quality(l, 2)
        lame_set_quality(l, 2)
        lame_set_bWriteVbrTag(l, 1)
        id3tag_init(l)
        id3tag_add_v2_4_UTF8(l)
        id3tag_v2_only(l)
        _ = id3tag_set_textinfo_utf8(l, "TIT2", title)
        _ = id3tag_set_comment_utf8(l, "eng", "", "Synthetic speech, made with TTS")
        guard lame_init_params(l) >= 0 else { lame_close(l); throw EngineError(description: "lame_init_params") }
        tagSize = lame_get_id3v2_tag(l, nil, 0)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            lame_close(l); throw EngineError(description: "\(url.path)\n\(String(cString: strerror(errno)))")
        }
        handle = try FileHandle(forWritingTo: url)
    }

    deinit { lame_close(lame) }

    func write(_ samples: UnsafePointer<Float>, count: Int) throws {
        var done = 0
        while done < count {
            let n = min(8192, count - done)
            let need = Int(1.25 * Double(n)) + 7200
            if out.count < need { out = [UInt8](repeating: 0, count: need) }
            let r = out.withUnsafeMutableBufferPointer {
                lame_encode_buffer_ieee_float(lame, samples + done, samples + done, Int32(n), $0.baseAddress, Int32($0.count))
            }
            guard r >= 0 else { throw EngineError(description: "lame_encode \(r)") }
            if r > 0 { try handle.write(contentsOf: out[0..<Int(r)]) }
            done += n
        }
    }

    func finish() throws {
        let r = out.withUnsafeMutableBufferPointer { lame_encode_flush(lame, $0.baseAddress, Int32($0.count)) }
        if r > 0 { try handle.write(contentsOf: out[0..<Int(r)]) }
        // The VBR (LAME) tag goes over the first frame, right after the ID3 tag.
        var tag = [UInt8](repeating: 0, count: 2880)
        let n = tag.withUnsafeMutableBufferPointer { lame_get_lametag_frame(lame, $0.baseAddress, $0.count) }
        if n > 0 && n <= tag.count {
            try handle.seek(toOffset: UInt64(tagSize))
            try handle.write(contentsOf: tag[0..<n])
        }
        try handle.close()
    }
}
