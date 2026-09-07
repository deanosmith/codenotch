#!/bin/bash
# Read-only reconnaissance for a GitHub Copilot (VS Code) provider.
#
# Never prints a token. Reports where a session lives so CopilotCredentials
# can be written against this Mac rather than against a guess.
#
# What the first run established, and why this script no longer guesses:
#   * VS Code Stable 1.136 stores the GitHub session as
#     secret://{"extensionId":"vscode.github-authentication","key":"github.auth"}
#     in state.vscdb — a Chromium v10 blob, not a keytar item.
#   * There is no vscodevscode.github-authentication keychain entry.
#   * The encryption password is Code Safe Storage / Code Key.
#   * ~/.config/github-copilot does not exist on a Chat-only install.
#   * GET /copilot_internal/user is the dashboard: quota_snapshots with
#     percent_remaining, copilot_plan, quota_reset_date_utc.
set -uo pipefail

say() { printf '\n\033[1m%s\n\033[0m' "$1"; }

CODE_SUPPORT="$HOME/Library/Application Support/Code"
INSIDERS_SUPPORT="$HOME/Library/Application Support/Code - Insiders"
COPILOT_CONFIG="$HOME/.config/github-copilot"

inspect_app() {
  local name="$1" path="$2"
  if [ -d "$path" ]; then
    local version
    version=$(defaults read "$path/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "?")
    local bundle
    bundle=$(defaults read "$path/Contents/Info.plist" CFBundleIdentifier 2>/dev/null || echo "?")
    echo "  $name: $version ($bundle)"
  else
    echo "  $name: not in /Applications"
  fi
}

inspect_store() {
  local label="$1" dir="$2"
  local db="$dir/User/globalStorage/state.vscdb"
  echo "  $label"
  if [ ! -d "$dir" ]; then
    echo "    no Application Support folder"
    return
  fi
  echo "    support dir exists"
  if [ ! -f "$db" ]; then
    echo "    no state.vscdb"
    return
  fi
  echo "    state.vscdb present ($(du -h "$db" | awk '{print $1}'))"

  # Key names only. Values of secret:// rows are encrypted blobs.
  sqlite3 "$db" "SELECT key FROM ItemTable WHERE key LIKE '%github%' OR key LIKE '%copilot%' OR key LIKE 'secret://%';" 2>/dev/null \
    | sed 's/^/    key /' | head -80

  # Non-secret identity caches VS Code sometimes keeps in plaintext.
  sqlite3 "$db" "SELECT key FROM ItemTable WHERE key LIKE '%github%' AND key NOT LIKE 'secret://%';" 2>/dev/null \
    | sed 's/^/    plaintext-key /' | head -40
}

inspect_keychain() {
  local service="$1"
  echo "  service $service"
  # Attributes only — never -w.
  if security find-generic-password -s "$service" >/tmp/codenotch-copilot-kc 2>/dev/null; then
    grep -E '"svce"|"acct"|"cdat"|"mdat"|"desc"|"labl"' /tmp/codenotch-copilot-kc | sed 's/^/    /'
    rm -f /tmp/codenotch-copilot-kc
  else
    echo "    none"
    rm -f /tmp/codenotch-copilot-kc
  fi
}

say "1. Installed?"
inspect_app "VS Code" "/Applications/Visual Studio Code.app"
inspect_app "VS Code Insiders" "/Applications/Visual Studio Code - Insiders.app"
inspect_app "VS Code Exploration" "/Applications/Visual Studio Code - Exploration.app"

say "2. VS Code state stores"
inspect_store "Stable" "$CODE_SUPPORT"
inspect_store "Insiders" "$INSIDERS_SUPPORT"

say "3. Keychain (attributes only)"
for svc in \
  "vscodevscode.github-authentication" \
  "vscode-insidersvscode.github-authentication" \
  "vscodevscode.github-authentication.github.auth" \
  "com.microsoft.VSCode.shared-secrets" \
  "com.microsoft.VSCodeInsiders.shared-secrets" \
  "Code Safe Storage" \
  "Code - Insiders Safe Storage"
do
  inspect_keychain "$svc"
done

echo "  dump matching services (names only):"
security dump-keychain 2>/dev/null \
  | grep -iE 'svce.*vscode|svce.*github|svce.*copilot|svce.*Code Safe|labl.*github.auth' \
  | sed 's/^/    /' | sort -u | head -40

say "4. ~/.config/github-copilot"
if [ -d "$COPILOT_CONFIG" ]; then
  ls -la "$COPILOT_CONFIG" | sed 's/^/  /'
  for f in apps.json hosts.json; do
    if [ -f "$COPILOT_CONFIG/$f" ]; then
      echo "  $f keys (values stripped):"
      python3 - "$COPILOT_CONFIG/$f" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as fh:
    data = json.load(fh)
if isinstance(data, dict):
    for key, value in data.items():
        if isinstance(value, dict):
            fields = sorted(value.keys())
            user = value.get("user") or value.get("github_user") or value.get("login")
            has_token = any(k in value for k in ("oauth_token", "token", "access_token"))
            print(f"    entry {key!r} user={user!r} fields={fields} has_token={has_token}")
        else:
            print(f"    entry {key!r} type={type(value).__name__}")
else:
    print(f"    root type={type(data).__name__}")
PY
    fi
  done
  if [ -f "$COPILOT_CONFIG/auth.db" ]; then
    echo "  auth.db tables:"
    sqlite3 "$COPILOT_CONFIG/auth.db" ".tables" 2>/dev/null | sed 's/^/    /'
    echo "  auth.db schema:"
    sqlite3 "$COPILOT_CONFIG/auth.db" ".schema" 2>/dev/null | sed 's/^/    /'
    echo "  oauth_tokens columns (no ciphertext):"
    sqlite3 "$COPILOT_CONFIG/auth.db" "PRAGMA table_info(oauth_tokens);" 2>/dev/null | sed 's/^/    /'
    sqlite3 "$COPILOT_CONFIG/auth.db" "SELECT auth_authority, length(token_ciphertext), substr(CAST(token_ciphertext AS TEXT), 1, 4) FROM oauth_tokens;" 2>/dev/null \
      | sed 's/^/    row authority,len,prefix /'
  fi
else
  echo "  directory does not exist"
fi

say "5. Non-secret Copilot / GitHub identity on disk"
for dir in "$CODE_SUPPORT" "$INSIDERS_SUPPORT"; do
  [ -d "$dir" ] || continue
  echo "  scanning $(basename "$dir") globalStorage for github/copilot plaintext"
  find "$dir/User/globalStorage" -maxdepth 2 -type d 2>/dev/null | sed 's/^/    /' | head -40
done

say "Done. Nothing here is a token. The adapter is written against this output."
