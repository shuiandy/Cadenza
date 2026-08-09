import Foundation

enum ContentViewMode: String, CaseIterable {
    case waterfall
    case grid
    case list

    var icon: String {
        switch self {
        case .waterfall: "square.3.layers.3d"
        case .grid: "square.grid.2x2"
        case .list: "list.bullet"
        }
    }

    var label: String {
        switch self {
        case .waterfall: String(localized: "Waterfall")
        case .grid: String(localized: "Grid")
        case .list: String(localized: "List")
        }
    }
}
