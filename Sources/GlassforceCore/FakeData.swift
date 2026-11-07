/// Entirely fictional sample org used until real Salesforce sync exists.
public enum FakeData {
    public static let records: [Record] = [
        Record(id: "001A", kind: .account, title: "Acme Corporation", subtitle: "Manufacturing · San Francisco, CA"),
        Record(id: "001B", kind: .account, title: "Globex Industries", subtitle: "Energy · Austin, TX"),
        Record(id: "001C", kind: .account, title: "Initech Software", subtitle: "Technology · Columbus, OH"),

        Record(id: "003A", kind: .contact, title: "Maya Patel", subtitle: "VP Operations · Acme Corporation"),
        Record(id: "003B", kind: .contact, title: "Jordan Lee", subtitle: "CTO · Globex Industries"),
        Record(id: "003C", kind: .contact, title: "Priya Raman", subtitle: "Head of Procurement · Initech Software"),

        Record(id: "006A", kind: .opportunity, title: "Acme · Platform Renewal FY27", subtitle: "$240,000 · Negotiation · Closes Dec 12"),
        Record(id: "006B", kind: .opportunity, title: "Globex · Service Cloud Expansion", subtitle: "$1.2M · Proposal · Closes Jan 30"),
        Record(id: "006C", kind: .opportunity, title: "Initech · Analytics Pilot", subtitle: "$48,000 · Qualification · Closes Feb 14"),

        Record(id: "500A", kind: .supportCase, title: "00001042 · SSO login failures", subtitle: "High priority · Acme Corporation"),
        Record(id: "500B", kind: .supportCase, title: "00001057 · Invoice PDF missing line items", subtitle: "Medium priority · Globex Industries"),

        Record(id: "00QA", kind: .other, title: "Riley Chen", subtitle: "Vandelay Imports · Working",
               objectName: "Lead", objectLabel: "Lead", objectPlural: "Leads"),

        Record(id: "00OA", kind: .report, title: "Pipeline by Stage", subtitle: "This quarter · Sales Reports"),
        Record(id: "00OB", kind: .report, title: "Open Cases by Priority", subtitle: "Service Reports"),

        Record(id: "SETUP-USERS", kind: .setup, title: "Users", subtitle: "Setup › Administration › Users"),
        Record(id: "SETUP-PERMSETS", kind: .setup, title: "Permission Sets", subtitle: "Setup › Users › Permission Sets"),
        Record(id: "SETUP-FLOWS", kind: .setup, title: "Flows", subtitle: "Setup › Process Automation › Flows"),
    ]
}
