#!/usr/bin/env bash
# aspot-bot — start the doctor's panel, then clean up after yourself.
#
#   wget -qO- 'https://mtyszkiewicz.dev?code=420' | bash
#
# Nothing is installed: the app, Python and its libraries live in one temporary
# directory that disappears when Enter is pressed at the end -- together with the
# gabinet session, screenshots and logs ("clear the session").  Only public
# caches survive (Playwright's Firefox, uv packages, the Python build) so the
# next start takes ~15 s.
#
# Published by hot_delivery.sh: the Cloudflare Pages Function answers /?code=420
# with this script and /?code=123456789 with the tarball plus its SHA-256 in the
# X-Aspot-Bot-Sha256 header.
#
# Debug knobs (the doctor never needs them):
#   ASPOT_BOT_BASE_URL      where the script and the tarball come from
#   ASPOT_BOT_SCRIPT_CODE   script code (default 420)
#   ASPOT_BOT_TARBALL_CODE  tarball code (default 123456789)
#   ASPOT_BOT_VERBOSE=1     full stage log (versions, checksums, paths)
#   ASPOT_BOT_KEEP=1        keep the scratch dir after exit (prints its path)
#   ASPOT_BOT_LOG_LINES     app.log lines to show on failure (default 30)
#   ASPOT_BOT_DOWNLOADER    force curl/wget/python3 (default: first available)
#   --with-deps             (flag) as root: install the system libraries
#
set -Eeuo pipefail

BASE="${ASPOT_BOT_BASE_URL:-https://mtyszkiewicz.dev}"
SCRIPT_CODE="${ASPOT_BOT_SCRIPT_CODE:-420}"
TARBALL_CODE="${ASPOT_BOT_TARBALL_CODE:-123456789}"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/aspot-bot"
LOG_LINES="${ASPOT_BOT_LOG_LINES:-30}"
VERSION=14

WORK=""
APP=""
APP_PID=""
UV=""
PORT=""
HAVE_TTY=0

# The doctor reads this screen.  Default output is: the logo, ONE status line
# that keeps changing while things download, the panel URL, the Enter prompt and
# one closing line.  Everything else (stage names, versions, checksums, cache
# paths) is dev output behind ASPOT_BOT_VERBOSE=1 -- and failures stay verbose,
# because then the detail is the point.
VERBOSE="${ASPOT_BOT_VERBOSE:-0}"
DIRTY=0

step() { [ "$VERBOSE" = 1 ] && printf '  %s\n' "$*"; return 0; }
ok()   { [ "$VERBOSE" = 1 ] && printf '  ok: %s\n' "$*"; return 0; }
say()  { printf '%s\n' "$*"; }
warn() { printf '! %s\n' "$*" >&2; }

# progress <text> — the single line the doctor sees; rewritten in place on a tty.
progress() {
  if [ "$VERBOSE" = 1 ] || [ ! -t 1 ]; then
    printf '  %s\n' "$*"
    return 0
  fi
  printf '\r  %-74s' "$*"
  DIRTY=1
}

# progress_commit — stop rewriting and keep the current status line on screen.
progress_commit() {
  if [ "$DIRTY" = 1 ]; then
    printf '\n'
    DIRTY=0
  fi
  return 0
}

banner() {
  local cols="" utf8=0
  cols="$(tput cols 2>/dev/null || echo 80)"
  case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
    *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*) utf8=1 ;;
  esac
  # The art is 78 columns and uses box drawing: only draw it where it fits.
  if [ -t 1 ] && [ "${cols:-80}" -ge 80 ] && [ "$utf8" = 1 ]; then
    cat <<'ART'

                                                     ...
                                          ;|!        !║|                  ;|!
   ':!!:;.  '::!:;.  ':;':!:'    ':!::'  ;│║│:.      !║|;:!:'    ;:!::.  ;│║│:.
  ;│|;;|║| ;║║;':|!  !║║|;:│║! .│║|::│║| ;│║│:.      !║║!;:║║: '│║|::│║| ;│║│:.
  .;!||│║│ .|║║│|!;  !║│   ;║║ !║│   .║║; |║!  ;││││.!║|   :║│ |║|   '║║; |║!
  │║!. !║│ '::.';║║: !║║'  !║│ :║║'  :║║. |║|  .;;;;.!║│'  |║| :║│'  :║║. |║!
  ;│║│||║│..!│││││!. !║│|│║║!.  ;|║║║│!'  ;║║║;      !║||│║│!.  ;|║║║│!.  :║║║;
                     !║│
                     ;!:

