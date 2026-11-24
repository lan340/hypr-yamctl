#!/usr/bin/env bash
# =========================================================================
# hypr-yamctl — Waybar & Hyprland Uninstaller
# Cleanly removes all components and restores original configuration
# =========================================================================

set -euo pipefail

BOLD='\033[1m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo -e "${RED}${BOLD}"
cat << 'EOF'
 ┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
 ┃                   hypr-yamctl Uninstaller                   ┃
 ┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛
EOF
echo -e "${RESET}"

info()    { echo -e "${BLUE}[INFO]${RESET} $*"; }
success() { echo -e "${GREEN}[✓]${RESET} ${BOLD}$*${RESET}"; }
warn()    { echo -e "${YELLOW}[!]${RESET} $*"; }

echo -n "Вы уверены, что хотите полностью удалить интеграцию Яндекс Музыки? [y/N]: "
read -r confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    info "Удаление отменено."
    exit 0
fi

# 1. Stop and disable systemd services
info "Остановка и отключение служб systemd..."
systemctl --user stop ym-like-watch.service ym-vol-watch.service 2>/dev/null || true
systemctl --user disable ym-like-watch.service ym-vol-watch.service 2>/dev/null || true
rm -f "$HOME/.config/systemd/user/ym-like-watch.service" "$HOME/.config/systemd/user/ym-vol-watch.service"
systemctl --user daemon-reload
success "Службы systemd остановлены и удалены."

# 2. Unpatch Waybar
WAYBAR_CONFIG=""
[[ -f "$HOME/.config/waybar/config" ]] && WAYBAR_CONFIG="$HOME/.config/waybar/config"
[[ -f "$HOME/.config/waybar/config.jsonc" ]] && WAYBAR_CONFIG="$HOME/.config/waybar/config.jsonc"

if [[ -n "$WAYBAR_CONFIG" ]]; then
    info "Удаление модулей из $WAYBAR_CONFIG..."
    python3 "$SCRIPT_DIR/scripts/waybar_manager.py" unpatch "$WAYBAR_CONFIG" 2>/dev/null || true
    success "Модули удалены из конфигурации Waybar."
fi

# Remove modular waybar files
rm -f "$HOME/.config/waybar/hypr-yamctl-modules.json" "$HOME/.config/waybar/yamusic-modules.json"
rm -f "$HOME/.config/waybar/hypr-yamctl.css" "$HOME/.config/waybar/yamusic.css"
rm -f "$HOME/.config/waybar/modules/ym_mpris.sh"

# Remove @import from style.css
STYLE_CSS="$HOME/.config/waybar/style.css"
if [[ -f "$STYLE_CSS" ]]; then
    sed -i '/@import.*hypr-yamctl/d' "$STYLE_CSS" 2>/dev/null || true
    sed -i '/@import.*yamusic/d' "$STYLE_CSS" 2>/dev/null || true
    success "Стили hypr-yamctl удалены из style.css"
fi

# 3. Unpatch Hyprland
rm -f "$HOME/.config/hypr/hypr-yamctl.conf" "$HOME/.config/hypr/yamusic.conf"

HYPRLAND_MAIN="$HOME/.config/hypr/hyprland.conf"
if [[ -f "$HYPRLAND_MAIN" ]]; then
    sed -i '/source = .*hypr-yamctl\.conf/d' "$HYPRLAND_MAIN"
    sed -i '/source = .*yamusic\.conf/d' "$HYPRLAND_MAIN"
    sed -i '/hypr-yamctl\.conf/d' "$HYPRLAND_MAIN" 2>/dev/null || true
    sed -i '/yamusic\.conf/d' "$HYPRLAND_MAIN" 2>/dev/null || true
    success "Привязка hypr-yamctl.conf удалена из $HYPRLAND_MAIN."
fi

# 4. Remove binaries from ~/.local/bin
info "Удаление скриптов из ~/.local/bin/..."
rm -f "$HOME/.local/bin/hypr-yamctl" \
      "$HOME/.local/bin/ym-node" \
      "$HOME/.local/bin/ym-like-watch.js" \
      "$HOME/.local/bin/ym-vol-watch.js" \
      "$HOME/.local/bin/ym_playerctl" \
      "$HOME/.local/bin/ym_wpvol" \
      "$HOME/.local/bin/mpris-ym" \
      "$HOME/.local/bin/yandex-music" \
      "$HOME/.local/bin/waybar-single"
success "Бинарные файлы удалены."

# 5. Check if user wants to restore latest backup
LATEST_BAK="$(ls -t "$HOME/.config/waybar/config"*bak* 2>/dev/null | head -n 1 || true)"
if [[ -n "$LATEST_BAK" && -f "$LATEST_BAK" ]]; then
    echo ""
    warn "Обнаружена резервная копия конфига: $LATEST_BAK"
    echo -n "Восстановить конфиг Waybar из этой резервной копии? [y/N]: "
    read -r ans_bak
    if [[ "$ans_bak" =~ ^[Yy]$ ]] && [[ -n "${WAYBAR_CONFIG:-}" ]]; then
        cp "$LATEST_BAK" "$WAYBAR_CONFIG"
        success "Конфиг Waybar восстановлен из $LATEST_BAK."
    fi
fi

# 6. Restart Waybar
echo ""
echo -n "Перезапустить Waybar сейчас? [Y/n]: "
read -r ans_bar
if [[ "${ans_bar:-y}" =~ ^[Yy]?$ ]]; then
    killall -q waybar || true
    sleep 1
    if [[ -f "$HOME/.local/bin/waybar-single" ]]; then
        nohup "$HOME/.local/bin/waybar-single" >/dev/null 2>&1 &
    elif command -v waybar &>/dev/null; then
        nohup waybar >/dev/null 2>&1 &
    fi
    success "Waybar перезапущен."
fi

echo ""
success "Удаление полностью завершено. Система возвращена в исходное состояние."
