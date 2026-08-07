#!/usr/bin/env bash
# Headless-browser helper (Playwright + Chromium) for visually/structurally
# inspecting a deployed environment — e.g. this project's "dev" or "ralph"
# k8s deployments (see PLANE.md's browser step for known URLs). Lets the
# agent confirm a UI change actually renders, not just that the code
# compiles or the tests pass.
#
# Usage:
#   browser.sh html <url> [out_file]        # rendered HTML after JS runs, to stdout or out_file
#   browser.sh screenshot <url> <out_file>  # full-page PNG screenshot to out_file
#
# Requires Node + the "playwright" npm package with Chromium downloaded
# (`npm install playwright && npx playwright install --with-deps chromium`),
# set up once in this directory (node_modules resolves relative to this
# script's own location, not the caller's cwd). If this fails because
# Playwright/Chromium is not installed, that is an infrastructure problem
# (see PLANE.md's Communication rules), not something to work around.

set -euo pipefail

CMD="${1:?usage: browser.sh <html|screenshot> <url> [out_file]}"
URL="${2:?url required}"
OUT="${3:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "$CMD" in
    html|screenshot) ;;
    *) echo "ERROR: unknown command \"$CMD\"; use html or screenshot" >&2; exit 1 ;;
esac

if [ "$CMD" = "screenshot" ] && [ -z "$OUT" ]; then
    echo "ERROR: out_file required for screenshot" >&2
    exit 1
fi

DRIVER="$(mktemp -p "$SCRIPT_DIR" --suffix=.mjs)"
trap 'rm -f "$DRIVER"' EXIT

cat > "$DRIVER" <<'EOF'
import { chromium } from 'playwright';

const [, , mode, url, out] = process.argv;
const browser = await chromium.launch();
const page = await browser.newPage();
await page.goto(url, { waitUntil: 'networkidle' });

if (mode === 'html') {
    const html = await page.content();
    if (out) {
        const fs = await import('node:fs');
        fs.writeFileSync(out, html);
    } else {
        process.stdout.write(html);
    }
} else {
    await page.screenshot({ path: out, fullPage: true });
}

await browser.close();
EOF

(cd "$SCRIPT_DIR" && node "$DRIVER" "$CMD" "$URL" "$OUT")
