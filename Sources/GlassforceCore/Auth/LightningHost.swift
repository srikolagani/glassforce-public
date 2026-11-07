import Foundation

/// Maps an org's My Domain instance URL to its Lightning Experience host (Salesforce Help:
/// "My Domain URL Formats" / "Partitioned Domains"):
///   acme.my.salesforce.com                      → acme.lightning.force.com            (production)
///   acme--uat.sandbox.my.salesforce.com         → acme--uat.sandbox.lightning.force.com (sandbox)
///   acme-dev-ed.develop.my.salesforce.com       → acme-dev-ed.develop.lightning.force.com (Developer Edition)
///   x.scratch / .demo / .patch / .free / .trailblaze  keep their partition word the same way
///   acme--uat.cs42.my.salesforce.com (legacy, no enhanced domains) → acme--uat.lightning.force.com
/// Anything else (gov cloud, custom domains, localhost mock) keeps the instance host, which redirects.
public enum LightningHost {
    static let partitions: Set<String> = ["sandbox", "develop", "scratch", "demo", "patch", "free", "trailblaze"]

    public static func base(for instanceURL: URL) -> URL {
        guard let host = instanceURL.host?.lowercased(), host.hasSuffix(".my.salesforce.com") else { return instanceURL }
        var labels = host.dropLast(".my.salesforce.com".count).split(separator: ".").map(String.init)
        guard let name = labels.first, !name.isEmpty else { return instanceURL }
        labels.removeFirst()
        let kept = labels.filter { partitions.contains($0) }
        var c = URLComponents(); c.scheme = "https"
        c.host = ([name] + kept + ["lightning", "force", "com"]).joined(separator: ".")
        return c.url ?? instanceURL
    }
}

extension LightningHost {
    /// Caches written before the Lightning-host fix hold My Domain links; move them to the Lightning host.
    public static func migrate(_ records: [Record]) -> [Record] {
        records.map { r in
            guard let url = r.url, url.path.hasPrefix("/lightning/"),
                  var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return r }
            c.host = base(for: url).host
            return r.with(url: c.url ?? url)
        }
    }
}
