# omarchy-windows (`drebbe.windows`)

An Omarchy Top-Bar window switcher widget and popup (`drebbe.windows`) that shows running and minimized windows across all workspaces, monitors, and layouts (tiled, scrolling, and floating).

## Features

- Top-bar summary chip (`Windows` or active count + minimized indicator)
- Filter tabs for `All`, `WS <slot>`, and `Minimized`
- Works with both Wayland and XWayland windows, Chromium webapps, and Steam titles
- Terminal process/CWD disambiguation when multiple terminal windows share a title
- Keyboard navigation (`↑`/`↓`, `←`/`→`, `Enter` to focus/restore, `x` to close, `Esc` to close)
- Bulk `Restore all` action for minimized windows

## Installation

Install directly from GitHub with `omarchy plugin add`:

```bash
omarchy plugin add https://github.com/ic3man5/omarchy-windows --enable
```

To place it right after the workspaces indicator on the left bar section:

```bash
omarchy plugin enable drebbe.windows left:after:omarchy.workspaces
```

## Updating

```bash
omarchy plugin update drebbe.windows
```

## License

MIT
