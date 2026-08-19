import Foundation

/// Whether a subsystem is actually doing its job, as distinct from merely running.
///
/// Both places this is used learned the same lesson the hard way: tracking showed
/// a green "Tracking…" dot for months while dropping ~90% of segments, and
/// blocking kept a domain in /etc/hosts long after the app believed it had been
/// removed. "The timer is alive" and "it works" are different claims, and only
/// the second one is worth showing a user.
enum HealthState: Equatable {
    case ok
    /// Working, but some signal is missing or unverifiable.
    case degraded(String)
    /// Not doing its job.
    case broken(String)

    var isOK: Bool { self == .ok }

    /// nil when healthy — callers render a warning row only when this is non-nil.
    var detail: String? {
        switch self {
        case .ok: return nil
        case .degraded(let message), .broken(let message): return message
        }
    }
}

/// Tracking refers to this as capture health; the name is kept where it reads better.
typealias CaptureHealth = HealthState