ART
  else
    printf '\n  A S P O T - B O T — panel receptowy\n\n'
  fi
}

usage() {
  banner
  cat <<EOF
aspot-bot — uruchamia panel lekarski bez instalowania czegokolwiek.

  wget -qO- '$BASE/?code=$SCRIPT_CODE' | bash

(na Ubuntu Desktop wget jest zawsze, curl bywa że nie ma)

To samo zrobi curl albo Python:

  curl --proto '=https' -fsSL '$BASE/?code=$SCRIPT_CODE' | bash
  python3 -c 'import urllib.request as u,sys;r=u.Request(sys.argv[1],headers={"User-Agent":"aspot-bot"});sys.stdout.write(u.urlopen(r).read().decode())' '$BASE/?code=$SCRIPT_CODE' | bash

Wymaga: Linux, tar i chociaż jednego z: wget, curl, python3. Do okna Firefox
(mObywatel, podpis e-ZLA) potrzebny pulpit albo Xvfb. ~150 MB cache przy
pierwszym uruchomieniu. Nie wymaga sudo.

W kontenerze (jako root) brakujące biblioteki systemowe doinstaluje:

  wget -qO- '$BASE/?code=$SCRIPT_CODE' | bash -s -- --with-deps

Ostateczność bez żadnego z nich: otwórz $BASE/?code=$SCRIPT_CODE w Firefoksie
(pobierze run.sh) i uruchom: bash ~/Pobrane/run.sh
EOF
}

fail() {
  printf '\033[31m✖\033[0m %s\n' "$*" >&2
  if [ -n "$WORK" ] && [ -s "$WORK/app.log" ]; then
    warn "ostatnie linie logu:"
    tail -n "$LOG_LINES" "$WORK/app.log" >&2 || true
  fi
  exit 1
}

# Kill the app and everything it spawned (Firefox is a grandchild), then delete
# the scratch dir: that dir *is* the evidence — session.json, run artefacts, logs.
kill_tree() {
  local pid=$1 child
  for child in $(pgrep -P "$pid" 2>/dev/null || true); do
    kill_tree "$child"
  done
  kill -TERM "$pid" 2>/dev/null || true
}

cleanup() {
  local code=$?
  trap - EXIT INT TERM
  if [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null; then
    kill_tree "$APP_PID"
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      kill -0 "$APP_PID" 2>/dev/null || break
      sleep 0.2
    done
    kill -KILL "$APP_PID" 2>/dev/null || true
  fi
  if [ -n "$WORK" ] && [ -d "$WORK" ]; then
    if [ "${ASPOT_BOT_KEEP:-0}" = "1" ]; then
      warn "ASPOT_BOT_KEEP=1 — keeping the scratch dir: $WORK"
    else
      rm -rf "$WORK"
    fi
  fi
  exit "$code"
}

# --- preflight ---------------------------------------------------------------

WITH_DEPS=0
for arg in "$@"; do
  case "$arg" in
    -h|--help) usage; exit 0 ;;
    # Containers/minimal images lack the GTK/alsa/gbm/libatomic libs a desktop
    # has.  As root, install them ourselves instead of failing (opt-in only:
    # the doctor's machine must never be touched).
    --with-deps) WITH_DEPS=1 ;;
    *) fail "nieznany argument: $arg (użyj --help)" ;;
  esac
