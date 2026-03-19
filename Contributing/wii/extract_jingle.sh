#!/bin/bash

shopt -s nullglob

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

case "$(uname)" in
    Darwin)
        TOOL_DOLPHIN="$SCRIPT_DIR/tools/macos/dolphin-tool"
        TOOL_WSZST="$SCRIPT_DIR/tools/macos/wszst"
        VGM="$SCRIPT_DIR/../tools/macos/vgmstream-cli"
        ;;
    Linux)
        TOOL_DOLPHIN="$SCRIPT_DIR/tools/linux/dolphin-tool"
        TOOL_WSZST="$SCRIPT_DIR/tools/linux/wszst"
        VGM="$SCRIPT_DIR/../tools/linux/vgmstream-cli"
        ;;
    *)
        echo "Unsupported OS: $(uname). Only Linux and macOS are supported."
        exit 1
        ;;
esac

if [ ! -x "$TOOL_DOLPHIN" ]; then
    echo "dolphin-tool not found or not executable at: $TOOL_DOLPHIN"
    exit 1
fi
if [ ! -x "$TOOL_WSZST" ]; then
    echo "wszst not found or not executable at: $TOOL_WSZST"
    exit 1
fi
if [ ! -x "$VGM" ]; then
    echo "vgmstream-cli not found or not executable at: $VGM"
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 could not be found. Please install python3."
    exit 1
fi
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
JINGLES_DIR="$REPO_ROOT/jingles/wii"
INDEX_JSON="$REPO_ROOT/index.json"

GAMES_DIR="$SCRIPT_DIR/games"
mkdir -p "$JINGLES_DIR"

for ROM in "$GAMES_DIR"/*.rvz "$GAMES_DIR"/*.iso; do
    echo "Processing $ROM..."
    BASENAME="${ROM%.*}"
    BASENAME="$(basename "$BASENAME")"

    tmpdir=$(mktemp -d)
    bnr_dir="$tmpdir/bnr_extract"
    bnr="$bnr_dir/DATA/files/opening.bnr"

    "$TOOL_DOLPHIN" extract -i "$ROM" -s opening.bnr -o "$bnr_dir" > /dev/null

    #a bunch of wii games have an annoying header that needs to be clipped before wszst can handle them. tools that can handle these files with
    #the header do exist, but none of them are scriptable to my knowledge.
    offset=$(LC_ALL=C grep -obam 1 $'\x55\xaa\x38\x2d' "$bnr" | LC_ALL=C head -1 | LC_ALL=C cut -d: -f1) > /dev/null
    if [[ -z "$offset" ]]; then
        echo "Could not find U8 header, skipping."
        continue
    fi

    dd if="$bnr" of="$tmpdir/opening.arc" bs=1 skip="$offset" status=none

    "$TOOL_WSZST" extract "$tmpdir/opening.arc" --dest "$tmpdir/bnr_out" > /dev/null

    sound=$(find "$tmpdir/bnr_out" -name "sound.bin" | head -1)
    if [[ -z "$sound" ]]; then
        echo "  No sound.bin found, skipping."
        rm -rf "$tmpdir"
        continue
    fi
    
    # Compute the sanitized filename (slug) and human-readable game title in one awk pass
    read -r FINAL GAME_TITLE < <(
        printf '%s\n' "$BASENAME" \
        | iconv -f utf-8 -t ascii//TRANSLIT \
        | awk '
        function trim(s) { gsub(/^ +| +$/, "", s); return s }
        {
            s=$0

            # 1. Strip TitleID prefix
            sub(/^0004[0-9A-Fa-f]{12}[-_ ]?/, "", s)

            # 2. Strip trailing noise tags (before the extension, which is already gone)
            sub(/[-_ .]?[Ss]tandard$/, "", s)
            sub(/[-_ .]?[Dd]ecrypted$/, "", s)
            sub(/[-_ .]?[Pp]iratelegit$/, "", s)

            # 3. Strip parenthetical regions/revisions for both outputs
            gsub(/\([^)]*\)/, "", s)
            s = trim(s)

            # 4. Move leading article — on the human-readable copy, before slugifying
            human = s
            if (match(human, /^(The|An|A) /)) {
                art  = substr(human, 1, RLENGTH-1)
                rest = substr(human, RLENGTH+1)
                rest = trim(rest)
                dash = index(rest, " - ")
                if (dash > 0) {
                    human = substr(rest,1,dash-1) ", " art " - " substr(rest,dash+3)
                } else {
                    human = rest ", " art
                }
            }
            # Clean up any double spaces left after stripping parens
            gsub(/ {2,}/, " ", human)
            human = trim(human)

            # 5. Slug: build from the article-moved human string
            slug = human
            gsub(/\047/, "", slug)           # apostrophes
            gsub(/ *- */, "-", slug)
            gsub(/ /, "-", slug)
            gsub(/[^A-Za-z0-9-]+/, "", slug)
            gsub(/-+/, "-", slug)
            gsub(/^-|-$/, "", slug)

            print tolower(slug) ".wav", human
        }')

    "$VGM" "$sound" -o "$JINGLES_DIR/$FINAL" > /dev/null

    rm -rf "$tmpdir"

    echo "Saved: $FINAL  (Game: $GAME_TITLE)"

    # --- Update index.json ---
    JINGLE_PATH="jingles/wii/$FINAL"

    python3 - "$INDEX_JSON" "$GAME_TITLE" "$JINGLE_PATH" <<'PYEOF'
import sys, json

index_path, game_title, jingle_path = sys.argv[1], sys.argv[2], sys.argv[3]

try:
    with open(index_path, 'r', encoding='utf-8') as f:
        data = json.load(f)
except FileNotFoundError:
    data = {"name": "Red's Jingles Pack", "wii": []}

wii = data.get("wii", [])

# Remove any existing entry for this file path (re-run idempotency)
wii = [e for e in wii if e.get("file") != jingle_path]

wii.append({"name": game_title, "file": jingle_path})

# Sort alphabetically by game title (case-insensitive)
wii.sort(key=lambda e: e["name"].lower())

data["wii"] = wii

with open(index_path, 'w', encoding='utf-8') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write('\n')

print(f"index.json updated: {game_title}")
PYEOF

done
