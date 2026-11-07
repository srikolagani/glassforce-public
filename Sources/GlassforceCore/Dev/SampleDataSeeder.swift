import Foundation

/// DEV ONLY. `--seed-sample-data <instance-host>`: creates obviously fictional Accounts with nested
/// Contacts, Opportunities and Cases via the sObject Tree API. Create-only, never updates or deletes.
/// Refuses unless the saved sign-in's instance host equals the host passed on the command line, and
/// skips if seed-marked Accounts already exist. Every record carries `marker` so it can be found and removed.
public struct SampleDataSeeder: Sendable {
    public static let marker = "glassforce sample data"
    public let client: SalesforceClient
    public init(client: SalesforceClient) { self.client = client }

    public enum SeedError: LocalizedError, Equatable {
        case hostMismatch(expected: String, actual: String)
        case noSignIn
        case failed(Int, String)
        public var errorDescription: String? {
            switch self {
            case .hostMismatch(let e, let a): "refusing: instance host \(a) is not the allowed host \(e)"
            case .noSignIn: "refusing: no saved sign-in"
            case .failed(let s, let m): "tree insert failed (HTTP \(s)): \(m)"
            }
        }
    }

    /// Returns per-object created counts, or nil if seed data already existed (skipped).
    public func run(org: String, allowedHost: String) async throws -> [String: Int]? {
        guard let creds = try await client.tokens.credentials(for: org) else { throw SeedError.noSignIn }
        let host = creds.instanceURL.host?.lowercased() ?? ""
        guard !allowedHost.isEmpty, host == allowedHost.lowercased() else {
            throw SeedError.hostMismatch(expected: allowedHost, actual: host)
        }
        let existing = try await client.query(org: org, instanceURL: creds.instanceURL,
            soql: "SELECT Description FROM Account WHERE Website LIKE '%.example.com' LIMIT 200")
        // Description is a long text area (not filterable in SOQL), so match the marker client-side.
        if existing.contains(where: { ($0["Description"] as? String) == Self.marker }) { return nil }

        var totals = ["Account": 0, "Contact": 0, "Opportunity": 0, "Case": 0]
        let accounts = Self.sampleAccounts()
        for start in stride(from: 0, to: accounts.count, by: 5) {
            let batch = Array(accounts[start..<min(start + 5, accounts.count)])
            let body = try JSONSerialization.data(withJSONObject: ["records": batch])
            let url = creds.instanceURL.appendingPathComponent("services/data/\(SalesforceClient.apiVersion)/composite/tree/Account")
            let response = try await client.tokens.authorizedSend(org, HTTPRequest(method: "POST", url: url,
                headers: ["Content-Type": "application/json", "Accept": "application/json"], body: body))
            let text = String(data: response.body, encoding: .utf8) ?? ""
            guard response.status == 201,
                  let json = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
                  json["hasErrors"] as? Bool == false,
                  let results = json["results"] as? [[String: Any]] else {
                throw SeedError.failed(response.status, String(text.prefix(400)))
            }
            for r in results {
                if let id = r["id"] as? String {
                    switch id.prefix(3) {
                    case "001": totals["Account", default: 0] += 1
                    case "003": totals["Contact", default: 0] += 1
                    case "006": totals["Opportunity", default: 0] += 1
                    case "500": totals["Case", default: 0] += 1
                    default: break
                    }
                }
            }
        }
        return totals
    }

