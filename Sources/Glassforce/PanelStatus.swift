import Foundation

enum PanelStatus: Equatable {
    case ready
    case noOrg
    case syncing(String)
    case failed(String)
}
