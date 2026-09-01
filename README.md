# Noir Terminal (noirterm) — phase 1

A from-scratch terminal emulator core in Zig. This is the foundation for
the eventual "built-in everything" terminal: GPU rendering, ligatures,
kitty graphics protocol, ASCII tabs, multiplexing, a file manager, a
music player, theming, and a new shell all get built on top of this.

**Target platform is Windows.** The core (parser + grid) is 100%
platform-agnostic; the only OS-specific piece is the PTY backend, which
is split behind a compile-time dispatcher (`src/pty.zig`) so the rest of
the codebase never needs an `if (windows)` anywhere.

## What's actually here right now

Phase 1 (core, platform-agnostic) + phase 2 (windowing, Windows-only —
GDI as an interim renderer, not the final GPU one):

- **`src/pty_linux.zig`** — real Linux PTY spawning via raw syscalls
  (no libc). Built AND run here, output inspected: a real `/bin/sh`
  spawned, fed real ANSI codes, read back and parsed correctly.
- **`src/pty_windows.zig`** — real ConPTY-based Windows backend
  (`CreatePseudoConsole` + `CreateProcessW` with the
  `PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE` attribute). Cross-compiles and
  **links** cleanly to a real Windows PE executable (verified via
  `zig build -Dtarget=x86_64-windows-gnu`) but has **not been run** —
  this dev sandbox has no Windows runtime to execute against. Treat the
  plumbing as solid, the runtime behavior as unconfirmed until you run
  it yourself.
  - One real gotcha already found and worked around: the mingw-w64
    import library bundled with this Zig toolchain names the
    `UpdateProcThreadAttributeList` symbol `UpdateProcThreadAttribute`
    (missing "List") — see the comment in `pty_windows.zig`. Worked
    around with a target-conditional `@extern` binding. **If you build
    with `-target x86_64-windows-msvc` instead of `-gnu`, this
    shouldn't matter** (MSVC's own kernel32.lib has the correct name) —
    that's the safer target to build against for real, since it
    sidesteps this mingw quirk entirely.
- **`src/pty.zig`** — picks the right backend at compile time based on
  `builtin.os.tag`.