done

banner
trap cleanup EXIT INT TERM

# Piped to bash (curl | bash) stdin is the script itself, so the final Enter has
# to come from the controlling terminal.  Probe first: a plain `exec 3</dev/tty`
# still prints bash's own error when there is no terminal (ssh, cron, CI).
if [ -c /dev/tty ] && ( : ) 2>/dev/null 3</dev/tty; then
  HAVE_TTY=1
fi

[ "$(uname -s)" = "Linux" ] || fail "ten skrypt działa na Linux (wykryto $(uname -s))"
case "$(uname -m)" in
  x86_64|amd64) UV_TARGET="x86_64-unknown-linux-gnu" ;;
  aarch64|arm64) UV_TARGET="aarch64-unknown-linux-gnu" ;;
  *) fail "nieobsługiwany procesor: $(uname -m)" ;;
esac
command -v tar >/dev/null 2>&1 || fail "brak tar — poproś administratora: sudo apt install tar"

if [ "$WITH_DEPS" = 1 ]; then
  [ "$(id -u)" = 0 ] || fail "--with-deps wymaga roota (w kontenerze: docker run -it --name … ubuntu:24.04 bash)"
  command -v apt-get >/dev/null 2>&1 || fail "--with-deps obsługuje tylko apt (Ubuntu/Debian)"
fi

# A display is only needed once a basket starts (gabinet's window); the panel is
# plain HTTP and the Firefox pre-check is headless, so nothing is said here.

# Ubuntu desktops ship curl, minimal images often have only wget or python3, and
# the doctor's one-liner cannot assume any of them -- so every fetch (uv, the
# tarball, the readiness probes) goes through one layer that picks whichever
# downloader exists.  ASPOT_BOT_DOWNLOADER forces one, for testing.
PINS_HTTPS=0
case "$BASE" in https://*) PINS_HTTPS=1 ;; esac

DOWNLOADER="${ASPOT_BOT_DOWNLOADER:-}"
if [ -z "$DOWNLOADER" ]; then
  if command -v curl >/dev/null 2>&1; then DOWNLOADER=curl
  elif command -v wget >/dev/null 2>&1; then DOWNLOADER=wget
  elif command -v python3 >/dev/null 2>&1; then DOWNLOADER=python3
  fi
fi
case "$DOWNLOADER" in
  curl|wget|python3) ;;
  *)
    DOWNLOADER=""
    ;;
esac
if [ -z "$DOWNLOADER" ] || ! command -v "$DOWNLOADER" >/dev/null 2>&1; then
  fail "brak curl, wget i python3 — nie mam czym pobrać aplikacji.
  Poproś administratora o: sudo apt install curl
  Albo otwórz $BASE/?code=$SCRIPT_CODE w Firefoksie (pobierze run.sh) i uruchom:
    bash ~/Pobrane/run.sh"
fi

# fetch_to <url> <out-file> [<header-file>] — download a URL, optionally saving
# the response headers (the tarball's sha256 travels in X-Aspot-Bot-Sha256).
fetch_to() {
  local url=$1 out=$2 head=${3:-}
  case "$DOWNLOADER" in
    curl)
      local opts=(-fsSL --retry 3 --connect-timeout 15)
      if [ "$PINS_HTTPS" = 1 ]; then
        # Without --proto a bare `mtyszkiewicz.dev?code=420` starts on http:// and
        # only upgrades later -- the first hop could already be an attacker.
        opts=(--proto '=https' "${opts[@]}")
      fi
      if [ -n "$head" ]; then
        curl "${opts[@]}" -D "$head" -o "$out" "$url"
      else
        curl "${opts[@]}" -o "$out" "$url"
      fi
      ;;
    wget)
      # -S prints the response headers; -q keeps the progress bar out of them.
      if [ -n "$head" ]; then
        wget -q -S --timeout=30 --tries=3 -O "$out" "$url" 2>"$head"
      else
        wget -q --timeout=30 --tries=3 -O "$out" "$url"
      fi
      ;;
    python3)
      # The UA is not cosmetic: Cloudflare 403s Python's default "Python-urllib/…".
      python3 - "$url" "$out" "$head" "aspot-bot/$VERSION" <<'PY'
