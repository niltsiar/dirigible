import Foundation
import Testing

@testable import DirigibleAudio

/// Times are in ticks of 10 ms, the frame of the word end step and the time unit of whisper.cpp.
struct WordEndsTests {
    /// Samples at -6 dBFS in each burst and digital silence elsewhere, at 16 kHz. The step reads
    /// only the peak of each frame, so a flat burst does for a tone.
    static func samples(_ bursts: [Range<Int>], ticks: Int) -> [Float] {
        var out = [Float](repeating: 0, count: ticks * 160)
        for burst in bursts {
            let range = (burst.lowerBound * 160)..<min(burst.upperBound * 160, out.count)
            out.replaceSubrange(range, with: repeatElement(0.5, count: range.count))
        }
        return out
    }

    static func word(_ text: String, _ start: Int, _ end: Int) -> TimedWord {
        TimedWord(text: text, start: start, end: end)
    }

    /// Checks the contract of the step on one input: each word has start < end. A word that took
    /// the empty-interval clause ends at most at the next start, the piece end, and its start + 1 s,
    /// or one tick after its start when that cap is not after it. Any other word ends at its token
    /// end or at the start of a gap within 1 s of its token end.
    static func checkContract(_ words: [TimedWord], samples: [Float], _ comment: Comment) {
        let placed = WordEnds.place(words, samples: samples)
        let levels = WordEnds.levels(of: samples)
        let gaps = WordEnds.gaps(in: levels, floor: WordEnds.floor(of: levels))
        #expect(placed.count == words.count, comment)
        for (k, (word, out)) in zip(words, placed).enumerated() {
            #expect(out.start < out.end, "\(comment): word \(k) \(word) gives \(out)")
            let gapEnd = gaps.contains { $0.lowerBound == out.end && WordEnds.distance(word.end, $0) <= 100 }
            let cap = min(k + 1 < placed.count ? placed[k + 1].start : Int.max, levels.count, out.start + 100)
            let clauseEnd = cap > out.start ? out.end <= cap : out.end == out.start + 1
            #expect(out.end == word.end || gapEnd || clauseEnd, "\(comment): word \(k) \(word) gives \(out)")
        }
    }

    @Test func everyWordEndsAfterItStarts() {
        // The cascade: "7," takes the gap 213..<242 and reverts, so the gap goes back; "carry" has a
        // token start after that gap end, takes the gap 246..<270, and reverts too.
        let cascade = Self.samples([150..<213, 242..<246, 270..<330], ticks: 400)
        let cascadeWords = [
            Self.word("at", 150, 200), Self.word("7,", 245, 250), Self.word("carry", 250, 252),
            Self.word("on", 255, 330),
        ]
        Self.checkContract(cascadeWords, samples: cascade, "cascade")
        #expect(
            WordEnds.place(cascadeWords, samples: cascade) == [
                Self.word("at", 150, 200), Self.word("7,", 245, 250), Self.word("carry", 250, 252),
                Self.word("on", 255, 330),
            ])

