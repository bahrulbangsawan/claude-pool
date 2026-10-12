import Foundation
import Testing
@testable import ClaudePool

struct SubscriptionPlanTests {
    private func details(tier: String? = nil, userTier: String? = nil, type: String? = nil, email: String? = "me@example.com",
                         seat: String? = nil, planName: String? = nil) -> AccountDetails {
        AccountDetails(emailAddress: email, organizationType: type, organizationRateLimitTier: tier, userRateLimitTier: userTier,
                       seatTier: seat, planDisplayName: planName, readAt: Date())
    }

    @Test func maxTwentyAndFiveAreDistinguished() {
        let twenty = SubscriptionPlan.resolve(subscriptionType: "max", details: details(tier: "default_claude_max_20x"), signedInEmail: "me@example.com")
        let five = SubscriptionPlan.resolve(subscriptionType: "max", details: details(tier: "default_claude_max_5x"), signedInEmail: "me@example.com")
        #expect(twenty?.displayName == "Max 20x")
        #expect(twenty?.multiplier == 20)
        #expect(five?.displayName == "Max 5x")
        #expect(five?.source == .rateLimitTier)
    }

    @Test func genericMaxIsNeverGivenAGuessedTier() {
        let noDetails = SubscriptionPlan.resolve(subscriptionType: "max", details: nil, signedInEmail: "me@example.com")
        #expect(noDetails?.displayName == "Max · Unknown Tier")
        #expect(noDetails?.isTierKnown == false)
        let unrelatedTier = SubscriptionPlan.resolve(subscriptionType: "max", details: details(tier: "default_raven"), signedInEmail: nil)
        #expect(unrelatedTier?.multiplier == nil)
        #expect(unrelatedTier?.isTierKnown == false)
    }

    @Test func detailsForAnotherAccountAreIgnored() {
        let plan = SubscriptionPlan.resolve(subscriptionType: "max", details: details(tier: "default_claude_max_20x", email: "old@example.com"), signedInEmail: "me@example.com")
        #expect(plan?.displayName == "Max · Unknown Tier")
    }

    @Test func userTierWinsOverOrganisationTier() {
        let plan = SubscriptionPlan.resolve(subscriptionType: "max", details: details(tier: "default_claude_max_5x", userTier: "default_claude_max_20x"), signedInEmail: nil)
        #expect(plan?.displayName == "Max 20x")
    }

    @Test func tierFromAnotherFamilyDoesNotLeak() {
        // A Pro sign-in never shows a Max multiplier, even if a stale tier is cached.
        let plan = SubscriptionPlan.resolve(subscriptionType: "pro", details: details(tier: "default_claude_max_20x"), signedInEmail: nil)
        #expect(plan?.displayName == "Pro")
    }

    @Test func teamSeatAndPlanNameAndFallbacks() {
        #expect(SubscriptionPlan.resolve(subscriptionType: "team", details: details(seat: "premium"), signedInEmail: nil)?.displayName == "Team · Premium seat")
        #expect(SubscriptionPlan.resolve(subscriptionType: "team", details: nil, signedInEmail: nil)?.displayName == "Team")
        #expect(SubscriptionPlan.resolve(subscriptionType: "max", details: details(planName: "Max 20x"), signedInEmail: nil)?.source == .planName)
        #expect(SubscriptionPlan.resolve(subscriptionType: nil, details: details(type: "claude_max"), signedInEmail: nil)?.family == .max)
        #expect(SubscriptionPlan.resolve(subscriptionType: nil, details: nil, signedInEmail: nil) == nil)
        // Labels with unexpected characters are not trusted as plan names.
        #expect(SubscriptionPlan.resolve(subscriptionType: "pro", details: details(planName: "<script>"), signedInEmail: nil)?.displayName == "Pro")
    }

    @Test func readerDecodesOnlyOAuthAccountFields() throws {
        let json = #"""
        {"primaryApiKey":"sk-ant-SHOULD-NEVER-APPEAR","projects":{"/x":{"history":["secret prompt"]}},
         "oauthAccount":{"emailAddress":"me@example.com","organizationType":"claude_max",
           "organizationRateLimitTier":"default_claude_max_20x","userRateLimitTier":null,"seatTier":null,
           "accessToken":"SHOULD-NEVER-APPEAR","profileFetchedAt":1791780156231}}
        """#
        let parsed = try #require(AccountDetailsReader.parse(Data(json.utf8)))
        #expect(parsed.organizationRateLimitTier == "default_claude_max_20x")
        #expect(parsed.profileFetchedAt != nil)
        #expect(!String(describing: parsed).contains("SHOULD-NEVER-APPEAR"))
        #expect(!String(describing: parsed).contains("secret prompt"))
        #expect(AccountDetailsReader.parse(Data("[]".utf8)) == nil)
        #expect(AccountDetailsReader.parse(Data(#"{"projects":{}}"#.utf8)) == nil)
    }

    @Test func configFileLocationMatchesClaudeCode() {
        let home = URL(fileURLWithPath: "/Users/x")
        let def = Profile.makeDefault(home: home)
        #expect(AccountDetailsReader.configFile(for: def, home: home).path == "/Users/x/.claude.json")
        var other = def
        other.isDefault = false
        other.configDir = "/Users/x/.claude-work"
        #expect(AccountDetailsReader.configFile(for: other, home: home).path == "/Users/x/.claude-work/.claude.json")
    }
}
