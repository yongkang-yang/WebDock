/// Safety decisions for pages created by pointer hover, before the user selects a site.
/// Kept separate from WebKit so the rules can be tested without a camera.
public enum SpeculativePagePolicy {
    /// A camera/microphone request can only proceed for a page the user actually opened.
    public static func allowsMediaRequest(isSpeculative: Bool,
                                          isSelectedAndVisible: Bool,
                                          isDetachedWindow: Bool) -> Bool {
        !isSpeculative && (isSelectedAndVisible || isDetachedWindow)
    }

    /// Speculative pages must not create windows, prompt for files or passwords,
    /// start downloads, or hand links to other applications.
    public static func allowsInteractiveSideEffects(isSpeculative: Bool) -> Bool {
        !isSpeculative
    }
}
