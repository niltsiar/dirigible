import Testing

/// `dirigible devices` (criterion 5). It reads the real device list of this Mac, read only, so
/// it checks invariants only.
struct DeviceCommandTests {
    @Test func eachLineHasFourFieldsAndAUniqueUID() async throws {
        let result = try await dirigible("devices")

        #expect(result.status == 0)
        #expect(result.stderr == "")
        let lines = result.stdout.split(separator: "\n", omittingEmptySubsequences: false).dropLast()
        #expect(result.stdout.isEmpty || result.stdout.hasSuffix("\n"))
        var uids: Set<Substring> = []
        for line in lines {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            try #require(fields.count == 4, "line \(line)")
            #expect(!fields[0].isEmpty)
            #expect((Int(fields[2]) ?? 0) > 0, "channels in \(line)")
            #expect((Double(fields[3]) ?? 0) > 0, "rate in \(line)")
            #expect(uids.insert(fields[0]).inserted, "UID \(fields[0]) repeats")
            #expect(!fields[0].hasPrefix("com.delineas.dirigible.tap."), "a tap aggregate in \(line)")
        }
    }

    /// A3: `dirigible apps` reads the real process list of this Mac, read only: one line for each
    /// app, three fields, no repeated bundle ID, and no agent such as Control Center.
    @Test func eachAppsLineHasThreeFieldsAndAUniqueBundleID() async throws {
        let result = try await dirigible("apps")

        #expect(result.status == 0)
        #expect(result.stderr == "")
        #expect(result.stdout.isEmpty || result.stdout.hasSuffix("\n"))
        var ids: Set<Substring> = []
        for line in result.stdout.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            try #require(fields.count == 3, "line \(line)")
            #expect(!fields[0].isEmpty && !fields[1].isEmpty, "line \(line)")
            #expect(["0", "1"].contains(fields[2]), "playing in \(line)")
            #expect(ids.insert(fields[0]).inserted, "bundle ID \(fields[0]) repeats")
        }
        #expect(!ids.contains("com.apple.controlcenter"), "Control Center is an agent")
    }
}