- **`src/vt/parser.zig`** — the standard terminal escape-sequence state
  machine (ground / escape / CSI-entry / CSI-param / CSI-intermediate /
  OSC-string, plus stub states for DCS and APC so kitty's graphics
  protocol and Sixel don't corrupt the stream later) with incremental
  UTF-8 decoding layered on top. Fully platform-agnostic. Has unit
  tests (`zig build test`).
- **`src/grid.zig`** — the actual screen buffer: cursor-addressed cells
  with per-cell fg/bg/attributes, cursor movement, line/screen erase,
  and SGR handling (16-color, 256-color, and truecolor). Also fully
  platform-agnostic. Also holds `images`: decoded kitty-graphics
  placements, kept separate from the cell grid rather than bloating
  every `Cell`.
- **`src/color.zig`** — color types + `Theme` (a 16-slot palette plus
  default fg/bg/border) with a swappable `active` theme that the
  renderer always reads from. Ships two built-in themes: `everforest_dark`
  (the default) and `noir` (an actual grayscale theme — see `theme.zig`).
- **`src/theme.zig`** — the theme file format (a small hand-rolled
  INI-style format: `[palette]`/`[ui]` sections, `key = #RRGGBB`, `#`
  comments) plus a `Registry` for cycling between loaded themes.
  **Genuinely unit-tested** — 5 tests covering parsing, malformed-line
  tolerance, and round-tripping — pure logic again, no OS dependency.
  Loading a theme file from disk and the F5 cycle keybinding live in
  `window.zig`, since that part needs real Win32 file APIs.
- **`src/layout.zig`** — binary split-tree for panes (tmux/zellij-style):
  split, close (collapses to the sibling), focus-cycling, and rect
  computation, all pane-agnostic (panes are referred to by plain
  `usize` index, owned by the tab). **Genuinely unit-tested** — 7 tests
  covering split/close/focus/rect math, all passing — since this is
  pure logic with zero OS dependency, unlike almost everything else in
  this project.
- **`src/kitty_graphics.zig`** — parses the kitty graphics protocol's
  APC payload (`G<key>=<val>,...;<base64>`) and decodes it into raw
  RGBA pixel data. **Genuinely unit-tested** — 5 tests covering
  RGBA/RGB decoding, malformed/unsupported input, and image IDs — pure
  logic again, no OS dependency. Deliberately a minimal slice of a
  large protocol: direct transmission only, raw RGBA/RGB only (no
  PNG), no chunking, no animation — see the file header for the full
  scope note.
- **`src/pane.zig`** — one terminal session: its own PTY, parser, grid,
  and background reader thread. A tab holds one or more panes arranged
  by a `layout.Layout`. Also where `apc_dispatch` actions get handed to
  `kitty_graphics.parse` and successfully-decoded images get stored on
  the pane's `Grid`.
- **`src/win32.zig`** — hand-declared user32/gdi32 bindings (window
  creation, message loop, GDI text drawing). None of this exists in
  Zig's std.os.windows, which only wraps what Zig's own stdlib needs.
- **`src/renderer_gdi.zig`** — draws the grid via `TextOutW`, batching
  runs of same-colored cells into single calls. Kept in the tree as a
  lower-risk fallback path (plain C-ABI calls, no COM) but **not wired
  up anymore** — `window.zig` now uses the D2D renderer below. GDI is
  also structurally incapable of ligatures (no text-shaping engine),
  which is the whole reason this phase moved to D2D/DirectWrite.
- **`src/d2d_shim.h`** + **`src/d2d.zig`** — real GPU-accelerated
  rendering via Direct2D + DirectWrite. Rather than hand-transcribing
  COM vtable layouts from memory (the classic way to introduce a bug
  that compiles fine and only misbehaves at runtime), this
  `@cImport`s the actual mingw-w64 `d2d1.h`/`dwrite.h` headers
  (bundled with this Zig toolchain) and calls through the
  compiler-generated struct layouts directly. Two real findings from
  building it, both documented in `d2d.zig`'s header and worked around
  in code:
  - The header's `COBJMACROS` mode normally generates safe
    `Interface_Method(this, ...)` wrapper functions, but they don't
    actually compile against this Zig version (missing the `.?` Zig
    requires to call an optional function pointer) — worked around by
    calling through the vtables directly, with the exact field paths
    (including which methods sit under a nested `.Base` for inherited
    COM interfaces) confirmed from the compiler's own error output.
  - One method's vtable field ended up named `DrawTextA` rather than
    `DrawText`, apparently from a header-order-dependent macro
    collision — caught immediately as a compile error naming the
    actual field, not a silent runtime mismatch, which is the whole
    point of getting this from real headers instead of memory.
- **`src/renderer_d2d.zig`** — same run-batching approach as the GDI
  renderer, but real GPU rendering with DirectWrite handling text
  shaping, so ligatures work automatically for a capable font. Draws
  one pane at a given pixel origin — doesn't call begin/clear/end
  itself, since multiple panes now share one D2D frame.
- **`src/window.zig`** — the actual Windows app: creates the window,
  manages tabs (each its own `layout.Layout` + pane list), spawns
  `cmd.exe` in a ConPTY per pane, runs a background reader thread per
  pane, feeds bytes through the parser into each pane's grid, and
  repaints via D2D on change. Draws pane borders and the tab bar as
  plain ASCII characters (`|`, `-`) rather than Unicode box-drawing,
  matching the project's terminal aesthetic. Routes `WM_CHAR` (typed
  text, including Ctrl+letter combos via Windows' own keyboard
  translation) and arrow keys to the *focused* pane. Placeholder
  keybindings: F2/F3 split horizontal/vertical, F4 close focused pane,
  Ctrl+Tab cycle focus, Ctrl+T new tab, Ctrl+PageUp/Down switch tabs —
  these should become configurable once the theme/config system
  (phase 6) exists rather than staying hardcoded.
- **`src/main.zig`** — branches by platform: real window on Windows,
  the original phase-1 headless proof everywhere else (this sandbox's
  fast-iteration harness for the platform-agnostic core).
- **`src/gitinfo.zig`** — reads `.git/HEAD` directly (no shelling out
  to `git.exe`) to detect the current branch, or a short hash for a
  detached HEAD. Unit-tested (3 tests) — and unlike almost everything
  else Windows-specific in this project, this one's actually been run:
  correct branch detection and detached-HEAD short-hash truncation
  confirmed against real (test-fixture) `.git` directories.
- **`src/prompt.zig`** — composes a starship-style ANSI prompt line
  from gathered context, using the currently active `color.Theme` so
  the prompt always matches the terminal. Unit-tested (4 tests) and
  actually run — confirmed producing correct ANSI-colored output.
- **`src/prompt_main.zig`** — the standalone `noirprompt` binary:
  gathers cwd/git-branch/exit-code and prints the composed prompt line.
  Meant to be invoked from a shell's prompt hook (a PowerShell
  integration snippet is in the file header) — architected the same
  way real starship is, as a separate program, not baked into the
  terminal itself.
- **`src/tui.zig`** — shared plumbing for the standalone TUI tools
  (file manager, music player): raw-mode terminal input and ANSI
  drawing helpers. Key decoding reuses `vt/parser.zig` — the same VT
  state machine that decodes a shell's *output* also correctly decodes
  the escape sequences a terminal sends *for* arrow keys, so there's
  no second parser to get right here.
