# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

`vaxis` — a Zig TUI library (a fork of rockorager's libvaxis; README, docs URLs, and the mirror workflow still
point upstream). Requires Zig **0.16.0** (`.minimum_zig_version` in `build.zig.zon`). This is a 0.16-era codebase
built on the new `std.Io` API — `std.Io.File`, `std.Io.Writer`, `std.Io.Mutex`, `std.process.Init`. Pre-0.16
idioms will not compile; see @styleguide/ZIGMIGRATE.md before reaching for an older API.

Targets Linux, macOS, and Windows. The C API surface is Linux-first — several entry points deliberately return
`.err_unsupported` elsewhere.

## Build / Test

Use the `Makefile`, not bare `zig build`:

- `make build` — `zig build`
- `make test` — `zig build test --summary all` (Zig unit tests, every example, C API tests, three linked C programs)
- `make format` — `zig fmt` over the sources
- `make lint` — `zlintpre` then `zlint -c styleguide` (config: `styleguide/zlint.json`; warnings are errors)
  over `LINT_FILES`, which excludes `src/c_api.zig`
- `make validate` — the pre-commit gate: clean, format, lint, build, test
- `make docs`, `make dist`, `make linux`, `make windows`, `make clean`

`zlintpre` and `zlint` are external binaries under `/usr/local/inferise/`. If they are missing, run
`make format test` instead of `make validate` and say that lint was skipped.

Both linters default to walking the whole working directory and have no exclude option, so `make lint` feeds
them an explicit file list (`LINT_FILES`) — otherwise they lint the vendored deps under `zig-pkg/`. Add new
source roots there, in the `Makefile`, not to a config file. `LINT_EXCLUDE` drops `src/c_api.zig` from both
linters; see the C ABI note below.

`zlintpre` forbids a trailing comma in a fn parameter list, and in Zig a trailing comma is what pins a list to
one-param-per-line. Dropping it is always safe: `zig fmt` joins short lists onto one line and leaves longer ones
wrapped, and either result is stable under repeated formatting. **Never re-add a trailing comma to a fn parameter
list** — `zig fmt` will keep it and `zlintpre` will fail. Run `make format` before `make lint`, as `make validate`
does. Signatures may exceed 100 columns; nothing checks width (`line-length` is `off` in `styleguide/zlint.json`).

CI is the source of truth for formatting and runs `zig fmt --check .`; the Makefile's `format` target uses
`zig fmt **/*.zig`, which only recurses under zsh/globstar-bash. When in doubt, verify with `zig fmt --check .`.

Run the demo gallery: `make cli` (letters a-m pick a demo, esc returns to the menu, q quits). Run a single example: `make example EXAMPLE=<name>` (default
`text_input`), and `make examples` to list the valid
names. They are interactive TUIs, so they need a real tty — without one they fail at `/dev/tty` with
`error: NoDevice`, which is expected, not a regression.

`styleguide/` is a git submodule. After a fresh clone, `git submodule update --init` — without it `make lint`
loses its config and the `@` imports below resolve to nothing.

## Module layout

- `src/main.zig` — root module barrel; re-exports the public API (`Vaxis`, `Window`, `Screen`, `Parser`, `Loop`,
  `Tty`, `Key`, `Cell`, `Style`, `Color`, `Image`, `Mouse`, `widgets`, `vxfw`, `unicode`, …).
- `src/vxfw/` — the high-level Flutter-like framework: `App.zig` plus composable widgets.
- `src/widgets/` — low-level widgets; `src/widgets/terminal/` is an embedded terminal emulator (Linux-only paths).
- `src/c_api.zig` + `include/vaxis.h` — the C ABI layer. C consumers live in `examples/c/`.
- `cli/` — the demo CLI (`make cli`): a numbered menu of every vxfw widget. `main.zig` is a thin entry
  point, `demo_app.zig` is the root widget and menu, `gallery.zig` owns the stateful demo widgets.
- `examples/`, `bench/` — not published in the package (`.paths` in `build.zig.zon` ships only `LICENSE`,
  `build.zig`, `build.zig.zon`, `include`, `src`).
- `styleguide/` — org-wide style submodule. Never hand-edit; changes there affect every Inferise project.

## Architecture conventions

Org-wide Zig rules: @styleguide/ZIGSTYLE.md

This repo is a fork carrying upstream libvaxis conventions, so ZIGSTYLE applies to **genuinely new files only**.
When editing an existing file, match that file's surrounding style rather than converting it:

- Existing layout is **file-as-struct**: a PascalCase filename is a struct (`Vaxis.zig`, `vxfw/Button.zig`); a
  lowercase filename is a namespace (`tty.zig`, `gwidth.zig`). Preserve this when touching existing code; new
  files follow ZIGSTYLE's snake_case one-struct-per-file rule instead.
- `//!` for module docs, `///` for decl docs — including on private declarations.
- When a function takes an I/O handle, `io: std.Io` is the **first** parameter. `deinit` commonly takes the
  allocator back as a parameter rather than the struct storing it.
