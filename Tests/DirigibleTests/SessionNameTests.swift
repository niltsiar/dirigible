import Testing

@testable import DirigibleApp

/// The rule of the name field of the start window (decision 0027). A unit test: the rule is a pure
/// function with many edge cases.
struct SessionNameTests {
    /// Criterion C11: the literal cases and the reason of each refusal. The long cases use "é",
    /// which is 2 UTF-8 bytes, so a count of characters accepts the 246-byte name.
    @Test func theNameRule() {
        let accent = "\u{E9}"
        let cases: [(text: String, refusal: SessionName.Refusal?, rule: Comment)] = [
            ("", .empty, "an empty name is refused as empty"),
            ("   ", .empty, "a name of only spaces is refused as empty"),
            ("a/b", .character, "a name with / is refused"),
            ("a:b", .character, "a name with : is refused"),
            (".hidden", .dot, "a name with a leading period is refused"),
            (String(repeating: accent, count: 123), .long, "the 246-byte name is refused as long"),
            (String(repeating: accent, count: 122) + "a", nil, "the 245-byte name is accepted"),
            ("Ep. 1", nil, "Ep. 1 is accepted"),
            ("Episodio 1", nil, "Episodio 1 is accepted"),
        ]
        for (text, refusal, rule) in cases {
            do {
                let name = try SessionName(text)
                #expect(refusal == nil, rule)
                #expect(name.text == text, "an accepted name keeps its text")
            } catch {
                #expect(error == refusal, rule)
            }
        }
    }
}