        var random = SeededGenerator(seed: 24)
        for trial in 0..<80 {
            var bursts: [Range<Int>] = []
            var words: [TimedWord] = []
            var tick = Int.random(in: 0...80, using: &random)
            let pauses = trial % 5 != 0
            while tick < 800 {
                let length = Int.random(in: 10...90, using: &random)
                bursts.append(tick..<(tick + length))
                let jitter = { (spread: Int) in Int.random(in: -spread...spread, using: &random) }
                let start = max(0, tick + jitter(40))
                let end: Int
                switch Int.random(in: 0..<10, using: &random) {
                case 0: end = start
                case 1: end = max(0, start - Int.random(in: 1...20, using: &random))
                default: end = max(0, tick + length + jitter(60))
                }
                let mark = [",", ".", "", "", ""].randomElement(using: &random)!
                words.append(Self.word("w\(words.count)\(mark)", start, end))
                tick += length + (pauses ? Int.random(in: 0...70, using: &random) : 0)
            }
            Self.checkContract(words, samples: Self.samples(bursts, ticks: tick + 20), "trial \(trial)")
        }
    }

    @Test func aLateTokenEndMovesToTheGapStart() {
        let samples = Self.samples([100..<150, 200..<260], ticks: 320)
        let placed = WordEnds.place([Self.word("one", 100, 200), Self.word("two", 205, 260)], samples: samples)
        #expect(abs(placed[0].end - 150) <= 1)
    }

    @Test func aLateTokenStartMovesToThePreviousGapEnd() {
        let samples = Self.samples([100..<150, 200..<260], ticks: 320)
        let placed = WordEnds.place([Self.word("one", 100, 150), Self.word("two", 230, 260)], samples: samples)
        #expect(placed[1].start == 200)
    }

    @Test func aWordWithNoGapKeepsItsTokenEnd() {
        let samples = Self.samples([100..<300], ticks: 400)
        let placed = WordEnds.place([Self.word("one", 100, 180), Self.word("two", 180, 290)], samples: samples)
        #expect(placed == [Self.word("one", 100, 180), Self.word("two", 180, 300)])
    }

    @Test func aWordWhoseMovedEndIsNotAfterItsStartKeepsItsTokenTimes() {
        // The pause 213..<242 lies before "seven", but whisper writes "7," at 240..<250, so the
        // alignment gives the pause to "7,": its end would be 213, before its start 240.
        let samples = Self.samples([150..<213, 242..<360], ticks: 420)
        let words = [Self.word("at", 150, 200), Self.word("7,", 240, 250), Self.word("carrying", 250, 340)]
        #expect(WordEnds.alignment(of: words, to: [213..<242, 360..<420]) == [nil, 0, 1])
        let placed = WordEnds.place(words, samples: samples)
        #expect(placed[1] == Self.word("7,", 240, 250))
        #expect(placed[2].start == 250)
    }

    @Test func aLastWordWithAnEmptyIntervalEndsAtTheFirstQuietFrame() {
        let quiet = WordEnds.place([Self.word("end", 100, 100)], samples: Self.samples([100..<160], ticks: 300))
        #expect(quiet == [Self.word("end", 100, 160)])
        let runOn = WordEnds.place([Self.word("end", 100, 100)], samples: Self.samples([100..<160], ticks: 160))
        #expect(runOn == [Self.word("end", 100, 160)])
    }

    @Test func aWordWithAnEmptyIntervalBeforeALongPauseEndsWithinOneSecond() {
        let samples = Self.samples([100..<130, 430..<480], ticks: 540)
        let placed = WordEnds.place([Self.word("one", 100, 100), Self.word("two", 430, 480)], samples: samples)
        #expect(placed[0].end > 100 && placed[0].end <= 200)
    }

    @Test func aWordWithAnEmptyIntervalEndsAtTheNextStartWhenTheBurstRunsOn() {
        let samples = Self.samples([100..<400], ticks: 460)
        let placed = WordEnds.place([Self.word("one", 100, 100), Self.word("two", 150, 400)], samples: samples)
        #expect(placed[0] == Self.word("one", 100, 150))
    }

    @Test func aWordWithAnEmptyIntervalAtTheNextStartGetsOneTick() {
        let samples = Self.samples([100..<400], ticks: 460)
        let placed = WordEnds.place([Self.word("one", 100, 100), Self.word("two", 100, 400)], samples: samples)
        #expect(placed[0] == Self.word("one", 100, 101))
    }

    @Test func eachGapGoesToOneWordInTimeOrder() {
        var random = SeededGenerator(seed: 7)
        for _ in 0..<50 {
            var gaps: [Range<Int>] = []
            var tick = 0
            for _ in 0..<20 {
                tick += Int.random(in: 5...60, using: &random)
                let length = Int.random(in: 20...80, using: &random)
                gaps.append(tick..<(tick + length))
                tick += length
            }
            var words: [TimedWord] = []
            var at = 0
            while at < tick {
                let end = at + Int.random(in: 5...50, using: &random)
                words.append(Self.word(Bool.random(using: &random) ? "w," : "w", at, end))
                at = end + Int.random(in: 0...30, using: &random)
            }
            let taken = WordEnds.alignment(of: words, to: gaps).compactMap { $0 }
            #expect(taken == taken.sorted() && Set(taken).count == taken.count)
        }
    }

    @Test func aPunctuatedWordTakesThePause() {
        let samples = Self.samples([100..<160, 200..<230, 260..<300], ticks: 360)
        let words = [Self.word("city,", 100, 140), Self.word("the", 195, 205), Self.word("sun", 260, 300)]
        let placed = WordEnds.place(words, samples: samples)
        #expect(placed[0].end == 160 && placed[1].start == 200)
        let plain = WordEnds.place([Self.word("city", 100, 140)] + words.dropFirst(), samples: samples)
        #expect(plain[0].end == 140)
    }

    @Test func aNoiseFloorRaisesTheFloor() {
        var samples = Self.samples([100..<160, 200..<260], ticks: 320)
        var random = SeededGenerator(seed: 45)
        let rms = Float(pow(10, -45.0 / 20))
        for n in samples.indices {
            // Box-Muller: a normal sample with the RMS above.
            let u = Double.random(in: Double.ulpOfOne..<1, using: &random)
            let v = Double.random(in: 0..<1, using: &random)
            samples[n] += rms * Float(sqrt(-2 * log(u)) * cos(2 * Double.pi * v))
        }
        let levels = WordEnds.levels(of: samples)
        let floor = WordEnds.floor(of: levels)
        #expect(floor == levels.sorted()[levels.count / 5] + 6 && floor > -40)
        let placed = WordEnds.place([Self.word("one", 100, 200), Self.word("two", 205, 260)], samples: samples)
        #expect(abs(placed[0].end - 160) <= 10)
    }
}