- **`src/dirscan.zig`** — directory listing shared by the file manager
  and music player's track list. Windows side
  (`FindFirstFileW`/`FindNextFileW`) has its struct layout cross-checked
  against the real mingw headers via `@cImport`, same technique as
  `d2d.zig` — a wrong field order here would silently misread file
  names rather than fail to compile, so it wasn't worth trusting to
  memory. Linux side uses the `getdents64` syscall directly.
- **`src/filemanager_main.zig`** — the standalone `noirfiles` binary: a
  real interactive file browser (arrow-key navigation, Enter to
  descend into directories, Backspace to go up, `q` to quit). **Actually
  run** — real directory listing, sorting, navigation, and descent all
  confirmed working end to end against real test directories on Linux.
- **`src/mci.zig`** — real audio playback via Windows' legacy MCI
  (`winmm.dll`) — a plain C-ABI string-command API from the Windows 3.1
  era, deliberately chosen over WASAPI/Media Foundation (COM interfaces
  on the scale of Direct2D) to avoid taking on a second COM subsystem
  this project doesn't have budget to get right blind. Windows-only by
  nature; playback itself is unconfirmed since there's no audio
  hardware to test against here even in principle.
- **`src/musicplayer_main.zig`** — the standalone `noirplay` binary:
  scans a directory for audio files, lists tracks, and plays the
  selected one via `mci.zig` on Windows. On Linux it swaps in a
  simulated player (`SimPlayer`) that fakes playback position advancing
  with real wall-clock time, so the TUI's navigation, track filtering,
  and status-line logic have **actually been run and confirmed
  correct**, even though the real audio backend hasn't.

**Verification status, plainly:** confirmed running on real Windows —
the window opens, ConPTY spawns `cmd.exe`, and D2D/DirectWrite render
it, with no errors reported. That confirmation covers the core
window/render/PTY loop as it stood at that point; it does NOT yet cover
tabs/panes/splits, kitty graphics, or the theme switcher added since —
those are still "compiles and links, unconfirmed on screen" like
everything always starts out in this project. One real bug was already
found and fixed this way: `d2d.zig` was `@alignCast`-ing an HWND as if
it were a normally-aligned pointer, which Windows handles don't
actually guarantee — see the fix commit/history for the pattern if this
class of bug shows up again with a different handle type. The Linux
headless path has also actually been run and inspected line by line,
and `layout.zig`/`kitty_graphics.zig`/`theme.zig`/`gitinfo.zig`/
`prompt.zig` all have real passing unit tests (31 across the project
total). Beyond unit tests, three of the standalone tools have actually
been *run* end to end with real output inspected: `noirprompt` (correct
ANSI, correct git-branch/detached-HEAD handling), `noirfiles` (real
directory listing/sorting/navigation/descent against real test
directories), and `noirplay` (real track scanning/filtering and a
simulated-but-functionally-exercised play/pause/status flow). That's
the fully-verified layer. The OS-facing orchestration in `window.zig`
(tab/pane/theme wiring) and real audio playback in `mci.zig` are where
confidence is lower until each gets its own run on your machine. Please
keep testing and reporting back exactly what happens — that's
consistently been the fastest way to close the gap between "compiles
and links" and "works".

### Known gaps in the multiplexer phase specifically

- No reserved gutter between panes — the ASCII border is drawn
  directly on the split boundary rather than the layout reserving a
  dedicated 1-cell gap, so it slightly overlaps each pane's edge
  column.
- Closing the last pane of the last tab is a no-op rather than
  quitting or spawning a fresh tab — there's nowhere for "zero tabs"
  to render, and that edge case needs a real decision.
- Split ratios are fixed at 50/50 — no interactive resize yet.

## Building it

Needs Zig 0.16. On your Arch box: `pacman -S zig`.

```
zig build                                        # native build
zig build run                                    # native build + run noirterm
zig build run-prompt -- 0                        # build + run noirprompt (arg = last exit code)
zig build run-files                              # build + run noirfiles (file manager TUI)
zig build run-play                               # build + run noirplay (music player TUI)
zig build test                                   # all unit tests
zig build -Dtarget=x86_64-windows-msvc            # cross-compile for Windows (recommended target)
zig build -Dtarget=x86_64-windows-gnu             # also works, see mingw note above
```

Building natively ON Windows, `zig build` will just pick up the
Windows backend automatically via `builtin.os.tag` — no flags needed.

## Roadmap (rough, in dependency order)

