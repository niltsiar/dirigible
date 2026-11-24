import Testing

@testable import DirigibleAudio

/// Decision 0065 D7b. The drop of episode 360: in piece 2, whisper.cpp gives the segment 103.91 s to
/// 116.45 s with 10 words, and a fresh call on 103.45 s to 117.20 s gives 29 words (`redecoded`).
struct ThinSegmentsTests {
    /// Rows "start end words" as segments with consecutive word ranges.
    static func segments(_ rows: String) -> [DecodedSegment] {
        let numbers = rows.split(whereSeparator: \.isWhitespace).map { Int($0)! }
        var segments: [DecodedSegment] = []
        for row in stride(from: 0, to: numbers.count, by: 3) {
            let first = segments.last?.words.upperBound ?? 0
            segments.append(
                DecodedSegment(start: numbers[row], end: numbers[row + 1], words: first..<(first + numbers[row + 2])))
        }
        return segments
    }

    /// Triples "text start end" as words.
    static func words(_ triples: String) -> [TimedWord] {
        let parts = triples.split(whereSeparator: \.isWhitespace).map(String.init)
        return stride(from: 0, to: parts.count, by: 3).map {
            TimedWord(text: parts[$0], start: Int(parts[$0 + 1])!, end: Int(parts[$0 + 2])!)
        }
    }

    static func distinct(_ count: Int) -> [TimedWord] {
        (0..<count).map { TimedWord(text: "w\($0)", start: 10391 + $0, end: 10392 + $0) }
    }

    static func ticks(samples: Int) -> Int { (samples + 159) / 160 }

    /// The first pass of piece 2 from 101.41 s to 121.12 s: the segment before, the thin segment, and
    /// the segment after, whose "Esto" starts at 117.09 s, inside the span.
    static let firstPass = words(
        """
        Esta 10141 10142  es 10146 10152  la 10152 10164  última 10164 10202  que 10202 10208  tengo 10223 10252
        en 10252 10262  la 10270 10275  memoria. 10280 10353
        Y 10383 10419  bueno, 10419 10613  pues 10613 10702  necesita 10731 10933  que 10970 11029  haya 11029 11067
        menos 11094 11279  mano 11279 11390  de 11390 11468  obra. 11501 11648
        Esto 11709 11720  no 11720 11721  tiene 11721 11725  por 11725 11734  qué 11734 11754  afectar 11754 11801
        a 11802 11806  todos, 11806 11852  pero 11852 11878  claro, 11878 11924  yo 11925 11937  no 11937 11949
        tengo 11958 11983  la 11983 11996  bola 11996 12022  de 12022 12040  cristal. 12040 12112
        """)
    static let pieceSegments = segments("10141 10345 9  10391 11645 10  11720 12112 17")
    static let dropSpan = ThinSpan(start: 10345, end: 11720, thin: [pieceSegments[1]])
    /// The fresh call on the span: "o" starts at the span start, before the thin segment start 103.91 s.
    static let redecoded = words(
        """
        o 10345 10353  bajas 10383 10402  voluntarias, 10402 10518  llámalo 10522 10553  como 10553 10572
        quieras, 10572 10622  porque 10622 10650  tiene 10658 10675  que 10685 10703  hacerse 10703 10754
        cargo 10761 10803  del 10803 10812  soporte 10845 10939  de 10939 10966  todo 10966 11020  el 11020 11067
        contexto 11094 11155  de 11155 11161  la 11176 11177  inteligencia 11185 11251  artificial 11251 11305
        y 11313 11321  necesita 11353 11408  que 11408 11440  haya 11440 11468  menos 11501 11531  mano 11535 11577
        de 11577 11598  obra. 11598 11648
        """)

    static func spans(_ rows: String, samples: Int, language: String = "es") -> [ThinSpan] {
        ThinSegments.spans(of: segments(rows), pieceEnd: ticks(samples: samples), language: language)
    }

