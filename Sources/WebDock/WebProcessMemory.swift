import AppKit
import Darwin
import WebKit

/// Best-effort memory for the main WebKit content process of a live page.
/// WebKit can share one process between pages, and subframes/GPU use other processes.
/// The process identifier is WebKit private API; unavailable results are shown as unknown.
enum WebProcessMemory {
    static func processID(for webView: WKWebView) -> pid_t? {
        let selector = NSSelectorFromString("_webProcessIdentifier")
        guard webView.responds(to: selector),
              let implementation = webView.method(for: selector) else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> pid_t
        let getter = unsafeBitCast(implementation, to: Getter.self)
        let pid = getter(webView, selector)
        return pid > 0 ? pid : nil
    }

    static func residentBytes(for pid: pid_t) -> UInt64? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(pid, PROC_PIDTASKINFO, 0, pointer, size)
        }
        guard result == size else { return nil }
        return info.pti_resident_size
    }
}
