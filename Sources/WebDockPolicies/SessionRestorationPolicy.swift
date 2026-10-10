/// State transitions for recovering a released WebKit page.
///
/// A hover can prepare an empty WKWebView, but it may not consume a saved
/// session. Only an explicit activation begins interaction-state restoration.
public enum SessionRestorationPhase: Equatable {
    case awaitingCommit
    case committed
}

public enum SessionRestorationPolicy {
    /// A saved session takes priority over navigation, except on a hover-only preload.
    public static func shouldRestore(hasSavedState: Bool, speculative: Bool,
                                     explicitURL: Bool) -> Bool {
        hasSavedState && !speculative && !explicitURL
    }

    /// An unselected speculative web view must stay empty rather than restoring
    /// the saved state or loading a different URL over it.
    public static func shouldDeferLoad(hasSavedState: Bool, speculative: Bool,
                                       explicitURL: Bool) -> Bool {
        hasSavedState && speculative && !explicitURL
    }

    /// A speculative page never replaces or erases the existing session.
    public static func shouldKeepCachedStateWhenClosing(speculative: Bool) -> Bool {
        speculative
    }

    /// Timeouts only protect against restores that never start navigation.
    /// A committed navigation may still be loading subresources for a long time.
    public static func shouldFallbackAfterTimeout(phase: SessionRestorationPhase?) -> Bool {
        phase == .awaitingCommit
    }
}