    @Test func theDroppedSegmentOfEpisode360IsTheOnlyThinSpan() {
        let spans = Self.spans(ThinSegmentsTables.pieceTwo, samples: ThinSegmentsTables.pieceTwoSamples)
        #expect(spans.map { $0.start..<$0.end } == [10345..<11720])
        #expect(spans.map(\.thin) == [[DecodedSegment(start: 10391, end: 11645, words: 286..<296)]])
    }

    @Test func aSegmentAtTheLimitsIsNotThin() {
        func spanCount(ticks: Int, words: Int) -> Int {
            ThinSegments.spans(
                of: [DecodedSegment(start: 1000, end: 1000 + ticks, words: 0..<words)], pieceEnd: 5000, language: "es"
            ).count
        }
        #expect(spanCount(ticks: 490, words: 2) == 0, "4.9 s, under the 5.0 s floor")
        #expect(spanCount(ticks: 600, words: 6) == 0, "1.0 s per word")
        #expect(spanCount(ticks: 1289, words: 23) == 0, "0.56 s per word")
        #expect(spanCount(ticks: 500, words: 4) == 1, "5.0 s, 1.25 s per word")
        #expect(spanCount(ticks: 601, words: 6) == 1, "6.01 s, 6 words")
    }

    @Test func theFirstAndLastSegmentUseThePieceBounds() {
        let spans = ThinSegments.spans(
            of: Self.segments("300 900 2  1000 1200 5  1300 2000 3"), pieceEnd: 2500, language: "es")
        #expect(spans.map { $0.start..<$0.end } == [0..<1000, 1200..<2500])
    }

    /// The three thin segments of the S1 t1 table: 10.68 s to 42.81 s, 42.81 s to 57.35 s, and 55.07 s to 76.97 s.
    @Test func overlappingOrAdjacentSpansMergeIntoOneCall() throws {
        let track = try #require(ThinSegmentsTables.trialTracks.first { $0.name == "S1-t1" })
        let spans = Self.spans(track.rows, samples: track.samples)
        #expect(spans.map { $0.start..<$0.end } == [1068..<7697])
        #expect(spans.map { $0.thin.map(\.start) } == [[1068, 4281, 5735]])
    }

    /// Five disjoint thin spans with 3, 2, 4, 2, and 5 words: the second 2 goes, a tie that comes later.
    @Test func aPieceStopsAtTheCapOfSecondCalls() {
        let rows = [3, 2, 4, 2, 5].enumerated().map { n, words in
            "\(2000 * n + 100) \(2000 * n + 1100) \(words)  \(2000 * n + 1200) \(2000 * n + 1400) 3"
        }
        let segments = Self.segments(rows.joined(separator: "  "))
        #expect(ThinSegments.calls(of: segments, pieceEnd: 10_000, language: "es").count == 5)
        let spans = ThinSegments.spans(of: segments, pieceEnd: 10_000, language: "es")
        #expect(spans.map(\.start) == [0, 1400, 3400, 7400])
        #expect(spans.map(\.firstPassWordCount) == [3, 2, 4, 5])
    }

    @Test func aLanguageWithNoSpacesHasNoThinSpan() {
        let table = ThinSegmentsTables.pieceTwo
        #expect(Self.spans(table, samples: ThinSegmentsTables.pieceTwoSamples, language: "es").count == 1)
        for code in ["zh", "ja", "th", "lo", "km", "my", "bo", "yue"] {
            #expect(Self.spans(table, samples: ThinSegmentsTables.pieceTwoSamples, language: code).isEmpty, "\(code)")
        }
    }

    @Test func theMergeReplacesOnlyTheWordsOfTheThinSegment() {
        let merged = ThinSegments.merge(Self.firstPass, blocks: [(Self.dropSpan, Self.redecoded)])
        #expect(merged == Array(Self.firstPass[0..<9]) + Self.redecoded + Array(Self.firstPass[19...]))
    }

