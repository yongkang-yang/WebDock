import AppKit
import WebKit

/// Video fullscreen and picture in picture.
///
/// WebKit's own element fullscreen moves the page into a separate macOS fullscreen Space, which
/// suits a browser but not a menu bar panel. Instead, this script implements the Fullscreen API
/// in the page: the element is pinned over the viewport, and the app moves the web view into a
/// window that covers the screen below the menu bar. Players inside iframes (most video sites)
/// work too: each frame makes its iframe fill its own viewport, up to the top frame, which tells
/// the app.
enum VideoPresentation {
    static let messageName = "webdockVideo"

    static let script = WKUserScript(source: """
        (() => {
          if (window.__webdockFullscreen) return;
          const isTop = window === window.top;
          const post = message => window.webkit?.messageHandlers?.\(messageName)?.postMessage(message);
          const mark = 'data-webdock-fullscreen';
          const ancestorMark = 'data-webdock-fullscreen-ancestor';
          let current = null;

          const css = `
            [${mark}] { position: fixed !important; inset: 0 !important; width: 100vw !important;
              height: 100vh !important; max-width: none !important; max-height: none !important;
              min-width: 0 !important; min-height: 0 !important; margin: 0 !important; border: 0 !important;
              padding: 0 !important; transform: none !important; z-index: 2147483647 !important;
              background: #000 !important; box-sizing: border-box !important; }
            video[${mark}] { object-fit: contain !important; }
            [${ancestorMark}] { transform: none !important; filter: none !important; perspective: none !important;
              contain: none !important; will-change: auto !important; backdrop-filter: none !important;
              z-index: 2147483647 !important; }
            html[${ancestorMark}], html[${ancestorMark}] > body { overflow: hidden !important; }`;
          const ensureStyle = () => {
            if (document.getElementById('webdock-fullscreen-style')) return;
            const style = document.createElement('style');
            style.id = 'webdock-fullscreen-style';
            style.textContent = css;
            (document.head || document.documentElement).appendChild(style);
          };
          const announce = (el, types) => {
            const target = el && el.isConnected ? el : document;
            for (const type of types) target.dispatchEvent(new Event(type, { bubbles: true, composed: true }));
          };
          const changeEvents = ['fullscreenchange', 'webkitfullscreenchange'];

          const enter = el => {
            if (current === el) return Promise.resolve();
            if (current) leave(false, false);
            current = el;
            ensureStyle();
            el.setAttribute(mark, '');
            for (let node = el.parentElement; node; node = node.parentElement) node.setAttribute(ancestorMark, '');
            if (isTop) post({ fullscreen: true }); else parent.postMessage({ webdockFullscreen: true }, '*');
            announce(el, changeEvents);
            if (el instanceof HTMLVideoElement) announce(el, ['webkitbeginfullscreen']);
            return Promise.resolve();
          };

          // `tellChild`: this frame's fullscreen element is an iframe whose page should leave too.
          // `tellParent`: pass it up, so the frame holding this one lets go of it.
          const leave = (tellChild, tellParent) => {
            const el = current;
            if (!el) return Promise.resolve();
            current = null;
            el.removeAttribute(mark);
            for (const node of document.querySelectorAll(`[${ancestorMark}]`)) node.removeAttribute(ancestorMark);
            if (tellChild && el.contentWindow) el.contentWindow.postMessage({ webdockExitFullscreen: true }, '*');
            if (tellParent) {
              if (isTop) post({ fullscreen: false }); else parent.postMessage({ webdockFullscreen: false }, '*');
            }
            announce(el, changeEvents);
            if (el instanceof HTMLVideoElement) announce(el, ['webkitendfullscreen']);
            return Promise.resolve();
          };
          const exit = () => leave(true, true);
          window.__webdockFullscreen = exit;

          for (const name of ['requestFullscreen', 'webkitRequestFullscreen', 'webkitRequestFullScreen']) {
            Element.prototype[name] = function () { return enter(this); };
          }
          for (const name of ['exitFullscreen', 'webkitExitFullscreen', 'webkitCancelFullScreen']) {
            Document.prototype[name] = function () { return exit(); };
          }
          const video = HTMLVideoElement.prototype;
          video.webkitEnterFullscreen = video.webkitEnterFullScreen = function () { enter(this); };
          video.webkitExitFullscreen = video.webkitExitFullScreen = function () { if (current === this) exit(); };
          const getter = (proto, names, get) => {
            for (const name of names) Object.defineProperty(proto, name, { get, configurable: true });
          };
          getter(Document.prototype, ['fullscreenElement', 'webkitFullscreenElement', 'webkitCurrentFullScreenElement'], () => current);
          getter(Document.prototype, ['fullscreen', 'webkitIsFullScreen'], () => !!current);
          getter(Document.prototype, ['fullscreenEnabled', 'webkitFullscreenEnabled'], () => true);
          getter(video, ['webkitSupportsFullscreen'], () => true);
          getter(video, ['webkitDisplayingFullscreen'], function () { return current === this; });

          addEventListener('message', event => {
            const data = event.data;
            if (!data || typeof data !== 'object') return;
            if (typeof data.webdockFullscreen === 'boolean') {
              const frame = [...document.querySelectorAll('iframe, frame')].find(f => f.contentWindow === event.source);
              if (!frame) return;
              if (data.webdockFullscreen) enter(frame); else if (current === frame) leave(false, true);
            } else if (data.webdockExitFullscreen && event.source === parent) {
              leave(true, false);
            }
          });
          addEventListener('keydown', event => {
            if (event.key === 'Escape' && current) {
              event.preventDefault();
              event.stopImmediatePropagation();
              exit();
            }
          }, true);

          // Picture in picture keeps playing with the panel closed; the app mustn't release the page.
          for (const [type, on] of [['enterpictureinpicture', true], ['leavepictureinpicture', false]]) {
            document.addEventListener(type, () => post({ pictureInPicture: on }), true);
          }
          document.addEventListener('webkitpresentationmodechanged', event => {
            post({ pictureInPicture: event.target.webkitPresentationMode === 'picture-in-picture' });
          }, true);
        })();
        """, injectionTime: .atDocumentStart, forMainFrameOnly: false)

    /// Picture in picture is off in WKWebView unless this WebKit preference is set. It has no
    /// public setter; check it exists so a WebKit without it doesn't raise.
    static func enablePictureInPicture(_ preferences: WKPreferences) {
        if preferences.responds(to: NSSelectorFromString("_setAllowsPictureInPictureMediaPlayback:")) {
            preferences.setValue(true, forKey: "allowsPictureInPictureMediaPlayback")
        }
    }
}

/// Forwards script messages without the user content controller retaining the receiver.
final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

/// A borderless black window covering the screen below the menu bar, the Dock included.
final class FullscreenWindow: NSWindow {
    var onExit: () -> Void = {}

    init(screen: NSScreen) {
        var frame = screen.frame
        frame.size.height = screen.visibleFrame.maxY - screen.frame.minY
        super.init(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
        backgroundColor = .black
        hasShadow = false
        isReleasedWhenClosed = false
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Esc the page didn't take.
    override func cancelOperation(_ sender: Any?) {
        onExit()
    }

    /// ⌘W.
    override func performClose(_ sender: Any?) {
        onExit()
    }
}
