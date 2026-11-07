import Foundation

/// Fictional records the mock org returns. Sandbox data mirrors production plus a few UAT-only rows.
enum MockData {
    static func rows(sandbox: Bool) -> [String: [[String: Any]]] {
        var accounts: [[String: Any]] = [
            ["Id": "001A00000ACME01", "Name": "Acme Corporation", "Industry": "Manufacturing", "BillingCity": "San Francisco"],
            ["Id": "001A00000GLBX01", "Name": "Globex Industries", "Industry": "Energy", "BillingCity": "Austin"],
            ["Id": "001A00000INTC01", "Name": "Initech Software", "Industry": "Technology", "BillingCity": "Columbus"],
            ["Id": "001A00000UMBR01", "Name": "Umbrella Health", "Industry": "Healthcare", "BillingCity": "Boston"],
            ["Id": "001A00000STRK01", "Name": "Stark Logistics", "Industry": "Transportation", "BillingCity": "Seattle"],
        ]
        var contacts: [[String: Any]] = [
            ["Id": "003A00000MAYA01", "Name": "Maya Patel", "Title": "VP Operations", "Account": ["Name": "Acme Corporation"]],
            ["Id": "003A00000JORD01", "Name": "Jordan Lee", "Title": "CTO", "Account": ["Name": "Globex Industries"]],
            ["Id": "003A00000PRIY01", "Name": "Priya Raman", "Title": "Head of Procurement", "Account": ["Name": "Initech Software"]],
            ["Id": "003A00000ELEN01", "Name": "Elena Ortiz", "Title": "Director of IT", "Account": ["Name": "Umbrella Health"]],
        ]
        var opportunities: [[String: Any]] = [
            ["Id": "006A00000ACME01", "Name": "Acme · Platform Renewal FY27", "Amount": 240000.0, "StageName": "Negotiation"],
            ["Id": "006A00000GLBX01", "Name": "Globex · Service Cloud Expansion", "Amount": 1200000.0, "StageName": "Proposal"],
            ["Id": "006A00000INTC01", "Name": "Initech · Analytics Pilot", "Amount": 48000.0, "StageName": "Qualification"],
            ["Id": "006A00000UMBR01", "Name": "Umbrella · Patient Portal", "Amount": 310000.0, "StageName": "Discovery"],
        ]
        var cases: [[String: Any]] = [
            ["Id": "500A00000CASE01", "CaseNumber": "00001042", "Subject": "SSO login failures", "Priority": "High"],
            ["Id": "500A00000CASE02", "CaseNumber": "00001057", "Subject": "Invoice PDF missing line items", "Priority": "Medium"],
            ["Id": "500A00000CASE03", "CaseNumber": "00001063", "Subject": "Acme data export timing out", "Priority": "Low"],
        ]
        var reports: [[String: Any]] = [
            ["Id": "00OA0000PIPE01", "Name": "Pipeline by Stage", "FolderName": "Sales Reports"],
            ["Id": "00OA0000CASE01", "Name": "Open Cases by Priority", "FolderName": "Service Reports"],
        ]
        if sandbox {
            accounts.append(["Id": "001A00000TEST01", "Name": "Acme Test Account (UAT)", "Industry": "Manufacturing", "BillingCity": "San Francisco"])
            opportunities.append(["Id": "006A00000TEST01", "Name": "Acme · UAT Renewal Scenario", "Amount": 1.0, "StageName": "Closed Won"])
            cases.append(["Id": "500A00000UAT001", "CaseNumber": "00001099", "Subject": "UAT regression: Acme quote PDF", "Priority": "High"])
            reports.append(["Id": "00OA0000UAT001", "Name": "UAT Test Coverage", "FolderName": "QA Reports"])
            contacts.append(["Id": "003A00000QA0001", "Name": "QA Tester", "Title": "Test User", "Account": ["Name": "Acme Corporation"]])
        }
        let leads: [[String: Any]] = [
            ["Id": "00QA00000LEAD01", "Name": "Riley Chen", "Company": "Vandelay Imports", "Status": "Working - Contacted"],
            ["Id": "00QA00000LEAD02", "Name": "Sam Okafor", "Company": "Hooli", "Status": "Open - Not Contacted"],
        ]
        let invoices: [[String: Any]] = [
            ["Id": "a01A0000INV0001", "Name": "INV-1001", "Status__c": "Paid"],
            ["Id": "a01A0000INV0002", "Name": "INV-1002", "Status__c": "Overdue"],
        ]
        let shipments: [[String: Any]] = [
            ["Id": "a02A0000SHP0001", "Name": "SHP-0001", "Carrier__c": "FedEx", "Status__c": "In transit"],
        ]
        return ["Account": accounts, "Contact": contacts, "Opportunity": opportunities, "Case": cases, "Report": reports,
                "Lead": leads, "Invoice__c": invoices, "Shipment__c": shipments]
    }

    static let defaultModified = "2026-11-01T12:00:00.000+0000"

