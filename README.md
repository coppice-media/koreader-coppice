# coppice.koplugin

A KOReader companion with a cover-first library UI for Coppice. Browse paged
cover grids, inspect book details, continue reading, and download books; progress
sync uses KOReader's built-in KOSync client, with annotations on liseur-sync.

The shipped plugin is named **Coppice** and installs as one directory:
`coppice.koplugin/`. The generic archive contains no account credentials,
password material, API key, liseur token, pairing nonce, or reusable secret.

## Install, upgrade, uninstall

1. Build or download `dist/coppice.koplugin.zip`.
2. Extract the single `coppice.koplugin/` directory into KOReader's `plugins`
   directory.
3. Restart KOReader. **Coppice** is first in Tools in both File Manager and
   Reader; the File Manager also has **Main → Browse Coppice library**.

Typical plugin directories are `/mnt/onboard/.adds/koreader/plugins/` on Kobo,
`/mnt/us/koreader/plugins/` on Kindle, and `~/.config/koreader/plugins/` on a
Linux desktop. Do not extract `tests/`, `dist/`, or the repository itself onto
the device.

An upgrade is a clean replacement of `coppice.koplugin/`. On first load the
plugin removes the known historical `stump.koplugin` files and its old settings
file without importing their contents. It never silently reuses an old
credential. The next pairing therefore issues fresh credentials.

Use **Forget this device pairing** before uninstalling when the device should
stop using its locally stored credentials. It restores prior KOReader progress
sync settings while Coppice still owns that target; an uninstall integration can
call `onUninstall()` for the same cleanup. Server-side device revocation remains
an operator action in Coppice.

## Using the library

Once the device is paired, Coppice Home opens by itself when KOReader starts
(once per run; closing a book returns to the file browser). Turn this off with
**Tools → Coppice → Open Coppice when KOReader starts**. Otherwise open
**Browse library** from **Tools → Coppice** or **Browse Coppice library** in
the File Manager Main menu, or bind **Coppice: browse library** to a tap or
swipe under **Settings → Taps and gestures** (category General).

Home shows library, in-progress, and on-device counts; local reading statistics
(today, the last seven days, and streak); Continue reading; recent highlights
and notes; recently opened books; paginated Recently added covers; and the
Browse actions. Its status line includes time, battery, Wi-Fi, server
reachability, and queued progress/annotation updates. Recent highlights and
notes are the four newest from the server across every book and app (Liseur,
Home, Kobo, KOReader), cached for offline viewing. An audiobook's page offers its
ebook edition when one is linked; KOReader cannot play audio.

Home is always exactly one screen wide and never scrolls sideways. It fits on
one screen or scrolls over at most two: each swipe moves a full screen and
snaps to a card row, and the last swipe stops at the end. On short screens
(for example a Kobo Clara) the cover rows shrink, three highlights show instead
of four, and reading stats and recently opened books become compact text rows.
Browse is a 3 × 3 grid; recently added books and all notes are reached from
their Home sections. Tap a Continue-reading cover to open its valid local
file directly; otherwise it opens book details. Long-press always opens details.

