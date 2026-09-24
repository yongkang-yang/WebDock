# WebDock

A macOS menu bar app that keeps your favorite web apps — ChatGPT, Claude, Gemini, X, Gmail, anything — one click away in a Liquid Glass panel.

## Features

- **Menu bar panel** — click the globe icon for a rounded Liquid Glass panel that drops down from the menu bar.
- **Start page** — clock, greeting, a Google search box (or type a URL), your sites as tiles, and a "Jump back in" list of recent pages.
- **Sidebar** — site icons that auto-hide (hover the left edge) or stay pinned. `⌘1`–`⌘9` switch sites, `⌘T` opens a fresh start page.
- **Stays logged in** — each site keeps its cookies; Google sign-in works in the embedded browser.
- **Memory-friendly** — sites load only when opened; pages off screen for 3 minutes are released and resume where you left off.
- **Adapts to the page** — the glass takes on the page's color, and the chrome goes light or dark with it.
- **Per-site layout** — Auto / Desktop / Mobile. Auto switches desktop-only sites to their mobile version when they don't fit.
- **Per-site dark mode** — Auto / Force / Off. Auto darkens pages that ignore the system's dark mode, and follows the system live.

## Build

Requires macOS 13+ and Xcode (Swift 6 toolchain). Liquid Glass needs macOS 26; older systems get a frosted fallback.

```sh
./build.sh
open build/WebDock.app
```

`build.sh` compiles with Swift Package Manager, assembles `build/WebDock.app`, builds the app icon from `BrowserBarIcon.iconset`, and ad-hoc signs it.

For UI work, `open build/WebDock.app --args --show-panel` opens the panel on launch.

## Usage

- Left-click the menu bar icon to open or close the panel; right-click for Settings and Quit.
- Add, edit, reorder, and remove sites in Settings (`⌘,`).
- Right-click a sidebar icon to open the site in your browser, close its page, or change its layout and dark mode.