    /// The midpoint of the first-pass "Esto" (117.09 s to 117.20 s) is inside the span, but the word
    /// belongs to the next segment.
    @Test func aNextSegmentWordInsideTheSpanStays() {
        let merged = ThinSegments.merge(Self.firstPass, blocks: [(Self.dropSpan, Self.redecoded)])
        #expect(merged.filter { $0.text == "Esto" } == [TimedWord(text: "Esto", start: 11709, end: 11720)])
        let obra = merged.firstIndex { $0.text == "obra." }
        #expect(obra.map { merged[$0 + 1].text } == "Esto")
    }

    /// A copy of the 1 to 4 first-pass words on each side of the drop span, at an edge of the second
    /// pass, goes; a copy of 5 words is over the cap and stays.
    @Test func anEdgeRunOfUpToFourRepeatedWordsGoes() {
        func kept(_ again: [TimedWord]) -> [TimedWord] {
            ThinSegments.kept(again, first: Self.firstPass, span: Self.dropSpan)
        }
        let (before, after) = (Self.firstPass[0..<9], Self.firstPass[19...])
        for count in 1...4 {
            #expect(kept(Array(before.suffix(count)) + Self.redecoded) == Self.redecoded, "\(count) before")
            #expect(kept(Self.redecoded + Array(after.prefix(count))) == Self.redecoded, "\(count) after")
        }
        let five = Array(before.suffix(5)) + Self.redecoded
        #expect(kept(five) == five)
        let memoria = TimedWord(text: "Memória,", start: 10346, end: 10360)
        #expect(kept([memoria] + Self.redecoded) == Self.redecoded, "case, accents, and punctuation ignored")
        let later = TimedWord(text: "Esto", start: 11830, end: 11840)
        #expect(kept(Self.redecoded + [later]) == Self.redecoded + [later], "1.21 s after the first-pass Esto")
    }

    /// S1 t1, the call on 42.81 s to 57.35 s: the first pass before the thin segment ends "si es verdad",
    /// and its "verdad" starts at 16.50 s, 26.82 s before the speech, because of the VAD time map.
    @Test func aSecondPassRunThatRepeatsTheWordsBeforeTheSpanGoes() {
        let first = Self.words(
            """
            fritas 1025 1074  si 1125 1459  es 1485 1623  verdad 1650 4302  teatra 4326 5458  ¿no? 5490 5600
            en 5646 5770  esta 6513 7508
            """)
        let segments = Self.segments("1024 1068 1  1068 4281 3  4281 5507 2  5735 7697 2")
        let span = ThinSpan(start: 4281, end: 5735, thin: [segments[2]])
        let again = Self.words("Es 4332 4333  verdad. 4333 4363  Tracatrá, 4869 4883  ¿no? 5381 5600")
        #expect(ThinSegments.kept(again, first: first, span: span) == Array(again[2...]))
    }

    /// The second pass of the drop span ends "obra. Esto no", and the next segment starts "Esto no tiene".
    @Test func aSecondPassRunThatRepeatsTheWordsAfterTheSpanGoes() {
        let again = Self.redecoded + Self.words("Esto 11710 11718  no 11719 11720")
        #expect(ThinSegments.kept(again, first: Self.firstPass, span: Self.dropSpan) == Self.redecoded)
    }

    @Test func aSecondPassWordBeforeTheThinSegmentInsideTheSpanStays() {
        let kept = ThinSegments.kept(Self.redecoded, first: Self.firstPass, span: Self.dropSpan)
        #expect(kept.first == TimedWord(text: "o", start: 10345, end: 10353))
        let merged = ThinSegments.merge(Self.firstPass, blocks: [(Self.dropSpan, kept)])
        #expect(merged[8...9].map(\.text) == ["memoria.", "o"])
    }