Search covers library results. Catalog views use a paginated four-column,
three-row cover-only grid with a count/sort subtitle, page controls, and a
**List**/**Covers** toggle. Missing artwork uses a bordered title placeholder;
only visible image covers are fetched. Thumbnails are cached in KOReader's
cache directory with a 24 MiB eviction budget. **On device** lists plugin
downloads identified by their Coppice media-ID sidecars. Book details show
available metadata, tags, progress, summary, series/author rows, Open or
format-labelled Download, and Remote notes actions. Reading-list metadata is
available, but the server does not expose reading-list membership.

## First launch: passwordless pairing

Pairing is the only onboarding flow. If no non-secret server origin was included
in a personalized archive, enter the Coppice root URL when prompted. The plugin
then starts the normal five-minute window:

```http
POST /api/v2/devices/pair/start
Content-Type: application/json

{"kind":"coppice","name":"KOReader"}
```

The response contains `pairing_id`, a six-digit **string** `code`, a random
`nonce`, `expires_at` (RFC 3339 UTC), and `poll_interval_secs`. The code and
expiry are shown on the device. The nonce is retained only while polling and is
never used as a credential for any other route.

The plugin polls exactly this endpoint, using the nonce query parameter:

```http
GET /api/v2/devices/pair/{pairing_id}/status?nonce={nonce}
```

`pending` is retried; `denied` and `expired` stop with a clear restart message.
On `approved`, the first response carries the one-time credentials and the
approved username:

```json
{
  "status": "approved",
  "username": "alice",
  "credentials": [
    {"kind":"liseur_token","protocol":"liseur","credential_ref":"…","secret":"…"},
    {"kind":"api_key","protocol":"koreader","credential_ref":"…","secret":"…"}
  ],
  "credential": {"kind":"api_key","protocol":"koreader","secret":"…"},
  "device": {"id":"…","name":"KOReader","kind":"coppice"},
  "endpoints": []
}
```

`credentials[]` is mapped by the explicit `(kind, protocol)` pair, never by
array position. The singular `credential` is accepted only for compatibility
with an older server response and supplies the API lane; a response without
both lanes is rejected rather than partially configured. The API key is used
for OPDS Basic (`username:api_key`), `/api/v2` Bearer, downloads, KOSync, and
progress. The liseur token is used only as a Bearer token on `/v1/*` annotation
and read-state routes. Both secrets are saved to KOReader's private settings
only after approval, then automatic KOSync is configured and KOReader is asked
to restart so its built-in client reloads the settings.

The plugin never asks for an account password and never mints a liseur token
from account credentials. Pairing approval is required for both auth lanes.

## Optional personalized configuration

The generic archive is built without configuration. A launcher may add exactly
one non-secret file at `coppice.koplugin/coppice_config.lua`:

```lua
return {
    server = "https://books.example.test", -- origin/root only
    download_dir = "/mnt/onboard/books",   -- optional default
    device_name = "Kobo Clara",            -- optional display name
}
```

Only `server`, `download_dir`, and `device_name` are read. Do not add usernames,
API keys, liseur tokens, pairing IDs/nonces, cookies, or other secrets. The
repository builder accepts the same non-secret values as command-line options.

## Deterministic builder

From this repository:

```sh
./build.sh
# dist/coppice.koplugin.zip
./build.sh --server-origin https://books.example.test --device-name "Kobo Clara"
```

The builder writes one sorted `coppice.koplugin/` tree, uses a fixed ZIP
 timestamp and stable compression metadata, and rejects legacy product paths in
the source tree. Running it twice with the same inputs produces the same bytes.
A personalized launcher may inject only the optional config file above.

## Runtime surfaces

| Feature | Coppice route or behavior |
| --- | --- |
| Home counts, paged books, libraries, series, authors, smart lists, details | Authenticated `POST /api/graphql` |
| Continue reading | `GET /api/v2/reading/continue` |
| OPDS compatibility | `GET /opds/v2.0/...` |
| Cover thumbnails | Authenticated `GET /api/v2/media/{id}/thumbnail` and `/api/v2/series/{id}/thumbnail` |
| Download | `GET /api/v2/media/{id}/file` |
| Automatic progress | KOReader KOSync at `/koreader/{api_key}` |
| Explicit progress | `/koreader/{api_key}/syncs/progress` |
| Annotations/read state | liseur `/v1/*` with the paired device token |

The plugin downloads only single-file acquisitions that KOReader can open.
Folder-backed or multi-track audiobooks remain visible but are not handed to
the reader. Book identity uses the sidecar media ID, then exact KOReader hash,
then an explicit user link; it never guesses by title. Reading-list metadata is
available, but its members are not exposed by the current read API. Collections
and daily/weekly/streak statistics likewise have no read endpoint.

## Annotation synchronization

Annotations sync in both directions with the liseur-sync service; reading
progress remains on KOReader's built-in KOSync path. Coppice pulls annotations
when a linked book opens and from **Sync annotations now**. It pushes after an
annotation change (debounced), on document close, and on suspend. A per-book
sidecar and persistent queue retain pending edits, deletes, ID mappings, and
server revisions while offline; queued writes are retried when KOReader reports
a network connection.

Highlights preserve KOReader's complete color palette (yellow, green, blue,
pink, purple, orange, red, olive, cyan, and gray) and drawer styles (lighten,
underline, strikeout, and invert); KOReader's `underscore` is the wire
`underline`. Notes preserve their body and any locator; bookmarks carry neither
color nor style. KOReader locators restore their native positions. Readium/Liseur
locators are imported only when the excerpt and optional before/after context
produce one unique match in the same chapter or href. Ambiguous or unmatched
annotations stay in the read-only **Remote notes** list instead of being
assigned a guessed location.

Writes use `POST /v1/annotations`; pulls use
`GET /v1/works/{work_id}/annotations?include_deleted=true`, including server
tombstones; deletes use `DELETE /v1/annotations/{id}?rev={revision}`. Requests
advertise `X-Liseur-Annotation-Capabilities:
annotation-color-drawer-v1` so the extended color/style fields are returned.
Local edits and deletes use stored compare-and-set revisions. On a conflict,
the newer `client_ts` wins; a local edit newer than a server tombstone is
recreated under a new stable ID rather than reviving the deleted record.

Host checks cover bidirectional mapping, style/color fidelity, safe remote
anchoring, duplicate-pull prevention, persisted queues, deletes, and revision
conflicts. KOReader UI and device/network behavior still require the
on-device checklist below.


## Screenshots

No screenshots are included in the source archive. Before release, capture the
portrait Home, cover-grid/list-toggle, and book-detail views on the supported
KOReader device; verify that text is legible and the full-refresh page turns
remain comfortable on e-ink.

## Security and migration notes

- The start route is unauthenticated because the device has no credential yet;
  approval is still mandatory before any secret is issued.
- The six-digit code is displayed only for the five-minute window. The server
  binds polling to the nonce and returns the one-time secrets only on the first
  approved poll.
- Credential-bearing API requests stay on the configured origin, use bounded
  response sizes, and publish completed downloads only after a successful
  same-origin transfer. User-facing failures never show URLs or raw response
  bodies.
- The API key appears in the KOSync path because that protocol requires it; the
  paired polling nonce is scoped to its status request. Forgetting the pairing
  restores prior KOSync credentials when a backup exists and removes legacy
  Coppice KOSync credentials when it does not.
- Historical plugin settings and known old files are deleted explicitly during
  migration. Unknown files are not recursively deleted. No old secret is
  imported.

## Verification

Pure behavior checks cover catalog mapping, layout and paging, URL construction,
cache eviction, OPDS, bidirectional annotation/color/style mapping, queue
persistence and idempotence, edit/delete revision conflicts, exact/readium
anchoring, tombstone removal, KOSync settings, credential-lane selection, and
migration boundaries. The host browser harness exercises search submission
through the default Enter action, the live GraphQL result shape and cover grid,
downloaded Continue-reading tap/long-press behavior, and the 305-book visible-page
regression at both supported test geometries.

```sh
luajit tests/pure_checks.lua
luajit tests/browser_checks.lua
tests/static_checks.sh
for module in coppice.koplugin/*.lua; do luajit -b "$module" /dev/null; done
```

## On-device checklist

- Open a linked book and confirm the server's annotations pull once; pull again
  and verify no duplicates. Check exact KOReader x-pointer restoration and
  Readium excerpt/context anchoring in the same chapter or href.
- Confirm unsupported/ambiguous excerpts remain only in **Remote notes** and
  are not inserted at a guessed position.
- Add and recolor/restyle a highlight, add a note, and add a bookmark. Verify
  automatic push after the debounce, then repeat after document close and
  suspend. Confirm all ten colors and four styles round-trip.
- Edit and delete a previously synced annotation; verify the stored revision is
  honored. Exercise an offline edit/delete followed by reconnect and confirm
  the persisted queue drains once without losing the last edit.
- Pull an annotation from another device, then remove it remotely and reopen
  the book; the imported annotation should disappear. Confirm reading progress
  still uses KOReader's built-in KOSync.

## Layout

| Path | Responsibility |
| --- | --- |
| `coppice.koplugin/main.lua` | lifecycle, pairing UI, settings, progress, annotations |
| `coppice.koplugin/coppice_api.lua` | authenticated REST/GraphQL requests, downloads, and asset transfer |
| `coppice.koplugin/coppice_pairing.lua` | pure credential/status mapping |
| `coppice.koplugin/coppice_settings.lua` | pure persisted-setting validation |
| `coppice.koplugin/coppice_errors.lua` | safe, localized request error summaries |
| `coppice.koplugin/coppice_migration.lua` | explicit historical-file retirement |
| `coppice.koplugin/coppice_url.lua` | URL validation, encoding, and origin confinement |
| `coppice.koplugin/coppice_opds.lua` | OPDS parsing and feed-link normalization |
| `coppice.koplugin/coppice_annotations.lua` | KOReader annotation mapping and revision signatures |
| `coppice.koplugin/coppice_annotation_sync.lua` | bidirectional annotation state, queue, and reconciliation |
| `coppice.koplugin/coppice_kosync.lua` | built-in KOSync configuration |
| `coppice.koplugin/coppice_browser.lua` | cover-first browsing, details, downloads, and reading |
| `coppice.koplugin/coppice_catalog.lua` | pure catalog mapping, layout, paging, URLs, and cache eviction |
| `tests/static_checks.sh` | fails on undeclared globals, undefined `self:` methods and missing KOReader icons (device-only runtime errors) |
| `tests/pure_checks.lua` | deterministic pure behavior checks |
| `build.py`, `build.sh` | deterministic generic archive builder |

MIT License.
