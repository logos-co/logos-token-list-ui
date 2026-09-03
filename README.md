# logos-token-list-ui

Basecamp panel for [`token_list_module`](https://github.com/logos-co/logos-evm-token-list-module):
the token metadata store — the list built into the module, extra list URLs, and your own
custom tokens.

A `ui_qml` module — a QML view (`src/qml/TokenListView.qml`) over a small C++ backend
(`src/token_list_ui_backend.{h,cpp}`) whose QML-facing surface is the QtRO contract in
`src/token_list_ui.rep`.

```bash
git add -A   # nix only sees git-tracked files
nix build '.#lgx' --override-input token_list_module path:../token-list-module
```
See **Build** below for why the override is required today.

## Why this is its own app and not a page in the wallet

`token_list_module` persists its config and its token buckets in *its* instance directory, and
that store is **device-wide**: every Logos wallet on the device decorates its rows from it. The
wallet is not supposed to configure it — it asks whether the module is configured and, only if
nothing is, applies the module's own defaults. Everything past that default — a second list
URL, a Tor proxy, a token the wallet's allowlist does not carry — belongs here.

The wallet therefore never needs this app installed. That is the point of the split: a fresh
device works offline with the built-in list, and this panel is where someone goes to change it.

## Seven decisions worth knowing

**"Starting" is not "not configured".** The panel reads `config_status()`, whose `state` is
`unready` / `unconfigured` / `configured`. `unready` means token_list has not finished starting;
the view says *"Waiting for the token list module to finish starting…"* and polls every 1500 ms.
The "Use the built-in Uniswap list" button appears **only** for `unconfigured`. Offering to
initialize a module that has not started is the conflation the whole convention exists to
prevent, and a bool cannot express the difference.

**The view never receives the whole list.** `get_all_tokens()` is 360,569 bytes on the shipped
list, and a `PROP(QString)` re-emits its entire string on every change. So the backend holds the
selected chain's rows, filters and paginates them, and publishes **one page** in `pageJson`. The
chain roster and its per-chain counts come from a single `get_all_tokens()` read on reload.

**Every config write is one field.** `setUseEmbeddedList`, `addListUrl`, `removeListUrl`,
`setProxy` and `setTimeout` each call `configure` with a `ListConfigWire` carrying exactly the
keys they change. token_list keeps every key the object omits, so a user changing the timeout
here cannot silently clear a sibling wallet's proxy. `setProxy` sends an explicit JSON `null` to
clear the proxy — "clear it" and "leave it alone" are different requests and only one of them
may drop a Tor proxy someone set.

**Adding a list URL fetches nothing.** It stores the URL. `refreshNow()` is the single method on
this panel that touches the network, it is reachable from one button, and it is disabled while
no URL is stored. Nothing re-fetches on its own: `refreshSecs` is deliberately **not** exposed
as a scheduler, because nothing in the platform runs that timer, and a control implying
automatic refresh would be a lie. The guard around the fetch is a *deadline* (`InFlight`), never
a latch — a callback that never fires must not wedge the button shut for good.

**`logoURI` is dropped in the backend, not hidden in the view.** 1,502 of the 1,709 shipped
tokens carry one, 11 of them `ipfs://`. A `ui_qml` view's sandbox refuses remote fetches and the
only trace is HTTP 0 plus one line in the *host* log — an invisible failure on 88% of rows. The
backend emits five keys per row and `logoURI` is not one of them, so the view cannot render it
by accident.

**Every token string renders as `Text.PlainText`.** `LogosText` is a bare `Text` with no
`textFormat`, i.e. Qt's AutoText HTML autodetection. Six tokens in the shipped list already
carry `&` in their name (`Johnson & Johnson`, `SPDR S&P 500 ETF Trust`, …), and a list fetched
from a URL someone typed can carry a tag. The table's cells are custom `cellDelegate`s for that
reason: `LogosTable`'s default body cell (`LogosTable.qml:414`) sets no `textFormat`.

**The status read carries a budget; the reads behind it do not need one.** `config_status()`
goes out as `config_statusAsyncResult(..., Timeout(1500))`, because an *unloaded* dependency
costs the ABI's 20 s default and this backend runs on the GUI thread — a 1500 ms poll of a
20 s call is a frozen panel. Everything after it (`get_list_sources`, `get_all_tokens`,
`get_tokens`) stays synchronous: those run only once token_list has answered, which is what
proves it is there. Three lost status reads (~4.5 s) and the header says so rather than leaving
a stale "Ready" on screen.

## Known limits

- **Chain ids are `int` on the wire.** The `.rep` carries `chainId` as `int`, so a chain past
  2^31 is dropped from the roster rather than shown as a row that cannot be paged. The largest
  id in the shipped list is 501,000,101, so nothing is dropped today.
- **Per-URL fetch results do not survive a restart.** `get_list_sources` reads an in-memory
  `sources` vector that `TokenList::load()` never restores
  (`token-list-module/rust-lib/src/tokens.rs:150-160`), so the panel says so on screen rather
  than letting an empty list read as "every URL failed".
- **`token_count`, not `tokenCount`.** `ListSource` derives `Serialize` with no
  `#[serde(rename_all)]` (`token-list-module/rust-lib/src/tokens.rs:55`), unlike `ListConfig`
  right below it. The backend accepts both spellings and republishes the camelCase one.
- **The chain-name table is cosmetic.** Sixteen ids, display only. It is not an allowlist and
  not a security boundary: an id it has no name for renders as `Chain 4663`, never guessed.
- **Nothing typed into "Add a token" is verified against the chain.** A wrong `decimals` makes
  every balance shown for that token wrong by a power of ten. The form says so.

## Build

`ws build` **SKIPs** the EVM repos — they have no `dep-graph.nix` entry — and exits 0, so a
green `ws build` here proves nothing. Build directly:

```bash
nix build '.#lgx' --override-input token_list_module path:../token-list-module
```

`nix` only sees git-tracked files: `git add -A` before every build.

The override is **required**, not a convenience: the rev in `flake.lock` predates the
initialization convention, so a bare `nix build` has no `config_status`, `init_defaults` or
`import_custom_tokens` to compile against, and no `useEmbeddedList` in its config. Re-lock once
that work is pushed.
