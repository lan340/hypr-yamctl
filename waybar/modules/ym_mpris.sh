#!/usr/bin/env bash
set -euo pipefail

# Можно зафиксировать конкретный инстанс:
# export YM_PLAYER="chromium.instance795600"
YM_PLAYER_DEFAULT="${YM_PLAYER:-}"

# --- helpers ---
lower() { tr '[:upper:]' '[:lower:]'; }

# Экраним спецсимволы для Pango (<, >, &)
pango_escape() {
  sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

pick_player() {
  # 0) Если задан конкретный — используем его
  if [[ -n "$YM_PLAYER_DEFAULT" ]] && playerctl -p "$YM_PLAYER_DEFAULT" status &>/dev/null; then
    echo "$YM_PLAYER_DEFAULT"; return 0
  fi

  # 1) Берём только chromium.* кандидатов
  mapfile -t cand < <(playerctl -l 2>/dev/null | grep -E '^chromium(\.|$)' || true)
  ((${#cand[@]}==0)) && return 1

  # 2) Выбираем лучший chromium: music.yandex + playing > paused > остальное
  local best="" best_score=-999
  for p in "${cand[@]}"; do
    url="$(playerctl -p "$p" metadata xesam:url 2>/dev/null || true)"
    idn="$(playerctl -p "$p" metadata mpris:identity 2>/dev/null || true)"
    st="$(playerctl -p "$p" status 2>/dev/null || true)"

    url_l="$(printf %s "$url" | lower)"
    idn_l="$(printf %s "$idn" | lower)"
    st_l="$(printf %s "$st" | lower)"

    score=0
    [[ "$url_l" == *"music.yandex"* || "$url_l" == *"yandex.ru/music"* ]] && score=$((score+10))
    [[ "$idn_l" == *"yandex"* || "$idn_l" == *"music"* ]] && score=$((score+4))
    case "$st_l" in
      playing) score=$((score+3));;
      paused)  score=$((score+1));;
    esac

    if (( score > best_score )); then best_score=$score; best="$p"; fi
  done

  [[ -n "$best" ]] && playerctl -p "$best" status &>/dev/null && { echo "$best"; return 0; }
  return 1
}

# --- main ---
PLAYER="$(pick_player || true)"
if [[ -z "${PLAYER:-}" ]]; then
  # нет подходящего плеера — отрисуем пусто
  echo '{"text":"","class":"stopped p0","alt":""}'
  exit 0
fi

status="$(playerctl -p "$PLAYER" status 2>/dev/null | lower || true)"
title="$(playerctl -p "$PLAYER" metadata xesam:title 2>/dev/null || true)"
artist="$(playerctl -p "$PLAYER" metadata xesam:artist 2>/dev/null | paste -sd ", " - || true)"
album="$(playerctl -p "$PLAYER" metadata xesam:album 2>/dev/null || true)"
idn="$(playerctl -p "$PLAYER" metadata mpris:identity 2>/dev/null || true)"

# --- прогресс для выбора SVG bar pXX ---
# position → секунды (float); переводим в микросекунды (int)
pos_us="$(playerctl -p "$PLAYER" position 2>/dev/null | awk '{print int($1*1000000)}' | tr -cd '0-9' || true)"
len_us="$(playerctl -p "$PLAYER" metadata mpris:length 2>/dev/null | tr -cd '0-9' || true)"
pos_us="${pos_us:-0}"
len_us="${len_us:-0}"

pct=0
if [[ "$len_us" -gt 0 && "$pos_us" -ge 0 ]]; then
  pct=$(( pos_us * 100 / len_us ))
  (( pct > 100 )) && pct=100
  (( pct < 0 )) && pct=0
fi
# округляем до ближайших 10%
bucket=$(( ((pct + 5) / 10) * 10 ))
(( bucket > 100 )) && bucket=100

# --- текст в две строки (Pango) ---
title_pango="$(printf '%s' "$title"  | pango_escape)"
artist_pango="$(printf '%s' "$artist" | pango_escape)"

if [[ -n "$artist_pango" ]]; then
  two_lines="$(printf '%s\n<span size="smaller" alpha="80%%">%s</span>' \
               "$title_pango" "$artist_pango")"
else
  two_lines="$title_pango"
fi

class_out="$status-p$bucket"
tooltip="${idn:+$idn: }$album"

jq -nc \
  --arg text "$two_lines" \
  --arg class "$class_out" \
  --arg alt "$PLAYER" \
  --arg tooltip "$tooltip" \
  '{text: $text, class: $class, alt: $alt, tooltip: $tooltip}'
