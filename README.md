# PeriPage A6 web editor

A single-file editor that composes a receipt in the browser and prints it straight to a
PeriPage thermal printer over **Web Bluetooth**. No server, no app, no driver.

    ./start.sh          # http://localhost:8765
    npm run deploy      # → https://peripage.baln.me

`file://` will not work — Chrome only exposes `navigator.bluetooth` on `https://` or
`http://localhost`. That is also why the Cloudflare deploy matters: it is the only way to
drive the printer from a phone, since a LAN address like `http://192.168.1.5:8765` is not a
secure context and the browser will hide Bluetooth entirely.

## Deploying to Cloudflare

Static assets on a Worker, configured in `wrangler.jsonc`. There is no server-side code;
the Worker only serves `public/`.

    npx wrangler login      # once, opens a browser
    npm run deploy

`npx wrangler deploy --dry-run` validates the config without touching the account.

### Custom domains

Live at **https://peripage.baln.me**, with the original
`peripage-editor.<subdomain>.workers.dev` URL still working alongside it.

Domains are declared in `wrangler.jsonc` under `routes` with `custom_domain: true`.
Cloudflare creates the DNS record and issues the certificate itself.

One trap worth knowing: **adding any route silently disables workers.dev** unless you also
set `"workers_dev": true`. The first deploy after adding a custom domain took the old URL
offline with only a warning, so that flag is now explicit in the config.

To add another domain, the zone must already be in the same Cloudflare account, otherwise
the deploy fails with `Can't infer zone from route [code: 10082]`. For a domain registered
elsewhere:

1. Cloudflare dashboard → **Add a site** → enter the domain.
2. Replace the registrar's nameservers with the Cloudflare pair it gives you.
3. Wait for the zone to go active, usually minutes.
4. Add the pattern to `routes` in `wrangler.jsonc` and deploy.

### Continuous deployment

Pushing to `main` deploys, via `.github/workflows/deploy.yml`. Every push and pull request
first runs a verify job that extracts the inline script from `public/index.html` and parses
it with `node --check`, then validates the Worker config with a dry run. The whole app is one
HTML file with a large inline script, so a syntax error would otherwise deploy cleanly and
only fail in the browser.

Two repository secrets are required. Create a Cloudflare API token at
**dash.cloudflare.com/profile/api-tokens** using the *Edit Cloudflare Workers* template, then:

    gh secret set CLOUDFLARE_API_TOKEN     # paste the token when prompted
    gh secret set CLOUDFLARE_ACCOUNT_ID    # paste your account id

Both commands prompt for the value, so nothing sensitive lands in your shell history. Until
they are set, the deploy job finishes green with a warning instead of failing, so the repo is
never in a broken-looking state. Local `npm run deploy` keeps working regardless.
The site is public once deployed. It holds no secrets and no printer data — layouts live
only in the browser's `localStorage` — but put Cloudflare Access in front of it if you would
rather it not be world-readable.

## Blocks

Text (font, size, weight, alignment, tracking, line height, inverted white-on-black),
image, QR code, barcode, divider, spacer and **gift tag**.

**Gift tag** is a framed name card for presents: a To line, a message, a From line, an
ornament, and a border. Twelve borders in two moods — classy (single, double, thick + thin,
dotted, deco corners) and funky (dashed, ticket stub with punched notches, scallops, zigzag,
wave, stars). Borders are painted as geometry directly on the dot grid rather than assembled
from font glyphs, so they stay sharp at 203 dpi and scale with the border weight. Type
hierarchy is derived from one size control: labels, names and message sizes are computed
from it so a tag stays balanced whatever you set.

**Fonts.** 32 faces in eight groups: heavy display, funky, pixel and retro, handwriting,
script, typewriter, elegant, plus the system defaults. Pixel faces such as Press Start 2P
and Silkscreen are a natural fit for a 203 dpi head, since their grid lands on whole dots.
Webfonts are loaded through the CSS Font Loading API *before* the canvas draws — a face that
has not arrived yet renders as a silent fallback and would bake the wrong glyphs into the
raster.

