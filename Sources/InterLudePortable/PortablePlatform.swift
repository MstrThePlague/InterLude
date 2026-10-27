import Foundation
import InterLudeCore

extension Platform {
    /// The implementations that work away from the Mac: decoding and encoding with ffmpeg and the core's own maths.
    /// A classifier and transcriber are added by whoever has the models (interlude-server, from InterLudeML).
    public static func portable(ffmpeg: URL) -> Platform {
        var p = Platform.portable
        p.decoder = FFmpegDecoder(executable: ffmpeg)
        p.encoder = FFmpegAACEncoder(executable: ffmpeg)
        return p
    }
}
