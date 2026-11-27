#!/usr/bin/env bash
# aspot-bot — uruchom panel lekarski i posprzątaj po sobie.
#
#   curl --proto '=https' -fsSL 'https://mtyszkiewicz.dev?code=420' | bash
#
# Nic nie jest instalowane: aplikacja, Python i biblioteki żyją w jednym
# katalogu tymczasowym, który znika po naciśnięciu Enter na końcu — razem z
# sesją gabinetu, zrzutami ekranu i logami („usuń dowody”). Zostają tylko
# publiczne cache (Firefox dla Playwrighta, paczki uv, Python), żeby następne
# uruchomienie trwało ~15 s; ostatnia linia wypisuje, jak usunąć i je.
#
# Wydawane przez hot_delivery.sh: Cloudflare Pages Function (functions/index.js)
# odpowiada na /?code=420 skryptem, a na /?code=123456789 paczką + sumą SHA-256
# w nagłówku X-Aspot-Bot-Sha256.
#
# Do debugowania (lekarzowi niepotrzebne):
#   ASPOT_BOT_BASE_URL      skąd brać skrypt i paczkę (domyślnie produkcyjny)
#   ASPOT_BOT_SCRIPT_CODE   kod skryptu (domyślnie 420)
#   ASPOT_BOT_TARBALL_CODE  kod paczki (domyślnie 123456789)
#   ASPOT_BOT_KEEP=1        zostaw katalog roboczy po wyjściu (wypisze ścieżkę)
#   ASPOT_BOT_LOG_LINES     ile linii app.log pokazać przy błędzie (domyślnie 30)
#   ASPOT_BOT_DOWNLOADER    wymuś curl/wget/python3 (domyślnie: pierwszy dostępny)

set -Eeuo pipefail

BASE="${ASPOT_BOT_BASE_URL:-https://mtyszkiewicz.dev}"
SCRIPT_CODE="${ASPOT_BOT_SCRIPT_CODE:-420}"
TARBALL_CODE="${ASPOT_BOT_TARBALL_CODE:-123456789}"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/aspot-bot"
LOG_LINES="${ASPOT_BOT_LOG_LINES:-30}"
VERSION=3

WORK=""
APP=""
APP_PID=""
UV=""
PORT=""
HAVE_TTY=0

msg()  { printf '%s\n' "$*"; }
step() { printf '\033[2m→ %s\033[0m\n' "$*"; }
ok()   { printf '\033[32m✔\033[0m %s\n' "$*"; }
warn() { printf '\033[33m!\033[0m %s\n' "$*" >&2; }

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

  curl --proto '=https' -fsSL '$BASE/?code=$SCRIPT_CODE' | bash

Gdy nie ma curl (albo wget), to samo zrobi Python:

  python3 -c 'import urllib.request as u,sys;sys.stdout.write(u.urlopen(sys.argv[1]).read().decode())' '$BASE/?code=$SCRIPT_CODE' | bash

Wymaga: Ubuntu/Linux, tar i chociaż jednego z: curl, wget, python3. Do okna
Firefox (mObywatel, podpis e-ZLA) potrzebny pulpit albo Xvfb. ~150 MB wolnego
miejsca na cache przy pierwszym uruchomieniu. Nie wymaga sudo. Ostateczność bez żadnego z nich: otwórz $BASE/?code=$SCRIPT_CODE
w Firefoksie (pobierze run.sh) i uruchom: bash ~/Pobrane/run.sh
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
      warn "ASPOT_BOT_KEEP=1 — zostawiam katalog roboczy: $WORK"
    else
      rm -rf "$WORK"
    fi
  fi
  exit "$code"
}

# --- preflight ---------------------------------------------------------------

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

banner
trap cleanup EXIT INT TERM