1. ~~Core: PTY (both backends) + VT parser + grid buffer~~ — done
2. ~~Windowing: real win32 window + message loop + GDI text rendering,
   keyboard input wired to the PTY~~ — done, untested on real Windows
3. ~~Real GPU rendering + ligatures: Direct2D + DirectWrite~~ — done,
   untested on real Windows. See `src/d2d.zig`'s header for two real
   findings from building it: the COBJMACROS-generated helper functions
   don't actually compile in this Zig version (missing `.?` on optional
   function pointers), and one method's vtable field is named
   `DrawTextA` rather than `DrawText` due to header-order macro
   pollution — both are now documented and worked around in code, not
   just here.
4. ~~Tabs & multiplexing: binary split-tree layout, per-pane PTY/parser/
   grid, ASCII borders and tab bar~~ — done. `layout.zig`'s tree logic
   (split/close/focus-cycling/rect math) is genuinely unit-tested
   (13 tests, all passing) since it's pure logic with no OS dependency —
   the one part of this phase that isn't just "compiles, hope for the
   best". The window/pane/rendering wiring around it is untested on
   real Windows like everything else in this project.
5. ~~Kitty graphics protocol~~ — done, the minimal viable slice of it.
   `kitty_graphics.zig`'s parsing/base64-decoding logic is genuinely
   unit-tested (5 tests, all passing) — pure logic again, same as
   layout.zig. Supports direct transmission (t=d) of raw RGBA (f=32)
   and RGB (f=24) pixel data only — no PNG (f=100), no chunked
   transmission, no animation frames. Rendering uses a real GPU bitmap
   via `ID2D1RenderTarget::CreateBitmap`/`DrawBitmap` (same
   real-headers-not-memory approach as the rest of `d2d.zig`), though
   it re-uploads every image fresh on every single paint call —
   correct but wasteful, the obvious next optimization once this is
   confirmed working at all.
6. ~~Theme config format + live switcher~~ — done. `theme.zig`'s parser
   is genuinely unit-tested (5 tests) — a small hand-rolled INI-style
   format (`[palette]`/`[ui]` sections, `key = #RRGGBB`, `#` comments),
   not a pulled-in TOML/YAML library, matching this project's
   zero-dependency pattern elsewhere. Two built-in themes ship
   (everforest-dark, and an actual "noir" grayscale theme — felt wrong
   for a project called Noir Terminal not to have one), F5 cycles
   between them, and `%APPDATA%\noirterm\theme.ini` is loaded and
   appended to the list at startup if present. The placeholder
   keybindings from phase 4 should move into this same config surface
   eventually rather than staying hardcoded in `window.zig`.
7. ~~Widgets (starship-style prompt segments)~~ — done, built as a
   genuinely separate program (`noirprompt.exe`), same architecture as
   real starship, since the roadmap always said this belongs on the
   shell side rather than baked into the terminal. `prompt.zig`'s
   composition logic and `gitinfo.zig`'s `.git/HEAD` parsing are both
   unit-tested (7 tests total) — and unlike everything Windows-specific
   in this project, **this one's actually been run and its real output
   inspected**, on Linux (this sandbox's available platform): correct
   ANSI-colored output pulling live from the active theme, correct
   branch-name display against a real `.git/HEAD`, and correct
   short-hash truncation for a detached HEAD. The Windows-specific
   gathering (`GetCurrentDirectoryW` etc.) is still unconfirmed on real
   Windows, but the actual logic it feeds — the part that was genuinely
   worth getting right — has real proof behind it now, not just a
   compile check.
8. ~~File manager pane, music player pane~~ — done, built as two more
   standalone binaries (`noirfiles`, `noirplay`) spawned into a pane
   over its PTY, same architecture as `noirprompt` and `cmd.exe` itself
   — not a native rendering mode inside the terminal. **Both have
   actually been run**, on Linux (this sandbox's available platform):
   real directory listing, sorting, arrow-key navigation (decoded by
   reusing the terminal's own `vt/parser.zig` — a nice payoff of that
   code being correct), directory descent, track-list filtering by
   extension, and simulated playback state all confirmed working
   end to end against real test directories. Real audio playback uses
   MCI (`winmm.dll`, a plain C-ABI legacy API, not COM — a deliberate
   choice to avoid taking on a second COM subsystem the size of
   Direct2D) and is Windows-only by nature; it hasn't been confirmed
   against real audio hardware, which doesn't exist in this sandbox
   even in principle. `noirfiles` doesn't yet launch a file's default
   associated app on Enter (only directory descent) — a reasonable,
   clearly-scoped follow-up.
9. **The new shell** — separate binary, spawned inside the PTY like any
   other shell; fish-style autosuggest, nushell-style structured errors

Each of these is its own substantial build — treat this roadmap as
"what's next", not "what's left for one sitting."
