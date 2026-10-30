import DirigibleCore
import Foundation

/// The text of the transcript pane (run transcript-1, landing 2). Every range is in UTF-16 units
/// of `string`, so the pane reads it as an `NSRange`.
public struct TranscriptText: Equatable, Sendable {
    /// A paragraph header "<track name> · h:mm:ss".
    public struct Header: Equatable, Sendable {
        public let range: Range<Int>
        public let track: TrackID
    }

    /// A line "<track name>: <text>" for a short run of another track inside a paragraph.
    public struct Backchannel: Equatable, Sendable {
        public let line: Range<Int>
        public let name: Range<Int>
        public let track: TrackID
    }

    /// One shown word or cue, and its range in the text.
    public struct Unit: Equatable, Sendable {
        public let occurrence: WordOccurrence
        public let track: TrackID
        public let frames: Range<Frames>
        public let text: Range<Int>
    }

    public let string: String
    public let headers: [Header]
    public let backchannels: [Backchannel]
    /// In text order.
    public let units: [Unit]
    /// Indexes into `units` in start order, and the largest end among the units up to each one.
    private let startOrder: [Int]
    private let latestEnd: [Frames]
    /// The line of each unit, counted from 0: two units are on one line when the numbers are equal.
    let lines: [Int]

    public init(session: Session) {
        let names = Dictionary(uniqueKeysWithValues: session.tracks.map { ($0.id, $0.name) })
        var text = Builder()
        var headers: [Header] = []
        var backchannels: [Backchannel] = []
        var units: [Unit] = []
        var lines: [Int] = []

        func add(_ words: [SpokenWord]) {
            let line = (lines.last ?? -1) + 1
            for (index, word) in words.enumerated() {
                lines.append(line)
                if index > 0 { text.append(" ") }
                units.append(
                    Unit(
                        occurrence: word.occurrence, track: word.track, frames: word.range,
                        text: text.append(word.text)))
            }
        }

        for paragraph in Self.paragraphs(of: session.words(), rate: session.sampleRate) {
            let seconds = max(0, paragraph.units[0].range.lowerBound.count) / session.sampleRate
            let time = String(format: "%ld:%02ld:%02ld", seconds / 3600, seconds / 60 % 60, seconds % 60)
            let name = names[paragraph.track, default: paragraph.track.rawValue]
            headers.append(Header(range: text.append("\(name) · \(time)"), track: paragraph.track))
            text.append("\n")
            add(paragraph.units)
            text.append("\n")
            for run in paragraph.backchannels {
                let track = run[0].track
                let nameRange = text.append(names[track, default: track.rawValue])
                text.append(": ")
                add(run)
                backchannels.append(
                    Backchannel(line: nameRange.lowerBound..<text.offset, name: nameRange, track: track))
                text.append("\n")
            }
        }

        let startOrder = units.indices.sorted { units[$0].frames.lowerBound < units[$1].frames.lowerBound }
        var latest = Frames.zero
        string = text.string
        self.headers = headers
        self.backchannels = backchannels
        self.units = units
        self.lines = lines
        self.startOrder = startOrder
        latestEnd = startOrder.map {
            latest = max(latest, units[$0].frames.upperBound)
            return latest
        }
    }

    /// The units whose frames hold `frame`, in text order. The start frame is in a unit and the end
    /// frame is not.
    public func units(at frame: Frames) -> [Unit] {
        var (low, high) = (0, startOrder.count)
        while low < high {
            let middle = (low + high) / 2
            if units[startOrder[middle]].frames.lowerBound <= frame { low = middle + 1 } else { high = middle }
        }
        var found: [Int] = []
        var index = low - 1
        while index >= 0, latestEnd[index] > frame {
            if units[startOrder[index]].frames.upperBound > frame { found.append(startOrder[index]) }
            index -= 1
        }
        return found.sorted().map { units[$0] }
    }
}

extension TranscriptText {
    private struct Builder {
        var string = ""
        var offset = 0

        @discardableResult
        mutating func append(_ piece: String) -> Range<Int> {
            let range = offset..<offset + piece.utf16.count
            string += piece
            offset = range.upperBound
            return range
        }
    }

    /// The units of one track, and the short runs of other tracks that go after them.
    private struct Paragraph {
        let track: TrackID
        var units: [SpokenWord] = []
        var backchannels: [[SpokenWord]] = []
    }

    /// A sequence of adjacent units (in start order) of one track.
    private struct Run {
        let track: TrackID
        let units: Range<Int>
        let start: Frames
        let span: Frames
    }

    /// A pause of 1.5 s on one track starts a paragraph, and so does a change of track. A run of
    /// another track with a span under 1 s between two units that the pause rule keeps together is
    /// a backchannel: it does not split the paragraph. When one run between them is longer, the
    /// track rule applies to all the runs.
    private static func paragraphs(of words: [SpokenWord], rate: Int) -> [Paragraph] {
        var runs: [Run] = []
        var first = 0
        while first < words.count {
            var last = first + 1
            var end = words[first].range.upperBound
            while last < words.count, words[last].track == words[first].track {
                end = max(end, words[last].range.upperBound)
                last += 1
            }
            let start = words[first].range.lowerBound
            runs.append(Run(track: words[first].track, units: first..<last, start: start, span: end - start))
            first = last
        }

        func isPause(_ gap: Frames) -> Bool { gap.count * 2 >= rate * 3 }

        /// The run of `track` that goes on a paragraph that ends at `end`, after the run `index`.
        /// A run that starts after a pause ends the search: no later run starts sooner.
        func continuation(of track: TrackID, after index: Int, end: Frames) -> Int? {
            for next in runs.indices.dropFirst(index + 1) {
                let run = runs[next]
                guard !isPause(run.start - end) else { return nil }
                if run.track == track { return next }
                guard run.span.count < rate else { return nil }
            }
            return nil
        }

        var paragraphs: [Paragraph] = []
        var cursor = 0
        var current = 0
        while cursor < words.count {
            var paragraph = Paragraph(track: runs[current].track)
            var end = Frames.zero
            fill: while true {
                while cursor < runs[current].units.upperBound {
                    let word = words[cursor]
                    if !paragraph.units.isEmpty, isPause(word.range.lowerBound - end) { break fill }
                    paragraph.units.append(word)
                    end = max(end, word.range.upperBound)
                    cursor += 1
                }
                guard let next = continuation(of: paragraph.track, after: current, end: end) else { break }
                paragraph.backchannels += runs[(current + 1)..<next].map { Array(words[$0.units]) }
                current = next
                cursor = runs[next].units.lowerBound
            }
            if current < runs.count, cursor == runs[current].units.upperBound { current += 1 }
            paragraphs.append(paragraph)
        }
        return paragraphs
    }
}
