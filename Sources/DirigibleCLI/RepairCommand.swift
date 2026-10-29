import ArgumentParser
import DirigibleAudio
import DirigibleCore
import DirigibleMCP
import Foundation

extension ClipCommand {
    struct Repair: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Reduce rumble, repair clipped peaks, or soften harsh \"s\" sounds in clips.",
            discussion: """
                The command renders each run of clips of one file through the chosen repairs into a new \
                24-bit WAV in Clips/, with a 10 s handle on each side of the run, and moves the clips onto it. \
                The source file stays. A line has the clip and its new file, with a tab between them. \
                A clip that this version rendered renders again from its source; the same values print \
                "Nothing to change." and write nothing.

                --rumble is a high-pass filter at a whole number of Hz from 20 to 300; the default is 80. \
                --clipping repairs clipped peaks: a sample at or over this percent of the peak of the run, \
                from 90 to 100, is a clip candidate; the default is 99. The repair makes the clip quieter; \
                use clip gain to bring it back. A call or a compressed track can show no clipped peak. \
                --sibilance softens "s" sounds by a largest cut of 1 to 40 dB; the default is 10. \
                --sibilance-hz is the frequency of the cut, from 2000 to 16000 Hz; the default is 6000. It \
                needs --sibilance. A filter corner has a limit: 0.45 times the session rate. Give the \
                clips before the options, because an option with a bare name takes the next word as its value.

                Exit 64 when no repair is chosen, a value is outside its range, or --sibilance-hz comes with no \
                --sibilance. Exit 1 when a clip is unknown or a corner is over the limit of the session rate. \
                Exit 2 when the package cannot be read or written, is locked, has a take that is not finalized, \
                has a source WAV that is missing or unreadable, has too little free disk space, or the render \
                fails. Control-C leaves the package as it was and exits 130.
                """)

        @OptionGroup var package: PackageArgument
        @Argument(help: "A clip. Give one or more.")
        var clips: [String] = []
        @Option(
            defaultAsFlag: String(Rumble.standard.hertz), parsing: .next,
            help: ArgumentHelp(
                "Reduce rumble with a high-pass filter at this frequency in Hz, 20 to 300. The default is 80.",
                valueName: "hz"))
        var rumble: String?
        @Option(
            defaultAsFlag: String(Declip.standard.percent), parsing: .next,
            help: ArgumentHelp(
                "Repair clipped peaks. A sample at or over this percent of the peak of the run, 90 to 100, is a "
                    + "clip candidate. The default is 99.",
                valueName: "percent"))
        var clipping: String?
        @Option(
            defaultAsFlag: String(DeEss.standard.decibels), parsing: .next,
            help: ArgumentHelp(
                "Soften \"s\" sounds by a largest cut in dB, 1 to 40. The default is 10.", valueName: "dB"))
        var sibilance: String?
        @Option(
            name: .customLong("sibilance-hz"),
            help: ArgumentHelp(
                "The frequency of the sibilance repair in Hz, 2000 to 16000. The default is 6000. Needs --sibilance.",
                valueName: "hz"))
        var sibilanceHertz: String?

        func validate() throws {
            guard !clips.isEmpty else { throw ValidationError("Give one or more clips.") }
            _ = try request()
        }

        /// The request of the options. A combination or a value that `ClipRenderWork.repairRequest`
        /// refuses exits 64, and so does a text that is not a whole number.
        private func request() throws -> ClipRenderRequest {
            do throws(ClipRenderWork.RepairRefusal) {
                return try ClipRenderWork.repairRequest(
                    rumble: try whole(rumble, else: .rumble), clipping: try whole(clipping, else: .clipping),
                    sibilance: try whole(sibilance, else: .sibilance),
                    sibilanceHertz: try whole(sibilanceHertz, else: .sibilanceHertz))
            } catch {
                throw ValidationError(error.text)
            }
        }

        func run() throws {
            try runClipRender(ClipRenderWork(clips: clips.map { ClipID($0) }, request: try request()), in: package)
        }
    }
}

/// The whole number of `text`, or nil for no option. A text that is not a whole number is the refusal
/// of its option, with the range in its text.
private func whole(_ text: String?, else refusal: ClipRenderWork.RepairRefusal) throws(ClipRenderWork.RepairRefusal)
    -> Int?
{
    guard let text else { return nil }
    guard let value = Int(text) else { throw refusal }
    return value
}