    static let companies: [(String, String, String, String)] = [
        ("Acme Corporation", "Manufacturing", "Phoenix", "AZ"), ("Globex Corporation", "Energy", "Springfield", "OR"),
        ("Initech", "Technology", "Austin", "TX"), ("Umbrella Corporation", "Biotechnology", "Raleigh", "NC"),
        ("Stark Industries", "Engineering", "Los Angeles", "CA"), ("Wayne Enterprises", "Construction", "Newark", "NJ"),
        ("Hooli", "Technology", "Palo Alto", "CA"), ("Pied Piper", "Technology", "San Jose", "CA"),
        ("Soylent Industries", "Food & Beverage", "Minneapolis", "MN"), ("Wonka Industries", "Food & Beverage", "Hershey", "PA"),
        ("Cyberdyne Systems", "Electronics", "Sunnyvale", "CA"), ("Tyrell Corporation", "Biotechnology", "Seattle", "WA"),
        ("Massive Dynamic", "Technology", "Boston", "MA"), ("Vandelay Industries", "Retail", "New York", "NY"),
        ("Dunder Mifflin", "Retail", "Scranton", "PA"), ("Oscorp", "Healthcare", "Jersey City", "NJ"),
        ("Wernham Hogg", "Retail", "Chicago", "IL"), ("Bluth Company", "Construction", "Newport Beach", "CA"),
        ("Prestige Worldwide", "Media", "Nashville", "TN"), ("Monarch Solutions", "Consulting", "Denver", "CO"),
        ("Gringotts Financial", "Banking", "Charlotte", "NC"), ("Oceanic Airlines", "Transportation", "Honolulu", "HI"),
        ("Sterling Cooper", "Media", "New York", "NY"), ("Nakatomi Trading", "Finance", "Los Angeles", "CA"),
        ("Los Pollos Hermanos", "Hospitality", "Albuquerque", "NM"),
    ]
    static let first = ["Ava", "Liam", "Maya", "Noah", "Priya", "Diego", "Hana", "Omar", "Zoe", "Ethan", "Lena", "Raj", "Chloe", "Marcus", "Ines", "Kofi"]
    static let last = ["Patel", "Nguyen", "Garcia", "Okafor", "Schmidt", "Kim", "Rossi", "Cohen", "Silva", "Tanaka", "Murphy", "Haddad", "Larsen", "Diaz"]
    static let titles = ["VP of Sales", "CIO", "Director of Operations", "Procurement Manager", "CFO", "Head of IT", "Sales Ops Lead"]
    static let stages = ["Prospecting", "Qualification", "Needs Analysis", "Value Proposition", "Id. Decision Makers",
                         "Perception Analysis", "Proposal/Price Quote", "Negotiation/Review", "Closed Won", "Closed Lost"]
    static let oppKinds = ["Platform Renewal", "Expansion", "New Business", "Services Add-on", "Pilot"]
    static let caseSubjects = ["Login issues after SSO change", "Invoice discrepancy", "Data export failing", "Integration timeout errors", "Feature request: bulk edit", "Onboarding training request"]
    static let caseStatus = ["New", "Working", "Escalated", "Closed"]
    static let priorities = ["High", "Medium", "Low"]
    static let origins = ["Phone", "Email", "Web"]

    /// Deterministic, obviously fictional records (no randomness, so reruns look the same).
    /// Split into helpers so the Linux type checker can finish; the dictionaries are the same.
    static func sampleAccounts() -> [[String: Any]] {
        companies.enumerated().map { i, company in
            sampleAccount(index: i, company: company)
        }
    }

    private static func sampleAccount(index i: Int, company c: (String, String, String, String)) -> [String: Any] {
        let slug = c.0.lowercased().filter { $0.isLetter }
        let contacts = (0..<(2 + i % 2)).map { sampleContact(account: i, index: $0, slug: slug) }
        let opps = (0..<(1 + i % 3)).map { sampleOpportunity(account: i, index: $0, company: c.0) }
        let cases = (0..<(1 + i % 2)).map { sampleCase(account: i, index: $0) }
        let attributes: [String: Any] = ["type": "Account", "referenceId": "a\(i)"]
        let phone = String(format: "(555) 02%02d-0000", i)
        return [
            "attributes": attributes,
            "Name": c.0,
            "Industry": c.1,
            "BillingCity": c.2,
            "BillingCountryCode": "US",
            "BillingStateCode": c.3,
            "Phone": phone,
            "Website": "https://www.\(slug).example.com",
            "Description": marker,
            "Contacts": ["records": contacts],
            "Opportunities": ["records": opps],
            "Cases": ["records": cases],
        ]
    }

    private static func sampleContact(account i: Int, index j: Int, slug: String) -> [String: Any] {
        let f = first[(i * 3 + j) % first.count]
        let l = last[(i * 5 + j) % last.count]
        let attributes: [String: Any] = ["type": "Contact", "referenceId": "c\(i)_\(j)"]
        return [
            "attributes": attributes,
            "FirstName": f,
            "LastName": l,
            "Title": titles[(i + j) % titles.count],
            "Email": "\(f.lowercased()).\(l.lowercased())@\(slug).example.com",
            "Phone": String(format: "(555) 01%02d-%04d", i, 1000 + j),
            "Description": marker,
        ]
    }

    private static func sampleOpportunity(account i: Int, index j: Int, company: String) -> [String: Any] {
        let months = [(2026, 11), (2026, 12), (2027, 1), (2027, 2), (2027, 3)]
        let month = months[(i + j) % 5]
        let attributes: [String: Any] = ["type": "Opportunity", "referenceId": "o\(i)_\(j)"]
        return [
            "attributes": attributes,
            "Name": "\(company) - \(oppKinds[(i + j) % oppKinds.count])",
            "StageName": stages[(i * 2 + j) % stages.count],
            "Amount": 15000 + ((i * 37 + j * 53) % 40) * 5000,
            "CloseDate": String(format: "%04d-%02d-%02d", month.0, month.1, 5 + (i + j * 7) % 22),
            "Description": marker,
        ]
    }

    private static func sampleCase(account i: Int, index j: Int) -> [String: Any] {
        let attributes: [String: Any] = ["type": "Case", "referenceId": "k\(i)_\(j)"]
        return [
            "attributes": attributes,
            "Subject": caseSubjects[(i + j) % caseSubjects.count],
            "Status": caseStatus[(i + j) % caseStatus.count],
            "Priority": priorities[(i + j) % 3],
            "Origin": origins[(i * 2 + j) % 3],
            "Description": marker,
        ]
    }
}
