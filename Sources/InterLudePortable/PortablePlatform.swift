import Foundation
import InterLudeCore

extension Platform {
    /// The implementations that work away from the Mac. For now that is decoding with ffmpeg and the core's own maths;
    /// the classifier, the AAC encoder and the transcriber come in later milestones, and until then the core's
    /// stand-ins report them unavailable.
    public static func portable(ffmpeg: URL) -> Platform {
        var p = Platform.portable
        p.decoder = FFmpegDecoder(executable: ffmpeg)
        return p
    }
}