**Emoji.** A searchable picker with nine categories inserts at the caret. Emoji are rendered
through **Noto Emoji**, the monochrome face, not the colour one. This matters: colour emoji
thresholded to 1-bit collapse into unreadable blobs, whereas the monochrome glyphs are line
art that prints cleanly. The picker grid itself uses the same face, so what you pick is what
prints. Blocks start collapsed as one-line rows, so a long document stays scannable and unwanted
blocks are easy to spot and delete. A block you have just added opens automatically. Drag
the grip at the left of any row to reorder, or use the arrow buttons for precision.

Reordering uses pointer events rather than HTML5 drag-and-drop, because HTML5 dragging never
fires on a touch screen and this page is meant to work from a phone. The list auto-scrolls
when you drag near its top or bottom edge. Save/load the
layout to `localStorage`, export the composition as PNG.

Everything is composited to a 1-bit buffer at the printer's native resolution, so the
on-screen preview is exactly the dot pattern that gets sent.

- **Text, QR, barcode, rules** are hard-thresholded, so they stay crisp.
- **Images** get their own halftone: Floyd–Steinberg, Atkinson, ordered 8×8 Bayer, or a
  plain threshold, with brightness/contrast/invert.
- **QR codes** snap to an integer number of printer dots per module and are centred on
  the dot grid, which matters for scan reliability on 203 dpi paper.

## Wire protocol

Raster data is standard ESC/POS `GS v 0`, wrapped in PeriPage's own reset and density
commands. Derived from `bitrate16/peripage-python`.

| Purpose            | Bytes                                                   |
|--------------------|---------------------------------------------------------|
| Reset              | `10 ff fe 01` + twelve `00`                              |
| Darkness           | `10 ff 10 00 0n`  (n = 0 light, 1 normal, 2 dark)        |
| Raster block       | `1d 76 30 00 xL xH yL yH` + rows                         |
| Feed paper         | `1b 4a nn`  (nn = dot rows)                              |

`xL/xH` is bytes per row (48 for a 384-dot A6), `yL/yH` is the row count in that block,
capped at 255. Rows are MSB-first, 1 = black dot.

Framing follows the reference driver exactly, which matters more than it looks:

- a **reset before every raster block**, not once per job;
- in the default **row by row** transfer mode, one write per row, so a write never
  straddles a row boundary. The reference relies on this and packet-based links do not
  forgive it the way a stream socket would. **Bulk packets** mode streams the whole block
  instead, which is faster where the printer tolerates it.

A verified transcript for three rows per block looks like:

    10ff100001                        density
    10fffe01 000000000000000000000000 reset
    1d76300030000300                  block: 48 bytes/row, 3 rows
    <48 bytes> <48 bytes> <48 bytes>  one write per row
    …                                 reset + preamble + rows, per block
    1b4a50                            feed

## When it connects but nothing prints

Writing to the wrong characteristic almost always succeeds silently, so the log cannot
tell you it went nowhere. Press **Probe every characteristic**. It prints a numbered line
through each writable characteristic in turn. Whichever number appears on paper identifies
the right one, which you then select from the dropdown.

Auto-selection scores candidates rather than taking the first match, strongly preferring
known printer services and refusing to land on housekeeping services like battery or
device information. If nothing scores, the log says so instead of pretending.

## Connecting

Press **Connect**. The app enumerates every GATT service it is allowed to see, logs each
characteristic with its properties, auto-selects a known write characteristic
(`ff02`, `2af1`, `ae01`, Nordic UART, Microchip transparent UART…) and subscribes to a
notify characteristic if one exists. If printing does nothing, pick a different write
characteristic from the dropdown — the log shows what the printer actually offers.

Switch the device filter to **All Bluetooth devices** if the printer does not advertise a
`PeriPage`/`PPG` name prefix.

### If no writable characteristic appears

Some PeriPage units expose only Bluetooth Classic SPP/RFCOMM. Web Bluetooth speaks GATT
only and cannot reach those, and no browser workaround exists. In that case the printer
needs a native bridge instead.

## Browser support

| Platform                | Status                                                          |
|-------------------------|-----------------------------------------------------------------|
| Chrome / Edge, Windows, macOS | Works out of the box                                      |
| Chrome, Android         | Works — the natural pairing for a pocket printer, but the page must be on HTTPS |
| Chrome, Linux           | Works on this desktop (verified, adapter present). Older builds or a distro without BlueZ 5.41+ may need `chrome://flags/#enable-experimental-web-platform-features` |
| Safari, Firefox         | No Web Bluetooth at all                                          |