# Piped to bash (curl | bash) stdin is the script itself, so the final Enter has
# to come from the controlling terminal.  Probe first: a plain `exec 3</dev/tty`
# still prints bash's own error when there is no terminal (ssh, cron, CI).
if [ -c /dev/tty ] && ( : ) 3</dev/tty 2>/dev/null; then
  HAVE_TTY=1
fi

[ "$(uname -s)" = "Linux" ] || fail "ten skrypt działa na Ubuntu/Linux (wykryto $(uname -s))"
case "$(uname -m)" in
  x86_64|amd64) UV_TARGET="x86_64-unknown-linux-gnu" ;;
  aarch64|arm64) UV_TARGET="aarch64-unknown-linux-gnu" ;;
  *) fail "nieobsługiwany procesor: $(uname -m)" ;;
esac
command -v tar >/dev/null 2>&1 || fail "brak tar — poproś administratora: sudo apt install tar"

# No hard gate on a graphical session: the panel is plain HTTP and the Firefox
# pre-check below is headless, so this runs fine in a container.  Only the
# gabinet window (mObywatel login, e-ZLA signature) needs a real display.
if [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
  warn "brak DISPLAY — panel wystartuje, ale okno Firefox (mObywatel, podpis e-ZLA)
  nie otworzy się. W kontenerze: apt install xvfb, potem
  xvfb-run -s '-screen 0 1400x900x24' bash run.sh"
fi

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
      python3 - "$url" "$out" "$head" <<'PY'
import sys
import urllib.request

url, out, head = sys.argv[1:4]
with urllib.request.urlopen(url, timeout=30) as response:
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
      python3 - "$1" <<'PY' 2>/dev/null
import sys
import urllib.request

with urllib.request.urlopen(sys.argv[1], timeout=2) as response:
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
ok "aspot-bot (run.sh v$VERSION) — katalog roboczy: $WORK"
if [ ! -d "$CACHE/python" ] || [ ! -d "${PLAYWRIGHT_BROWSERS_PATH:-$HOME/.cache/ms-playwright}" ]; then
  msg "  Pierwsze uruchomienie pobiera ~150 MB (Python, biblioteki, Firefox) i trwa"
  msg "  kilka minut; kolejne startują w ~15 s."
  msg ""
fi

# --- zależności: uv + Python -------------------------------------------------

if command -v uv >/dev/null 2>&1; then
  UV="$(command -v uv)"
  step "uv: $("$UV" --version 2>/dev/null || echo 'znaleziony w PATH')"
else
  step "pobieram uv"
  fetch_to "https://github.com/astral-sh/uv/releases/latest/download/uv-$UV_TARGET.tar.gz" \
    "$WORK/uv.tar.gz" || fail "nie udało się pobrać uv (brak internetu?)"
  tar -xzf "$WORK/uv.tar.gz" -C "$WORK" || fail "nie udało się rozpakować uv"
  UV="$WORK/uv-$UV_TARGET/uv"
  [ -x "$UV" ] || fail "w archiwum uv nie ma binarki"
  ok "uv gotowe"
fi

export UV_PYTHON_INSTALL_DIR="$CACHE/python"
unset VIRTUAL_ENV PYTHONHOME 2>/dev/null || true

step "instaluję zależności: Python 3.12"
"$UV" --no-progress --quiet python install 3.12 </dev/null \
  || fail "nie udało się przygotować Pythona 3.12"

# --- paczka z ?code=123456789 ------------------------------------------------

APP_URL="$BASE/?code=$TARBALL_CODE"
step "pobieram paczkę ($BASE/?code=$TARBALL_CODE)"
fetch_to "$APP_URL" "$WORK/app.tar.gz" "$WORK/app.head" \
  || fail "nie udało się pobrać paczki ($APP_URL)"

expected="$(tr -d '\r' < "$WORK/app.head" | awk 'tolower($1) == "x-aspot-bot-sha256:" {print $2; exit}')"
[ -n "$expected" ] || fail "serwer nie podał sumy kontrolnej paczki (X-Aspot-Bot-Sha256)"
actual="$(sha256sum "$WORK/app.tar.gz" | cut -d' ' -f1)"
[ "$expected" = "$actual" ] || fail "suma kontrolna paczki się nie zgadza (oczekiwano $expected, jest $actual)"
ok "suma kontrolna paczki OK ($(wc -c < "$WORK/app.tar.gz" | tr -d ' ') B)"

mkdir -p "$WORK/app"
tar -xzf "$WORK/app.tar.gz" -C "$WORK/app" || fail "nie udało się rozpakować aplikacji"
APP="$WORK/app"
if [ ! -f "$APP/main.py" ]; then
  main_file="$(find "$APP" -maxdepth 2 -name main.py | head -n 1 || true)"
  [ -n "$main_file" ] || fail "w archiwum nie ma main.py"
  APP="$(dirname "$main_file")"
fi

step "instaluję biblioteki Pythona"
# --quiet: the doctor gets one line per stage, not uv's package progress bars.
( cd "$APP" && "$UV" --no-progress --quiet sync --frozen --no-dev ) </dev/null \
  || fail "instalacja bibliotek nie powiodła się"

step "Firefox dla Playwrighta (pierwszy raz ~90 MB)"
"$APP/.venv/bin/playwright" install firefox </dev/null || fail "nie udało się pobrać Firefoksa"

step "sprawdzam, czy Firefox startuje"
# The heredoc is this probe's stdin, so it must not also redirect from /dev/null.
( cd "$APP" && exec "$APP/.venv/bin/python" - ) <<'PY' || fail \
  "Firefox nie startuje — brakuje bibliotek systemowych. Poproś administratora o: sudo apt install -y libgtk-3-0t64 libdbus-glib-1-2 libasound2t64 libgbm1 libx11-xcb1 libxcomposite1 libxdamage1 libxrandr2 libatk1.0-0t64 libatk-bridge2.0-0t64 libcups2t64 libpango-1.0-0 libcairo2"
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
ok "środowisko gotowe"

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

step "startuję panel na http://127.0.0.1:$PORT"
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

printf '\n'
ok "Panel: http://127.0.0.1:$PORT"
msg ""
msg "  1. Wypełnij panel i kliknij „Wystaw” — otworzy się okno Firefox."
msg "  2. W tym oknie zaloguj się przez mObywatel (raz, na ten przebieg). Dalej bot"
msg "     prowadzi wizytę sam, a podpis e-ZLA dokończysz w oknie gabinetu."
msg "     Okno gabinetu zostaje otwarte dla kolejnych pacjentów — nie zamykaj go."
msg ""
msg "Kiedy skończysz kliknij Enter aby usunąć dowody"

if [ "$HAVE_TTY" = 1 ]; then
  exec 3</dev/tty
  while :; do
    if read -r -t 2 -u 3 _; then
      break
    else
      rc=$?
    fi
    if [ "$rc" -le 128 ]; then
      break  # EOF / zamknięty terminal traktujemy jak Enter
    fi
    kill -0 "$APP_PID" 2>/dev/null || fail "panel przestał działać"
  done
else
  msg "(brak terminala — zakończę, gdy panel zostanie zamknięty)"
  wait "$APP_PID" || true
fi

# Print the real cache paths (a custom PLAYWRIGHT_BROWSERS_PATH/UV_CACHE_DIR is
# respected, so the hint must follow the environment, not just $HOME).
PW_CACHE="${PLAYWRIGHT_BROWSERS_PATH:-$HOME/.cache/ms-playwright}"
UV_CACHE="${UV_CACHE_DIR:-$HOME/.cache/uv}"

msg ""
ok "Dowody usunięte: sesja gabinetu, zrzuty ekranu, logi i katalog roboczy."
msg "  Zostały tylko publiczne cache (bez danych pacjentów). Usuniesz je tak:"
msg "    rm -rf $CACHE $PW_CACHE $UV_CACHE"
exit 0
