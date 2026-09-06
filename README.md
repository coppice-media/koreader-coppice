# stump.koplugin

A KOReader plugin for [Stump](https://github.com/stumpapp/stump): browse and
download your library from the device, sync reading progress both ways, and
push highlights, notes and bookmarks back to the server.

Everything the plugin does uses Stump's existing, documented surfaces. There is
no Stump-side agent, no companion daemon, and no third-party service.

| Feature | Stump surface |
| --- | --- |
| Continue reading | `GET /api/v2/reading/continue` |
| Browse libraries, series, latest books | `GET /opds/v2.0/...` (OPDS 2.0 JSON) |
| Search | `GET /opds/v2.0/search?query=` |
| Download a book | `GET /api/v2/media/{id}/file` |
| Automatic progress sync | KOReader's built-in **Progress sync**, pointed at `/koreader/{api_key}` |
| On-demand progress push / pull | `PUT` / `GET /koreader/{api_key}/syncs/progress` |
| Highlights, notes, bookmarks | `POST /v1/annotations` (liseur-sync) |

## Install

Copy the plugin folder to your device's KOReader `plugins` directory:

```
<KOReader>/plugins/stump.koplugin/
```

Where `<KOReader>` is:

| Device | Path |
| --- | --- |
| Kobo | `/mnt/onboard/.adds/koreader/plugins/` |
| Kindle | `/mnt/us/koreader/plugins/` |
| reMarkable | `/home/root/koreader/plugins/` |
| PocketBook | `/mnt/ext1/applications/koreader/plugins/` |
| Android | `koreader/plugins/` in the app's storage directory |
| Desktop (Linux) | `~/.config/koreader/plugins/` or the AppImage's `koreader/plugins/` |

Only the `stump.koplugin` folder is needed; `tests/` is for development.
Restart KOReader after copying. The plugin appears as **Stump** under
`Tools` (☰ → Tools) in both the file browser and the reader.

## Settings

`Tools → Stump`:

| Setting | What it is | Needed for |
| --- | --- | --- |
| **Server** | Your Stump root URL, e.g. `http://192.168.1.10:10801`. A pasted OPDS, `/api/v2` or `/koreader/<key>` URL is trimmed back to the root for you. | everything |
| **Username** | Your Stump username. | everything |
| **Password** | Your Stump password. | highlight export |
| **API key** | A Stump API key (`Settings → App → API keys`). Needs the `ACCESS_KOREADER_SYNC` permission for progress sync. | progress sync, and preferred for browsing/downloads |
| **Download folder** | Where downloaded books are written. Defaults to KOReader's download folder. | downloads |

**Why two credentials.** Stump does not accept one credential everywhere, so
neither does this plugin:

| Surface | Accepts |
| --- | --- |
| `/opds/v2.0/...` | `Basic <user>:<api key>` **or** `Basic <user>:<password>` |
| `/api/v2/...` | `Bearer <api key>`, or a `stump_session` cookie from `POST /api/v2/auth/login` |
| `/koreader/{api_key}/...` | the API key **in the path**; no header |
| `/v1/...` (annotations) | `Bearer <device secret>`, minted from a `POST /v1/login` |

The API key is preferred wherever it works, because a Stump API key can carry
narrower permissions than the account. The password is only used for the
annotation lane, where Stump bcrypt-verifies it and a key cannot stand in. If
you set only an API key, everything except highlight export works; if you set
only a password, everything except progress sync works.

## Features

### Continue reading

One request returns your most recently read, unfinished books with their
positions: `GET /api/v2/reading/continue`. This reads Stump's **unified reading
state** (`reading_heads`), so a position that arrived from KOReader, a Kobo, a
Komga client or an audiobook player all show up the same way.

OPDS 2.0 also has a "Keep Reading" feed, but an OPDS publication carries its
position only as a *link* (`rel=http://www.cantook.com/api/progression`), so
drawing a progress bar there costs one extra request per row. That is why this
screen uses the native route.

### Browsing and downloads

Libraries → series → books, latest books, and search, all over OPDS 2.0 JSON.
Tapping a book downloads it into your download folder and opens it.

The Stump media id is written into the book's KOReader sidecar
(`stump_media_id`), so progress and highlights later land on the right record
without a title guess.

### Progress sync

Two paths, and you want both.

**Automatic.** `Set up automatic progress sync` configures KOReader's own
Progress sync plugin for you: it writes the custom sync server
(`<server>/koreader/<api key>`), fills in the username/key fields that plugin
requires, and switches document matching to **Binary**. Restart KOReader
afterwards so it re-reads its settings. From then on KOReader pushes on page
turn, suspend and document close, on its own schedule — this plugin does not
duplicate that.

Stump ignores the kosync username and password (KOReader sends `md5(password)`,
which cannot be checked against a bcrypt hash); the key in the URL is the
credential. Binary matching is not optional: Stump identifies a document by
KOReader's partial MD5, stored as `media.koreader_hash`. With filename matching
every push is a `404`.

**On demand.** `Push this book's progress now` and `Pull this book's progress
from Stump` do one round trip each and tell you what happened. The pull offers
to jump to the server's position.

### Highlights, notes and bookmarks

`Export highlights and notes to Stump` maps the open book's
`doc_settings.annotations` onto Stump's liseur-sync annotation records:

| KOReader | Stump annotation |
| --- | --- |
| `drawer` set (a drawn highlight) | `kind: highlight` |
| `drawer` unset (a page bookmark) | `kind: bookmark` |
| `text` (the selected passage) | `excerpt` |
| `note` (your own note) | `body`, on a highlight |
| `color` | `color`, if it is one of Stump's six palette tokens |
| `page` / `pos0` / `pos1` / `pageno` / `chapter` / `drawer` | `locator`, verbatim |
| `pageno / page count` | `progression` |
| `datetime` | `client_ts` (converted from device-local time to UTC) |

The locator is opaque to the server and is replayed byte for byte, so a
crengine DOM x-pointer stays an x-pointer: it is **not** converted into a
Readium locator or an EPUB CFI, because that would fabricate an anchor.

Each record's id is derived from its anchor and creation time, so re-exporting
the same book updates the same records instead of creating copies. The last
accepted revision per record is remembered in the book's sidecar
(`stump_annotation_revs`), which is what makes the second export a
compare-and-set edit rather than a conflict.

Stump's `note` kind is never produced: it is defined as the *unanchored* one,
and every KOReader annotation has an anchor. A highlight that has a note keeps
its anchor and carries the note in `body`.

### Linking a sideloaded book

A book that was not downloaded through the plugin is matched in three steps,
most reliable first:

1. the sidecar's `stump_media_id`, written by the plugin's own download;
2. the book's partial MD5 matched against `koreaderHash` from
   `/api/v2/reading/continue` — the same value Stump stores as
   `media.koreader_hash`, so any book that has ever synced progress is
   identified exactly;
3. `Link this book to a Stump book…`, which searches the library and lets you
   pick.

Nothing is guessed from a title.

## Limitations

- **Audiobooks cannot be downloaded.** A multi-file audiobook advertises one
  acquisition link per track; that is a playlist, not a book file. It still
  appears in the catalogue and on the dashboard.
- **Highlight export needs a file-backed book.** Stump resolves a book's work
  identity by digesting the file. A directory-backed book (a multi-file
  audiobook, a folder book) answers `500 Is a directory`, which the plugin
  reports as-is.
- **Highlight export can hit a `409`.** If two copies of the same book in your
  library claim the same identity, Stump refuses to guess which work you meant
  (`identifiers resolve to multiple works`). Resolve the duplicate server-side.
- **`/opds/v2.0/books/browse` is not offered.** Its handler flattens the
  pagination struct into its query parameters, and a flattened serde struct
  cannot coerce a query string: `?page=1` answers `400 invalid type: string
  "1", expected u64`, and so does the `next` link the feed emits. Libraries,
  series, latest books and search reach every book and page correctly.
- **Progress is one-shot per direction.** Automatic background sync is
  KOReader's built-in plugin, configured by this one. There is no
  plugin-owned scheduler.
- **Highlights are push-only.** Deletions made on the device are not
  tombstoned on the server, and annotations created elsewhere are not imported
  into KOReader. The plugin reads the server's live set only to report a count.
- **No Readium locator translation.** Progress and annotation anchors travel in
  KOReader's own format.

## Verification

Every HTTP call the plugin makes has been exercised with `curl` against a live
Stump built from `apps/server` (`headless,liseur-sync`): OPDS 2.0 browse and
search under both Basic credentials, `/api/v2/reading/continue` under a Bearer
API key and under a session cookie, the file download (including a `Range`
request), the three kosync routes, and the whole annotation lane
(`login` → `tokens` → `token` → `books/{id}/resolve` → `annotations` create,
stale replay → `conflict`, edit → `rev 2`, live read).

The pure functions — URL building, OPDS mapping, annotation mapping, the kosync
settings patch — are checked by `tests/pure_checks.lua`:

```sh
lua tests/pure_checks.lua      # or luajit, or lua5.1
```

**The plugin has never been run inside KOReader.** No device or desktop
KOReader run has happened: the Lua loads and the pure logic is checked, and
the server contract it targets is verified, but the UI, the menu wiring, the
network calls in KOReader's own environment, and the interaction with the
built-in Progress sync plugin are unverified.

## Layout

| File | Responsibility |
| --- | --- |
| `main.lua` | Plugin lifecycle, settings, menu, progress and annotation actions |
| `stump_api.lua` | HTTP client for all four surfaces and their credentials |
| `stump_url.lua` | URL building and normalization (pure) |
| `stump_opds.lua` | OPDS 2.0 feed → browser rows (pure) |
| `stump_annotations.lua` | KOReader annotations → liseur-sync records (pure) |
| `stump_kosync.lua` | Configures KOReader's built-in Progress sync plugin |
| `stump_browser.lua` | The browser `Menu`: dashboard, catalogue, downloads |
| `tests/pure_checks.lua` | Checks for the pure modules |

## Licence

MIT, matching Stump.
