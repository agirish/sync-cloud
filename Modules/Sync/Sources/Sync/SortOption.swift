import Foundation

public enum SortOption: String, CaseIterable, Equatable {
    case name = "Name"
    case kind = "Kind"
    case dateModified = "Date Modified"
    case size = "Size"
    case tags = "Tags"
}