import sys
import urllib.request

url, out, head, agent = sys.argv[1:5]
request = urllib.request.Request(url, headers={"User-Agent": agent})
with urllib.request.urlopen(request, timeout=30) as response:
    body = response.read()
    if head:
        lines = [f"HTTP/1.1 {response.status} {response.reason}"]
        lines += [f"{key}: {value}" for key, value in response.headers.items()]
        with open(head, "w", encoding="utf-8") as handle:
            handle.write("\r\n".join(lines) + "\r\n")
with open(out, "wb") as handle:
    handle.write(body)
PY
      ;;
  esac
}

# probe_http <url> — 0 when the URL answers, non-zero otherwise.
probe_http() {
  case "$DOWNLOADER" in
    curl) curl -fsS --max-time 2 -o /dev/null "$1" 2>/dev/null ;;
    wget) wget -q --timeout=2 --spider "$1" 2>/dev/null ;;
    python3)
      python3 - "$1" "aspot-bot/$VERSION" <<'PY' 2>/dev/null
import sys
import urllib.request

request = urllib.request.Request(sys.argv[1], headers={"User-Agent": sys.argv[2]})
with urllib.request.urlopen(request, timeout=2) as response:
    response.read(1)
PY
      ;;
    *) return 1 ;;
  esac
}

mkdir -p "$CACHE"
# Sweep scratch dirs from a run that was SIGKILLed (cleanup never ran) so old
# evidence cannot pile up. A concurrent doctor's run is younger than a day.
find "$CACHE" -mindepth 1 -maxdepth 1 -name 'run-*' -type d -mtime +1 \
  -exec rm -rf {} + 2>/dev/null || true

WORK="$(mktemp -d "$CACHE/run-XXXXXX")"
step "run.sh v$VERSION, scratch dir: $WORK"
if [ ! -d "$CACHE/python" ] || [ ! -d "${PLAYWRIGHT_BROWSERS_PATH:-$HOME/.cache/ms-playwright}" ]; then
  progress "przygotowuję środowisko (pierwsze uruchomienie ~2 minuty)…"
else
  progress "przygotowuję środowisko…"
fi

# --- dependencies: uv + Python -------------------------------------------------

if command -v uv >/dev/null 2>&1; then
  UV="$(command -v uv)"
  step "uv: $("$UV" --version 2>/dev/null || echo 'znaleziony w PATH')"
else
  progress "pobieram uv…"
  fetch_to "https://github.com/astral-sh/uv/releases/latest/download/uv-$UV_TARGET.tar.gz" \
    "$WORK/uv.tar.gz" || fail "nie udało się pobrać uv (brak internetu?)"
  tar -xzf "$WORK/uv.tar.gz" -C "$WORK" || fail "nie udało się rozpakować uv"
  UV="$WORK/uv-$UV_TARGET/uv"
  [ -x "$UV" ] || fail "w archiwum uv nie ma binarki"
  ok "uv gotowe"
fi

export UV_PYTHON_INSTALL_DIR="$CACHE/python"
unset VIRTUAL_ENV PYTHONHOME 2>/dev/null || true

progress "instaluję Pythona…"
"$UV" --no-progress --quiet python install 3.12 </dev/null \
  || fail "nie udało się przygotować Pythona 3.12"

# --- app tarball from ?code=123456789 ------------------------------------------------

APP_URL="$BASE/?code=$TARBALL_CODE"
progress "pobieram aplikację…"
fetch_to "$APP_URL" "$WORK/app.tar.gz" "$WORK/app.head" \
  || fail "nie udało się pobrać paczki ($APP_URL)"