- Tests are colocated at the bottom of the file they cover, with prefix-scoped names:
  `test "parse: single xterm keypress"`, `test "Queue: simple push / pop"`.
- Public C enum values are ABI — **append only, never reorder**. C exports are gated on
  `@import("root") == @This()` so importing vaxis as a Zig module emits no `vaxis_*` symbols. C test programs
  compile with `-std=c99 -pedantic-errors`.
- **The Zig fn name in `src/c_api.zig` *is* the exported C symbol**, prefixed with `vaxis_`: `pub fn parser_new`
  exports `vaxis_parser_new`. They stay **snake_case** because C callers read them, not Zig callers — this is the
  one file where Zig naming conventions do not apply, and `make lint` skips it for exactly that reason. Renaming
  one is a breaking ABI change: update `include/vaxis.h` and `examples/c/` in the same commit, and verify with
  `nm -g zig-out/lib/libvaxis.a | grep vaxis_` against the header.
- The version lives only in `build.zig.zon`; `build.zig` `@embedFile`s and parses it at comptime and passes it to
  `src/c_api.zig` via `build_options`. Never hardcode a version elsewhere.
- `*.zig` and `*.zon` are forced to LF by `.gitattributes`.

## Project-state heads-ups

- **`make run` and `make demo` are broken.** They invoke `zig build run` / `zig build serve`, steps that do not
  exist in `build.zig`; `make demo`'s web console does not exist in this repo at all. Use `make example`
  instead. (`make github` / `make clone` also still point at `inferise/zigbase`.)
- **Tests never touch a real terminal.** `src/tty.zig` swaps in a `TestTty` whenever `builtin.is_test`, and
  `getWinsize` returns a fixed 80x40. Do not write tests that assume real terminal dimensions or capabilities;
  tests that genuinely need one return `error.SkipZigTest` (several are Linux-only).
- There is **no terminfo** — capabilities are detected by querying the terminal at runtime, so behavior differs
  under CI and other non-tty contexts.
- **SIGWINCH** (`src/tty.zig`): the handler is process-global with a fixed array of 8 slots (`notifyWinsize`
  returns `error.OutOfMemory` past that) and defers all work to a signal thread over a self-pipe to stay
  async-signal-safe. Keep new work out of the handler itself. Because the state is global, multiple TTYs in one
  compilation unit are not fully supported. On macOS the tty fd is deliberately never closed — closing
  `/dev/tty` can block indefinitely.
- **`-Dexternal_uucode=true`** makes `build()` return immediately after `addModule("vaxis")`; examples, bench,
  tests, docs, and the C library steps are all skipped by design. Do not "fix" that early return.
- The C API is compiled once as a PIC object and reused for both static and shared libs — building each
  linkage from the module directly would re-run the Zig frontend per linkage. The static lib is named
  `vaxis-static` on Windows only, because the DLL import library is also `vaxis.lib` there.
- Apps wire `pub const panic = vaxis.Panic;` so the terminal is reset on panic. `Panic` is
  `std.debug.FullPanic(panicCall)`; `vaxis.panicHandler` is the older three-argument form, still supported
  because Zig wraps a bare `panic` function in `FullPanic` itself. `examples/` use the older spelling.
- **Never write a bare `catch {}`** — `make lint` is clean and must stay that way. Bind the error and log it:
  `catch |err| log.err("...: {t}", .{err})`. Zig rejects `_ = err` ("error set is discarded") and zlint still
  flags `catch |_| {}` and a comment-only `catch { ... }`, so logging is the only way through.
- Three call sites log from contexts where `std.log` may lock, allocate, or is not async-signal-safe: `recover()`
  in `src/main.zig` (runs from the panic handler), and in `src/widgets/terminal/Command.zig` the post-`fork` child
  before `exec` and `handleSigChild`. Each carries a comment saying so. Logging there is a deliberate tradeoff of
  a small deadlock risk for diagnosability — keep the comments if you touch these.
- `.agents/setup` appends a newline to `/etc/resolv.conf` — Zig's package manager rejects one without a trailing
  newline. Relevant if package fetches fail in a sandbox.
- No env var is required to build or test. At runtime `src/Vaxis.zig` reads `NO_COLOR`, `TERMUX_VERSION`,
  `VHS_RECORD`, `TERM_PROGRAM`, `VAXIS_FORCE_LEGACY_SGR`, `VAXIS_FORCE_WCWIDTH`, `VAXIS_FORCE_UNICODE`.

## Not yet implemented

- CI runs only on pull requests to `main` and on `workflow_dispatch` — pushes to `main` are not tested.
- `typos.toml` exists but no workflow invokes it.
- No release workflow; releasing is `make tag` (bare tags like `0.6.0`, no `v` prefix).
- No `CONTRIBUTING.md`, `CODEOWNERS`, or `.editorconfig`.
- The `vt` example compiles but does not work correctly.
