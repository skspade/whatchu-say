import Testing
@testable import Meeting

@Suite("AttendeeList")
struct AttendeeListTests {
    @Test("parses comma-separated input, trims whitespace")
    func parseCSV() {
        let list = AttendeeList(parsing: "  Alice, Bob , Carol  ")
        #expect(list.names == ["Alice", "Bob", "Carol"])
    }

    @Test("ignores empty entries")
    func parseEmpties() {
        let list = AttendeeList(parsing: "Alice,,Bob,")
        #expect(list.names == ["Alice", "Bob"])
    }

    @Test("isEmpty when no names")
    func empty() {
        #expect(AttendeeList(parsing: "").isEmpty)
        #expect(AttendeeList(parsing: " ,, ").isEmpty)
    }

    @Test("dedupes case-insensitively, keeps first casing")
    func dedupe() {
        let list = AttendeeList(parsing: "Alice, alice, ALICE, Bob")
        #expect(list.names == ["Alice", "Bob"])
    }
}
