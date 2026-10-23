import Testing
@testable import ClaudePool

@Suite struct SlugTests {
    @Test(arguments: [
        ("Work", "work"),
        ("My Personal Account", "my-personal-account"),
        ("  Café Crème  ", "cafe-creme"),
        ("a--b__c", "a-b-c"),
        ("--edge--", "edge"),
        ("Team #2 (EU)", "team-2-eu"),
        ("日本語", ""),
        ("UPPER123", "upper123"),
    ])
    func makesSlug(_ input: String, _ expected: String) {
        #expect(Slug.make(from: input) == expected)
    }

    @Test func typingKeepsOneTrailingHyphen() {
        #expect(Slug.typing("My ") == "my-")
        #expect(Slug.typing("My  Work") == "my-work")
        #expect(Slug.typing("akun#") == "akun-")
        #expect(Slug.typing(" -Akun") == "akun")
        #expect(Slug.typing("AKUN4") == "akun4")
        #expect(Slug.typing("Café ") == "cafe-")
        #expect(Slug.typing(String(repeating: "a", count: 40)).count == Slug.maxLength)
    }

    @Test func kebabIsNotTruncated() {
        #expect(Slug.kebab(String(repeating: "a", count: 40)).count == 40)
        #expect(Slug.kebab("Client — Northwind") == "client-northwind")
    }

    @Test func truncatesToMaxLength() {
        let slug = Slug.make(from: String(repeating: "abc ", count: 20))
        #expect(slug.count <= Slug.maxLength)
        #expect(!slug.hasSuffix("-"))
        #expect(Slug.isValid(slug))
    }

    @Test func validation() {
        #expect(Slug.isValid("work"))
        #expect(Slug.isValid("work-2"))
        #expect(!Slug.isValid(""))
        #expect(!Slug.isValid("Work"))
        #expect(!Slug.isValid("-work"))
        #expect(!Slug.isValid("work-"))
        #expect(!Slug.isValid("wo rk"))
        #expect(!Slug.isValid("wörk"))
        #expect(!Slug.isValid(String(repeating: "a", count: 33)))
    }
}