    /// The shape of X3 t1 r2: the span ends at 160.39 s, and 8 of the 10 second-pass words start there or later.
    @Test func secondPassWordsPastTheSpanEndStayInCallOrder() {
        let first = Self.words(
            """
            bien 14000 14100  O 14131 14300  sea, 14300 14500  que 14600 14800  ahora 14900 15100  estás 15100 15300
            con 15300 15400  los 15400 15500  100 15500 15700  de 15700 15800  esto. 15800 16031  Vale 16039 16100
            """)
        let segments = Self.segments("13900 14131 1  14131 16031 10  16039 16200 1")
        let span = ThinSpan(start: 14131, end: 16039, thin: [segments[1]])
        let again = Self.words(
            """
            o 14131 14140  sea 14140 14200  que 16039 16040  ahora 16040 16041  estás 16041 16042  con 16042 16043
            los 16043 16044  100 16044 16045  de 16045 16046  esto 16046 16047
            """)
        let kept = ThinSegments.kept(again, first: first, span: span)
        #expect(ThinSegments.merge(first, blocks: [(span, kept)]) == [first[0]] + again + [first[11]])
    }

    @Test func theRedecodeOfEpisode360IsAccepted() {
        #expect(ThinSegments.accepts(Self.redecoded, over: Self.dropSpan.thin))
        let composed = ThinSegments.compose(
            first: Self.firstPass, language: "es",
            redecodes: [Redecode(span: Self.dropSpan, outcome: .words(Self.redecoded))])
        let note = RedecodeNote(start: 10345, end: 11720, before: 10, result: .compared(after: 29, kept: .secondPass))
        #expect(composed.notes == [note])
        let expected = Array(Self.firstPass[0..<9]) + Self.redecoded + Array(Self.firstPass[19...])
        #expect(composed.outcome == .words(expected, language: "es"))
    }

    /// Over the thin segment of 12.54 s with 10 first-pass words.
    @Test func aLoopADenseOrAThinRedecodeIsRefused() {
        func accepts(_ words: [TimedWord]) -> Bool { ThinSegments.accepts(words, over: Self.dropSpan.thin) }
        func repeated(_ text: String) -> [TimedWord] {
            Self.words(text.split(separator: " ").map { "\($0) 11600 11601" }.joined(separator: " "))
        }
        #expect(!accepts(Array(Self.redecoded[0..<23]) + repeated("mmhmm mmhmm mmhmm mmhmm mmhmm mmhmm")))
        #expect(accepts(Array(Self.redecoded[0..<26]) + repeated("sí sí sí")))
        #expect(accepts(Array(Self.redecoded[0..<21]) + repeated("ha salido de compras ha salido de compras")))
        #expect(!accepts(Self.distinct(80)), "6.38 words per second")
        #expect(accepts(Self.distinct(75)), "5.98 words per second")
        #expect(!accepts(Self.distinct(11)), "1.14 s per word, still thin")
        #expect(accepts(Self.distinct(13)), "0.96 s per word")
    }

    @Test func fewerOrEqualWordsKeepTheFirstPass() {
        for count in [9, 10] {
            let composed = ThinSegments.compose(
                first: Self.firstPass, language: "es",
                redecodes: [Redecode(span: Self.dropSpan, outcome: .words(Self.distinct(count)))])
            #expect(composed.outcome == .words(Self.firstPass, language: "es"), "\(count) words")
            #expect(composed.notes.map(\.result) == [.compared(after: count, kept: .firstPass)])
        }
    }

    @Test func aTickSpanGivesTheSampleRangeClampedToThePiece() {
        #expect(ThinSegments.sampleRange(ticks: 10345..<11720, count: 9_557_200) == 1_655_200..<1_875_200)
        #expect(ThinSegments.sampleRange(ticks: 59700..<59733, count: 9_557_200) == 9_552_000..<9_557_200)
    }

    @Test func secondPassWordsShiftByTheSpanStart() {
        let shifted = ThinSegments.shifted([TimedWord(text: "o", start: 8, end: 20)], byTicks: 10345)
        #expect(shifted == [TimedWord(text: "o", start: 10353, end: 10365)])
    }

    @Test func aNormalPieceHasNoThinSpan() {
        #expect(Self.spans(ThinSegmentsTables.pieceTwoCut, samples: ThinSegmentsTables.pieceTwoCutSamples).isEmpty)
        #expect(Self.spans(ThinSegmentsTables.pieceTwo, samples: ThinSegmentsTables.pieceTwoSamples).count == 1)
    }