    /// describeGlobal for the mock org: real objects plus the system clutter the Settings picker must hide.
    static var globalObjects: [[String: Any]] {
        func o(_ name: String, _ label: String, _ plural: String, custom: Bool = false, queryable: Bool = true, searchable: Bool = true,
               hidden: Bool = false, setting: Bool = false, layoutable: Bool = true, prefix: String? = "a0X", associate: String? = nil) -> [String: Any] {
            var d: [String: Any] = ["name": name, "label": label, "labelPlural": plural, "custom": custom, "queryable": queryable,
                                    "searchable": searchable, "deprecatedAndHidden": hidden, "customSetting": setting,
                                    "layoutable": layoutable, "createable": true]
            d["keyPrefix"] = prefix ?? NSNull()
            d["associateEntityType"] = associate ?? NSNull()
            return d
        }
        return [
            o("Account", "Account", "Accounts", prefix: "001"), o("Contact", "Contact", "Contacts", prefix: "003"),
            o("Opportunity", "Opportunity", "Opportunities", prefix: "006"), o("Case", "Case", "Cases", prefix: "500"),
            o("Lead", "Lead", "Leads", prefix: "00Q"), o("Campaign", "Campaign", "Campaigns", prefix: "701"),
            o("Report", "Report", "Reports", prefix: "00O"),
            o("Invoice__c", "Invoice", "Invoices", custom: true, prefix: "a01"),
            o("Shipment__c", "Shipment", "Shipments", custom: true, prefix: "a02"),
            // Hidden by the picker:
            o("AccountHistory", "Account History", "Account History", searchable: false, prefix: "017", associate: "History"),
            o("AccountShare", "Account Share", "Account Share", searchable: false, prefix: "00r", associate: "Share"),
            o("AccountFeed", "Account Feed", "Account Feed", prefix: "0D5", associate: "Feed"),
            o("AccountChangeEvent", "Account Change Event", "Account Change Event", searchable: false, prefix: nil, associate: "ChangeEvent"),
            o("AccountTag", "Account Tag", "Account Tags", prefix: "02q"),
            o("Invoice__History", "Invoice History", "Invoice History", custom: true, prefix: "a03"),
            o("Glassforce_Config__mdt", "Glassforce Config", "Glassforce Configs", custom: true, prefix: "m00"),
            o("Order_Placed__e", "Order Placed", "Order Placed", custom: true, prefix: "e00"),
            o("Legacy_Thing__c", "Legacy Thing", "Legacy Things", custom: true, hidden: true, prefix: "a04"),
            o("Routing_Setting__c", "Routing Setting", "Routing Settings", custom: true, setting: true, prefix: "a05"),
            o("ApexLog", "Apex Debug Log", "Apex Debug Logs", searchable: false, prefix: "07L"),
            o("AsyncApexJob", "Apex Job", "Apex Jobs", queryable: true, searchable: false, prefix: "707"),
            o("Vote", "Vote", "Votes", queryable: false, prefix: "00T"),
            o("FieldDefinition", "Field Definition", "Field Definitions", layoutable: false, prefix: "00N"),
        ]
    }

    /// Describe results for the objects above that can be synced.
    static func describe(_ name: String) -> [String: Any]? {
        typealias F = (name: String, type: String, nameField: Bool, autoNumber: Bool)
        func f(_ n: String, _ t: String = "string", name: Bool = false, auto: Bool = false) -> F { (n, t, name, auto) }
        let fields: [String: (String, String, Bool, [F])] = [
            "Account": ("Account", "Accounts", false, [f("Id", "id"), f("Name", name: true), f("Industry", "picklist"), f("BillingCity"), f("LastModifiedDate", "datetime")]),
            "Contact": ("Contact", "Contacts", false, [f("Id", "id"), f("FirstName"), f("LastName"), f("Name", name: true), f("Title"), f("Email", "email"), f("LastModifiedDate", "datetime")]),
            "Opportunity": ("Opportunity", "Opportunities", false, [f("Id", "id"), f("Name", name: true), f("Amount", "currency"), f("StageName", "picklist"), f("LastModifiedDate", "datetime")]),
            "Case": ("Case", "Cases", false, [f("Id", "id"), f("CaseNumber", name: true, auto: true), f("Subject"), f("Priority", "picklist"), f("Status", "picklist"), f("LastModifiedDate", "datetime")]),
            "Lead": ("Lead", "Leads", false, [f("Id", "id"), f("FirstName"), f("LastName"), f("Name", name: true), f("Company"), f("Status", "picklist"), f("Email", "email"), f("LastModifiedDate", "datetime")]),
            "Campaign": ("Campaign", "Campaigns", false, [f("Id", "id"), f("Name", name: true), f("Status", "picklist"), f("Type", "picklist"), f("LastModifiedDate", "datetime")]),
            "Invoice__c": ("Invoice", "Invoices", true, [f("Id", "id"), f("Amount__c", "currency"), f("Name", name: true), f("Status__c", "picklist"), f("LastModifiedDate", "datetime")]),
            // Name is an auto-number and isn't the first text field: the name field must still win.
            "Shipment__c": ("Shipment", "Shipments", true, [f("Id", "id"), f("Carrier__c"), f("Name", name: true, auto: true), f("Status__c", "picklist"), f("LastModifiedDate", "datetime")]),
        ]
        guard let (label, plural, custom, list) = fields[name] else { return nil }
        return ["name": name, "label": label, "labelPlural": plural, "custom": custom, "queryable": true,
                "fields": list.map { ["name": $0.name, "type": $0.type, "nameField": $0.nameField, "autoNumber": $0.autoNumber] }]
    }
}
