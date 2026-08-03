import Foundation

// MARK: - Owned Settings Store

/// The single owner of persisted app settings (#177). Holds one in-memory
/// `iQualizeState` and persists it after every mutation.
///
/// Every write goes through a per-field setter or a synchronous `update`
/// transaction on the same live instance, so a write that happens while a
/// modal spins a nested run loop (or while a caller is suspended at an await)
/// mutates the state the enclosing code will persist from — nothing is
/// snapshotted and written back stale. This replaces the old whole-struct
/// read-modify-write pattern, whose write clobbered any write made in between.
///
/// The persisted format is unchanged: same UserDefaults key, same JSON encoder,
/// same decoder with its per-field fallbacks.
@MainActor
final class SettingsStore {
    private(set) var state: iQualizeState
    private let defaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        defaults = userDefaults
        state = iQualizeState.readPersisted(from: userDefaults)
    }

    /// Mutates one field of the live instance and persists.
    func set<T>(_ keyPath: WritableKeyPath<iQualizeState, T>, _ value: T) {
        state[keyPath: keyPath] = value
        persist()
    }

    /// Multi-field transaction for genuinely coupled writes (e.g. the
    /// global/per-preset gain switch, the footer-toggle batch). The closure is
    /// synchronous and non-escaping, so a transaction cannot straddle an await
    /// or a modal by construction.
    func update(_ mutate: (inout iQualizeState) -> Void) {
        mutate(&state)
        persist()
    }

    private func persist() {
        state.writePersisted(to: defaults)
    }
}