    /// The counts of the probe of the trial tracks: 24 thin segments in 17 calls on 10 tracks.
    @Test func theTrialTracksStayUnderTheCap() {
        let expected: [String: (thin: Int, calls: Int)] = [
            "S1-t1": (3, 1), "S1-t2": (0, 0), "X1-t1": (2, 2), "X1-t2": (4, 2), "X2-t1": (6, 4),
            "X2-t2": (2, 1), "X3-t1": (2, 2), "X3-t2": (2, 2), "X4-t1": (3, 3), "X4-t2": (0, 0),
        ]
        #expect(ThinSegmentsTables.trialTracks.map(\.name).sorted() == expected.keys.sorted())
        for track in ThinSegmentsTables.trialTracks {
            let calls = ThinSegments.calls(
                of: Self.segments(track.rows), pieceEnd: Self.ticks(samples: track.samples), language: "es")
            #expect(calls.flatMap(\.thin).count == expected[track.name]?.thin, "\(track.name)")
            #expect(calls.count == expected[track.name]?.calls, "\(track.name)")
            #expect(calls.count <= ThinSegments.callCap, "\(track.name)")
        }
    }

    /// Each recorded re-decode of the trial tracks has as many words as the first pass or fewer, or
    /// stays thin. Distinct words stand for its words: more words only make a call more likely to pass.
    @Test func theTrialRedecodesAreRefused() {
        let lines = ThinSegmentsTables.trialRedecodes.split(separator: "\n")
        #expect(lines.count == 23)
        for line in lines {
            let parts = line.split(separator: " ", maxSplits: 2)
            let again = Self.distinct(Int(parts[1])!)
            #expect(!ThinSegments.accepts(again, over: Self.segments(String(parts[2]))), "\(line)")
        }
    }

    @Test func aStoppedRedecodeStopsThePiece() {
        let accepted = Redecode(span: Self.dropSpan, outcome: .words(Self.redecoded))
        let finished = ThinSegments.compose(first: Self.firstPass, language: "es", redecodes: [accepted])
        #expect(finished.outcome != .stopped)
        let stopped = Redecode(span: Self.dropSpan, outcome: .stopped)
        let composed = ThinSegments.compose(first: Self.firstPass, language: "es", redecodes: [accepted, stopped])
        #expect(composed.outcome == .stopped)
    }

    @Test func aFailedRedecodeKeepsTheFirstPassAndNotesTheFault() {
        let failed = Redecode(span: Self.dropSpan, outcome: .failed(code: -7))
        let composed = ThinSegments.compose(first: Self.firstPass, language: "es", redecodes: [failed])
        #expect(composed.outcome == .words(Self.firstPass, language: "es"))
        #expect(composed.notes == [RedecodeNote(start: 10345, end: 11720, before: 10, result: .failed(code: -7))])
    }

    /// A leading quote at the end of segment 0 joins the letters of segment 1: the word is of segment 1.
    @Test func aWordBelongsToTheSegmentOfItsFirstLetterToken() {
        let tokens = [
            WhisperToken(bytes: Array(" Hola".utf8), start: 10, end: 40, isSpecial: false, segment: 0),
            WhisperToken(bytes: Array(" \"".utf8), start: 45, end: 50, isSpecial: false, segment: 0),
            WhisperToken(bytes: Array("Bien".utf8), start: 60, end: 90, isSpecial: false, segment: 1),
            WhisperToken(bytes: Array(" ya".utf8), start: 95, end: 99, isSpecial: false, segment: 2),
        ]
        let joined = WhisperWords.joinWithSegments(tokens)
        #expect(joined.map(\.word.text) == ["Hola", "\"Bien", "ya"])
        #expect(joined.map(\.segment) == [0, 1, 2])
        let segments = ThinSegments.segments([(0, 44), (44, 92), (92, 100), (100, 120)], wordSegments: [0, 1, 2])
        #expect(segments.map(\.words) == [0..<1, 1..<2, 2..<3, 3..<3])
    }
}
