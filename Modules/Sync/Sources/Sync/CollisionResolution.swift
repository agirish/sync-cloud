/// Options for resolving file naming collisions during transfers.
public enum CollisionResolution: Sendable {
    case replace
    case keepBoth
    case skip
}
