# WebDock

A macOS menu bar app that keeps your favorite web apps — ChatGPT, Claude, Gemini, X, Gmail, anything — one click away in a Liquid Glass panel.

## Features

- **Menu bar panel** — click the globe icon for a rounded Liquid Glass panel that drops down from the menu bar.
- **Start page** — clock, greeting, a Google search box (or type a URL), your sites as tiles (drag to rearrange), and a "Jump back in" list of recent pages.
- **Sidebar** — site icons beside the page; the button at the top left shows or hides it. `⌘1`–`⌘9` switch sites, `⇧⌘H` goes home, `⌘T` opens a fresh start page.
- **All pages** — `⇧⌘\`, the button at the header's far right, or a trackpad pinch in shows the open pages as cards, like the iPhone's app switcher. Scroll or swipe through them, click one (or pinch out) to open it, drag one up to close its page; `Esc` goes back.
- **Stays logged in** — each site keeps its cookies; Google sign-in works in the embedded browser.
- **Memory-friendly** — sites load on demand. Off-screen pages are released after 3 minutes; their WebKit interaction state is held in memory for recovery (navigation, scroll position, and some form data), while cookies remain persistent. Pinned pages stay loaded. State does not survive quitting WebDock, and web apps may not restore unsent drafts.
- **Hover preloading** — pointing at a sidebar icon or start-page tile for 250 ms starts loading that site in the background (one speculative page at a time).
- **Switcher process memory** — Show All Pages displays a best-effort resident memory reading below each live page. This is the WebKit content **process** memory, not per-page allocation. Processes may be shared. The reading may be unavailable if WebKit changes its private process-ID interface.
- **Adapts to the page** — the glass takes on the page's color, and the chrome goes light or dark with it.
- **Per-site layout** — Auto / Desktop / Mobile. Auto switches desktop-only sites to their mobile version when they don't fit.
- **Per-site dark mode** — Auto / Force / Off. Auto darkens pages that ignore the system's dark mode, and follows the system live.
- **Global shortcut** — `⌥Space` (changeable in Settings) shows or hides the panel from any app.
- **Resizable** — drag the panel's left, right or bottom edge; the size is remembered.
- **Find and zoom** — `⌘F` / `⌘G` find on the page; `⌘+` / `⌘−` / `⌘0` zoom, remembered per site.
- **Unread badges** — sidebar icons show the count a page puts in its title, like Gmail's "Inbox (3)".
- **Downloads** — files go to Downloads, with a "Show in Finder" toast when done.
- **Microphone and camera** — voice modes and calls work; the site gets access without asking each time.
- **Open in Window** — move a page, as it is, into a window of its own.
- **Video** — a player's fullscreen button fills the screen below the menu bar (Esc to leave), and picture in picture works; a page playing either way isn't released.
- **Add from the panel** — the start page's "+" tile, or "Add Page as Site" in the header's ⋯ menu; the name fills itself in.

## Build

Requires macOS 13+ and Xcode (Swift 6 toolchain). Liquid Glass needs macOS 26; older systems get a frosted fallback.

```sh
./build.sh
open build/WebDock.app
```

`build.sh` compiles with Swift Package Manager, assembles `build/WebDock.app`, copies in `Resources/AppIcon.icns`, and signs it with your Developer ID or Apple Development certificate (falling back to ad-hoc; set `CODESIGN_IDENTITY` to choose one).

The icon is generated from `BrowserBarIcon.iconset/BrowserBar_1024.png` by `Scripts/make-icon.py` (needs Pillow and NumPy), which redraws it full-bleed for the macOS 26+ icon shape. `build.sh` reruns it when the source art changes.

For UI work, `open build/WebDock.app --args --show-panel` opens the panel on launch.

## Usage

- Left-click the menu bar icon to open or close the panel; right-click for Settings and Quit.
- Add, edit, reorder, and remove sites in Settings (`⌘,`).
- Right-click a sidebar icon to open the site in your browser or its own window, close its page, or change its layout and dark mode.
- `⌘W`, or the ✕ at the header's right, closes the page on screen; the ✕ asks for a second click so a stray one doesn't. On the start page, `⌘W` closes the panel.
- Settings (`⌘,`) has an Open at Login switch, the global shortcut, and whether the start page puts your most used sites first.

## License

WebDock is licensed under the [GNU General Public License v3.0](LICENSE).