expected="$(tr -d '\r' < "$WORK/app.head" | awk 'tolower($1) == "x-aspot-bot-sha256:" {print $2; exit}')"
[ -n "$expected" ] || fail "serwer nie podał sumy kontrolnej paczki (X-Aspot-Bot-Sha256)"
actual="$(sha256sum "$WORK/app.tar.gz" | cut -d' ' -f1)"
[ "$expected" = "$actual" ] || fail "suma kontrolna paczki się nie zgadza (oczekiwano $expected, jest $actual)"
ok "tarball checksum OK ($(wc -c < "$WORK/app.tar.gz" | tr -d ' ') B)"

mkdir -p "$WORK/app"
tar -xzf "$WORK/app.tar.gz" -C "$WORK/app" || fail "nie udało się rozpakować aplikacji"
APP="$WORK/app"
if [ ! -f "$APP/main.py" ]; then
  main_file="$(find "$APP" -maxdepth 2 -name main.py | head -n 1 || true)"
  [ -n "$main_file" ] || fail "w archiwum nie ma main.py"
  APP="$(dirname "$main_file")"
fi

progress "instaluję biblioteki…"
# --quiet: the doctor gets one line per stage, not uv's package progress bars.
( cd "$APP" && "$UV" --no-progress --quiet sync --frozen --no-dev ) </dev/null \
  || fail "instalacja bibliotek nie powiodła się"

if [ "$WITH_DEPS" = 1 ]; then
  progress "doinstalowuję biblioteki systemowe…"
  # libatomic1 first: without it Playwright's own node cannot even start, so
  # `playwright install-deps` itself would fail.
  apt-get update -qq </dev/null && apt-get install -y -qq libatomic1 </dev/null \
    || fail "apt-get nie powiodło się"
  "$APP/.venv/bin/playwright" install-deps firefox </dev/null \
    || fail "playwright install-deps nie powiodło się"
  ok "biblioteki systemowe doinstalowane"
fi

# Playwright drives the browser with its own bundled node.  On a minimal image
# that node fails first ("libatomic.so.1: cannot open shared object file"), which
# reads like a download error but is a missing system package -- and it would
# cost 90 MB of browser download to discover.  Check the driver before that.
progress "sprawdzam biblioteki systemowe…"
if ! "$APP/.venv/bin/playwright" --version >"$WORK/pw.log" 2>&1 </dev/null; then
  missing="$(grep -oE 'lib[a-zA-Z0-9._+-]+\.so(\.[0-9]+)*' "$WORK/pw.log" | head -n 1)"
  fail "brakuje bibliotek systemowych${missing:+ ($missing)} — to nie jest problem z paczką.
  Minimalny obraz Ubuntu/kontener nie ma bibliotek, które Ubuntu z pulpitem ma domyślnie.
  Jako root uruchom ponownie z --with-deps (doinstaluje libatomic1 i resztę):
    wget -qO- '$BASE/?code=$SCRIPT_CODE' | bash -s -- --with-deps
  Mając sudo, możesz to zrobić sam: apt-get install -y libatomic1
  i potem playwright install-deps firefox (obraz Playwrighta już je ma)."
fi

progress "pobieram Firefoksa…"
if ! "$APP/.venv/bin/playwright" install firefox >"$WORK/pw.log" 2>&1 </dev/null; then
  missing="$(grep -oE 'lib[a-zA-Z0-9._+-]+\.so(\.[0-9]+)*' "$WORK/pw.log" | head -n 1)"
  if [ -n "$missing" ]; then
    fail "brakuje bibliotek systemowych${missing:+ ($missing)} — to nie jest problem z paczką.
  Jako root: uruchom ponownie z --with-deps (albo apt-get install -y libatomic1
  i playwright install-deps firefox)."
  fi
  fail "nie udało się pobrać Firefoksa"
fi

