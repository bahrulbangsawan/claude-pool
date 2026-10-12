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
