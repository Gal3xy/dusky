#!/usr/bin/env bash

# Fetch buffers and mode state
ACTIVE=$(makoctl list -j 2>/dev/null || echo "[]")
HISTORY=$(makoctl history -j 2>/dev/null || echo "[]")
DND_STATE=$(makoctl mode | grep 'do-not-disturb')

[[ -z "$ACTIVE" ]] && ACTIVE="[]"
[[ -z "$HISTORY" ]] && HISTORY="[]"

BLACKLIST_FILE="${XDG_RUNTIME_DIR:-/tmp}/mako_rofi_blacklist"
BLACKLIST_RAW=$(cat "$BLACKLIST_FILE" 2>/dev/null || echo "")

# Calculate the true count
COUNT=$(jq -r -n \
  --argjson active "$ACTIVE" \
  --argjson history "$HISTORY" \
  --arg bl "$BLACKLIST_RAW" '
  ($bl | split("\n") | map(select(. != ""))) as $blacklisted_ids
  | ($active + $history) 
  | unique_by(.id) 
  | map(select(.summary != null and .summary != "")) 
  | map(select((.id | tostring) as $id_str | $blacklisted_ids | index($id_str) | not))
  | length
')

# Dynamically output JSON based on DND state and Count
if [[ -n "$DND_STATE" ]]; then
    # DND is ENABLED
    if [[ "$COUNT" -eq 0 ]]; then
        echo '{"text": "󰂛", "tooltip": "Do Not Disturb (0 pending)", "class": "dnd"}'
    else
        echo '{"text": "󰂛 '"$COUNT"'", "tooltip": "Do Not Disturb ('"$COUNT"' pending)", "class": "dnd-pending"}'
    fi
else
    # DND is DISABLED
    if [[ "$COUNT" -eq 0 ]]; then
        echo '{"text": "󰂚 0", "tooltip": "No notifications", "class": "empty"}'
    else
        echo '{"text": "󰂚 '"$COUNT"'", "tooltip": "'"$COUNT"' pending notifications", "class": "pending"}'
    fi
fi