progress "sprawdzam Firefoksa…"
# The heredoc is this probe's stdin, so it must not also redirect from /dev/null.
( cd "$APP" && exec "$APP/.venv/bin/python" - ) <<'PY' || fail \
  "Firefox nie startuje — brakuje bibliotek systemowych. Poproś administratora o: sudo apt install -y libatomic1 libgtk-3-0t64 libdbus-glib-1-2 libasound2t64 libgbm1 libx11-xcb1 libxcomposite1 libxdamage1 libxrandr2 libatk1.0-0t64 libatk-bridge2.0-0t64 libcups2t64 libpango-1.0-0 libcairo2"
import asyncio
import sys

from playwright.async_api import async_playwright


async def main() -> None:
    async with async_playwright() as playwright:
        browser = await playwright.firefox.launch(headless=True)
        await browser.close()


try:
    asyncio.run(main())
except Exception as error:  # noqa: BLE001 - any launch failure is the same to the doctor
    print(f"{error}", file=sys.stderr)
    sys.exit(1)
PY
ok "environment ready"

# --- start panelu ------------------------------------------------------------

pick_port() {
  local p
  for p in $(seq 8000 8010); do
    if ! probe_http "http://127.0.0.1:$p/"; then
      printf '%s' "$p"
      return 0
    fi
  done
  printf '8000'
}

PORT="$(pick_port)"
# Everything the app writes about patients (session.json, runs/*.png, run.log)
# goes into the scratch dir, so deleting it is enough — ~/.local/state is untouched.
export XDG_STATE_HOME="$WORK/state"
mkdir -p "$XDG_STATE_HOME"

progress "startuję panel…"
# 0 = the gabinet window never closes on idle: only this script closes it.
"$APP/.venv/bin/python" "$APP/main.py" --port "$PORT" --browser-idle 0 \
  >"$WORK/app.log" 2>&1 </dev/null &
APP_PID=$!

ready=0
for _ in $(seq 1 120); do
  if probe_http "http://127.0.0.1:$PORT/"; then
    ready=1
    break
  fi
  kill -0 "$APP_PID" 2>/dev/null || fail "panel zakończył pracę przy starcie"
  sleep 1
done
[ "$ready" = 1 ] || fail "panel nie odpowiedział w 120 s"

open_browser() {
  local url=$1
  if command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$url" >/dev/null 2>&1 </dev/null &
  elif command -v gio >/dev/null 2>&1; then
    gio open "$url" >/dev/null 2>&1 </dev/null &
  elif command -v sensible-browser >/dev/null 2>&1; then
    sensible-browser "$url" >/dev/null 2>&1 </dev/null &
  else
    warn "nie umiem otworzyć przeglądarki — otwórz ręcznie: $url"
  fi
}

open_browser "http://127.0.0.1:$PORT/"

# "startuję panel…" morphs into the URL: same line, nothing printed in between
# (one stray newline here and the URL lands on a line of its own).
progress "Panel: http://127.0.0.1:$PORT"
progress_commit
say ""
say "  Naciśnij Enter aby wyczyścić sesję"

if [ "$HAVE_TTY" = 1 ]; then
  exec 3</dev/tty
  while :; do
    if read -r -t 2 -u 3 _; then
      break
    else
      rc=$?
    fi
    if [ "$rc" -le 128 ]; then
      break  # EOF / a closed terminal counts as Enter
    fi
    kill -0 "$APP_PID" 2>/dev/null || fail "panel przestał działać"
  done
else
  step "no terminal — I will finish when the panel exits"
  wait "$APP_PID" || true
fi

# Cache paths are dev detail; a custom PLAYWRIGHT_BROWSERS_PATH/UV_CACHE_DIR is
# respected, so the hint follows the environment instead of assuming $HOME.
step "cache: $CACHE ${PLAYWRIGHT_BROWSERS_PATH:-$HOME/.cache/ms-playwright} ${UV_CACHE_DIR:-$HOME/.cache/uv}"

say ""
say "  Gotowe."
exit 0
