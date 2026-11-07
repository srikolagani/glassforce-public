import Foundation
import Testing
@testable import GlassforceCore

@Suite("Sample data seeder (dev only)")
struct SampleDataSeederTests {
    @Test func sampleSetIsSmallMarkedAndFictional() throws {
        let accounts = SampleDataSeeder.sampleAccounts()
        #expect(accounts.count == 25)
        var total = accounts.count
        for a in accounts {
            #expect(a["Description"] as? String == SampleDataSeeder.marker)
            for rel in ["Contacts", "Opportunities", "Cases"] {
                let recs = try #require((a[rel] as? [String: Any])?["records"] as? [[String: Any]])
                total += recs.count
                for r in recs { #expect(r["Description"] as? String == SampleDataSeeder.marker) }
                if rel == "Contacts" { for r in recs { #expect((r["Email"] as? String)?.hasSuffix(".example.com") == true) } }
            }
        }
        #expect(total < 250)
        // Each tree request is <= 200 records (5 accounts per batch).
        #expect(JSONSerialization.isValidJSONObject(["records": accounts]))
    }

    @Test func parsesSeedFlagWithHost() {
        let o = LaunchOptions(arguments: ["app", "--seed-sample-data", "x.my.salesforce.com"])
        #expect(o.seedSampleDataHost == "x.my.salesforce.com")
    }
}
