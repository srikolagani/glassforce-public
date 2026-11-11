import Foundation
import GlassforceCore

/// Production preference domain: the installed app's standard defaults.
struct UserDefaultsPreferenceStore: PreferenceStore {
    let domain: String
    let defaults: UserDefaults

    static func production() -> UserDefaultsPreferenceStore {
        UserDefaultsPreferenceStore(domain: ProcessIdentity.productionDomain, defaults: .standard)
    }

    func string(forKey key: String) -> String? { defaults.string(forKey: key) }

    func set(_ value: String?, forKey key: String) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    func integer(forKey key: String) -> Int { defaults.integer(forKey: key) }

    func dictionary(forKey key: String) -> [String: Int]? {
        defaults.dictionary(forKey: key) as? [String: Int]
    }

    func set(_ value: [String: Int]?, forKey key: String) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
}
