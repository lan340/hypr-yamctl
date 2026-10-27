#!/usr/bin/env bash
# =========================================================================
# Yandex Music Waybar & Hyprland Installer
# Interactive, non-destructive installer with custom placement and hotkeys
# =========================================================================

set -euo pipefail

# --- Color definitions ---
BOLD='\033[1m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"

echo -e "${CYAN}${BOLD}"
cat << 'EOF'
 ┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
 ┃           Yandex Music -> Waybar & Hyprland Installer       ┃
 ┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛
EOF
echo -e "${RESET}"

# --- Helper functions ---
info()    { echo -e "${BLUE}[INFO]${RESET} $*"; }
success() { echo -e "${GREEN}[✓]${RESET} ${BOLD}$*${RESET}"; }
warn()    { echo -e "${YELLOW}[!]${RESET} $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }

# --- Check Dependencies ---
info "Проверка системных зависимостей..."
MISSING_DEPS=()
for cmd in curl jq playerctl python3; do
    if ! command -v "$cmd" &>/dev/null; then
        MISSING_DEPS+=("$cmd")
    fi
done

if [[ ${#MISSING_DEPS[@]} -gt 0 ]]; then
    warn "Отсутствуют необходимые утилиты: ${MISSING_DEPS[*]}"
    if command -v pacman &>/dev/null; then
        echo -n "Установить через pacman? [Y/n]: "
        read -r ans
        if [[ "$ans" =~ ^[Yy]?$ ]]; then
            sudo pacman -S --needed "${MISSING_DEPS[@]}"
        else
            error "Пожалуйста, установите ${MISSING_DEPS[*]} и перезапустите скрипт."
            exit 1
        fi
    else
        error "Пожалуйста, установите ${MISSING_DEPS[*]} через ваш пакетный менеджер."
        exit 1
    fi
fi
success "Базовые утилиты в наличии."

# --- Check Node/Electron Runtime ---
info "Проверка среды выполнения JavaScript..."
NODE_EXEC=""
if command -v electron34 &>/dev/null; then
    NODE_EXEC="electron34"
elif command -v electron &>/dev/null; then
    NODE_EXEC="electron"
elif command -v node &>/dev/null; then
    # Test if node works and has required libraries
    if node -e 'process.exit(0)' 2>/dev/null; then
        NODE_EXEC="node"
    fi
fi

if [[ -z "$NODE_EXEC" ]]; then
    warn "Системный Node.js или Electron не найдены / повреждены."
    warn "Рекомендуется: sudo pacman -S electron34 или nodejs."
    echo -n "Продолжить с настройкой на electron34? [Y/n]: "
    read -r ans
    NODE_EXEC="electron34"
fi
success "Среда выполнения JS: $NODE_EXEC"

# --- Discover Waybar Config ---
info "Поиск конфигурации Waybar..."
WAYBAR_CONFIG=""
if [[ -f "$HOME/.config/waybar/config" ]]; then
    WAYBAR_CONFIG="$HOME/.config/waybar/config"
elif [[ -f "$HOME/.config/waybar/config.jsonc" ]]; then
    WAYBAR_CONFIG="$HOME/.config/waybar/config.jsonc"
else
    error "Не найден конфиг Waybar в ~/.config/waybar/ (config или config.jsonc)."
    exit 1
fi
success "Найден конфиг Waybar: $WAYBAR_CONFIG"

# Scan via Python script
SCAN_JSON="$(python3 "$SCRIPT_DIR/scripts/waybar_manager.py" scan "$WAYBAR_CONFIG")"
IS_ARRAY="$(echo "$SCAN_JSON" | jq -r '.is_array')"
ALREADY_INSTALLED="$(echo "$SCAN_JSON" | jq -r '.already_installed')"

if [[ "$ALREADY_INSTALLED" == "true" ]]; then
    warn "Модули Яндекс Музыки уже обнаружены в конфигурации Waybar!"
    echo -n "Переустановить / обновить интеграцию заново? [Y/n]: "
    read -r ans
    if [[ ! "$ans" =~ ^[Yy]?$ ]]; then
        info "Установка отменена пользователем."
        exit 0
    fi
    # Unpatch first
    python3 "$SCRIPT_DIR/scripts/waybar_manager.py" unpatch "$WAYBAR_CONFIG"
    SCAN_JSON="$(python3 "$SCRIPT_DIR/scripts/waybar_manager.py" scan "$WAYBAR_CONFIG")"
fi

# --- Select Target Bar (if multi-monitor array) ---
BAR_INDEX=0
BAR_COUNT="$(echo "$SCAN_JSON" | jq -r '.bar_count')"
if [[ "$IS_ARRAY" == "true" && "$BAR_COUNT" -gt 1 ]]; then
    echo ""
    echo -e "${BOLD}? В конфиге обнаружено несколько панелей ($BAR_COUNT шт.). Куда установить?${RESET}"
    echo "  0) На все панели (All outputs) [Рекомендуется]"
    for ((i=0; i<BAR_COUNT; i++)); do
        out_name="$(echo "$SCAN_JSON" | jq -r ".bars[$i].output")"
        echo "  $((i+1))) Только на панель $((i+1)) (output: $out_name)"
    done
    echo -n "Ваш выбор [0-$BAR_COUNT]: "
    read -r bar_choice
    if [[ "$bar_choice" == "0" || -z "$bar_choice" ]]; then
        BAR_INDEX="all"
    else
        BAR_INDEX="$((bar_choice - 1))"
    fi
fi

# --- Select Section ---
echo ""
echo -e "${BOLD}? В какую секцию панели вы хотите поместить плеер?${RESET}"
echo "  1) modules-left   (Слева, например рядом с воркспейсами) [Рекомендуется]"
echo "  2) modules-center (По центру, рядом с часами/погодой)"
echo "  3) modules-right  (Справа, в системной области)"
echo -n "Ваш выбор [1-3, по умолчанию 1]: "
read -r sec_choice

SECTION="modules-left"
case "${sec_choice:-1}" in
    2) SECTION="modules-center" ;;
    3) SECTION="modules-right"  ;;
    *) SECTION="modules-left"   ;;
esac
success "Выбрана секция: $SECTION"

# --- Select Position within Section ---
CURRENT_MODULES=($(echo "$SCAN_JSON" | jq -r ".bars[0][\"$SECTION\"][]" 2>/dev/null || true))
MOD_COUNT=${#CURRENT_MODULES[@]}

echo ""
echo -e "${BOLD}? Где именно внутри '$SECTION' разместить блоки?${RESET}"
echo "  1) В самом начале секции (перед всеми модулями)"
echo "  2) В самом конце секции (после всех модулей) [По умолчанию]"
if [[ $MOD_COUNT -gt 0 ]]; then
    echo "  3) После конкретного существующего модуля..."
    echo "  4) Перед конкретным существующим модулем..."
fi
echo -n "Ваш выбор: "
read -r pos_choice

POSITION="end"
TARGET_MODULE=""

case "${pos_choice:-2}" in
    1) POSITION="start" ;;
    3)
        POSITION="after"
        echo ""
        echo "Текущие модули в '$SECTION':"
        for ((i=0; i<MOD_COUNT; i++)); do
            echo "  $((i+1))) ${CURRENT_MODULES[$i]}"
        done
        echo -n "Вставить ПОСЛЕ какого модуля? [номер 1-$MOD_COUNT]: "
        read -r mod_idx
        idx=$((mod_idx - 1))
        if [[ $idx -ge 0 && $idx -lt $MOD_COUNT ]]; then
            TARGET_MODULE="${CURRENT_MODULES[$idx]}"
        else
            POSITION="end"
        fi
        ;;
    4)
        POSITION="before"
        echo ""
        echo "Текущие модули в '$SECTION':"
        for ((i=0; i<MOD_COUNT; i++)); do
            echo "  $((i+1))) ${CURRENT_MODULES[$i]}"
        done
        echo -n "Вставить ПЕРЕД каким модулем? [номер 1-$MOD_COUNT]: "
        read -r mod_idx
        idx=$((mod_idx - 1))
        if [[ $idx -ge 0 && $idx -lt $MOD_COUNT ]]; then
            TARGET_MODULE="${CURRENT_MODULES[$idx]}"
        else
            POSITION="start"
        fi
        ;;
    *) POSITION="end" ;;
esac
success "Позиция: $POSITION ${TARGET_MODULE:+($TARGET_MODULE)}"

# --- Select Components & Order ---
echo ""
echo -e "${BOLD}? Какие компоненты управления Яндекс Музыкой включить?${RESET}"
echo -n "  Включить кнопку сердечка (лайк текущего трека)? [Y/n]: "
read -r inc_heart
echo -n "  Включить название трека + круговой прогресс?   [Y/n]: "
read -r inc_track
echo -n "  Включить управление внутренней громкостью?    [Y/n]: "
read -r inc_vol

MOD_HEART="custom/mpris_heart"
MOD_TRACK="custom/ym_mpris"
MOD_VOL="custom/ym_volume"

SELECTED_MODS=()
[[ "${inc_heart:-y}" =~ ^[Yy]?$ ]] && SELECTED_MODS+=("$MOD_HEART")
[[ "${inc_track:-y}" =~ ^[Yy]?$ ]] && SELECTED_MODS+=("$MOD_TRACK")
[[ "${inc_vol:-y}"   =~ ^[Yy]?$ ]] && SELECTED_MODS+=("$MOD_VOL")

if [[ ${#SELECTED_MODS[@]} -eq 0 ]]; then
    warn "Ни один модуль не выбран. Включаем все три по умолчанию."
    SELECTED_MODS=("$MOD_HEART" "$MOD_TRACK" "$MOD_VOL")
fi

# Order selection if more than 1 module selected
if [[ ${#SELECTED_MODS[@]} -gt 1 ]]; then
    echo ""
    echo -e "${BOLD}? Выберите порядок отображения модулей:${RESET}"
    echo "  1) [♥ Сердечко] [Название трека] [Громкость] (По умолчанию)"
    echo "  2) [Название трека] [♥ Сердечко] [Громкость]"
    echo "  3) [Название трека] [Громкость] [♥ Сердечко]"
    echo -n "Ваш выбор [1-3, по умолчанию 1]: "
    read -r order_choice
    case "${order_choice:-1}" in
        2)
            # Track first, then Heart, then Vol
            NEW_ORDER=()
            [[ " ${SELECTED_MODS[*]} " =~ " $MOD_TRACK " ]] && NEW_ORDER+=("$MOD_TRACK")
            [[ " ${SELECTED_MODS[*]} " =~ " $MOD_HEART " ]] && NEW_ORDER+=("$MOD_HEART")
            [[ " ${SELECTED_MODS[*]} " =~ " $MOD_VOL " ]]   && NEW_ORDER+=("$MOD_VOL")
            SELECTED_MODS=("${NEW_ORDER[@]}")
            ;;
        3)
            NEW_ORDER=()
            [[ " ${SELECTED_MODS[*]} " =~ " $MOD_TRACK " ]] && NEW_ORDER+=("$MOD_TRACK")
            [[ " ${SELECTED_MODS[*]} " =~ " $MOD_VOL " ]]   && NEW_ORDER+=("$MOD_VOL")
            [[ " ${SELECTED_MODS[*]} " =~ " $MOD_HEART " ]] && NEW_ORDER+=("$MOD_HEART")
            SELECTED_MODS=("${NEW_ORDER[@]}")
            ;;
    esac
fi

MODS_CSV="$(IFS=,; echo "${SELECTED_MODS[*]}")"
success "Выбранные модули: $MODS_CSV"

# --- Hyprland Keybindings Setup ---
echo ""
echo -e "${BOLD}? Настройка горячих клавиш в Hyprland:${RESET}"
echo "  1) $mainMod = SUPER (Клавиша Windows) [По умолчанию]"
echo "  2) $mainMod = ALT"
echo -n "Выберите клавишу-модификатор [1-2, по умолчанию 1]: "
read -r mod_key_choice

HYPR_MOD="SUPER"
[[ "${mod_key_choice:-1}" == "2" ]] && HYPR_MOD="ALT"

echo ""
echo "Стандартная раскладка клавиш:"
echo "  $HYPR_MOD + ~ (grave)           : Поставить / снять лайк"
echo "  $HYPR_MOD + X                   : Воспроизведение / Пауза"
echo "  $HYPR_MOD + C                   : Следующий трек"
echo "  $HYPR_MOD + Z                   : Предыдущий трек"
echo "  $HYPR_MOD + Shift + Колесо Мыши : Регулировка громкости плеера"
echo "  $HYPR_MOD + Shift + Клик Колесом: Заглушить (Mute) плеер"
echo -n "Оставить эти горячие клавиши? [Y/n]: "
read -r ans_keys

KEY_LIKE="grave"
KEY_PLAY="X"
KEY_NEXT="C"
KEY_PREV="Z"

if [[ ! "${ans_keys:-y}" =~ ^[Yy]?$ ]]; then
    echo -n "Клавиша для Лайка [сейчас: grave]: "
    read -r user_k && KEY_LIKE="${user_k:-grave}"
    echo -n "Клавиша Play/Pause [сейчас: X]: "
    read -r user_k && KEY_PLAY="${user_k:-X}"
    echo -n "Клавиша Следующий трек [сейчас: C]: "
    read -r user_k && KEY_NEXT="${user_k:-C}"
    echo -n "Клавиша Предыдущий трек [сейчас: Z]: "
    read -r user_k && KEY_PREV="${user_k:-Z}"
fi
success "Конфигурация клавиш готова."

# --- Confirmation before applying ---
echo ""
echo -e "${MAGENTA}${BOLD}------------------------------------------------------${RESET}"
echo -e "${BOLD}Итог установки:${RESET}"
echo "  • Конфиг Waybar: $WAYBAR_CONFIG"
echo "  • Размещение:    $SECTION -> $POSITION ${TARGET_MODULE:+($TARGET_MODULE)}"
echo "  • Модули:        $MODS_CSV"
echo "  • Хоткеи Hyprland: $HYPR_MOD + [$KEY_LIKE, $KEY_PLAY, $KEY_NEXT, $KEY_PREV]"
echo -e "${MAGENTA}${BOLD}------------------------------------------------------${RESET}"
echo -n "Применить все изменения? [Y/n]: "
read -r confirm
if [[ ! "${confirm:-y}" =~ ^[Yy]?$ ]]; then
    warn "Установка отменена пользователем."
    exit 0
fi

# =========================================================================
# Execution phase
# =========================================================================
info "Создание резервных копий конфигураций..."
mkdir -p "$HOME/.config/waybar" "$HOME/.config/hypr" "$HOME/.local/bin" "$HOME/.config/systemd/user"

cp "$WAYBAR_CONFIG" "$WAYBAR_CONFIG.bak.$TIMESTAMP"
[[ -f "$HOME/.config/waybar/style.css" ]] && cp "$HOME/.config/waybar/style.css" "$HOME/.config/waybar/style.css.bak.$TIMESTAMP"
[[ -f "$HOME/.config/hypr/hyprland.conf" ]] && cp "$HOME/.config/hypr/hyprland.conf" "$HOME/.config/hypr/hyprland.conf.bak.$TIMESTAMP"
success "Бэкапы созданы с суффиксом .bak.$TIMESTAMP"

# 1. Install executables to ~/.local/bin/
info "Установка скриптов в ~/.local/bin/..."
cp "$SCRIPT_DIR/bin/"* "$HOME/.local/bin/"
chmod +x "$HOME/.local/bin/"ym-* "$HOME/.local/bin/"ym_* "$HOME/.local/bin/"yandex-music* 2>/dev/null || true

# Configure ym-node to use detected engine
if [[ "$NODE_EXEC" == "electron34" || "$NODE_EXEC" == "electron" ]]; then
    cat << EOF > "$HOME/.local/bin/ym-node"
#!/usr/bin/env bash
export NODE_PATH=/usr/lib/node_modules
export ELECTRON_RUN_AS_NODE=1
exec /usr/bin/$NODE_EXEC "\$@"
EOF
else
    cat << EOF > "$HOME/.local/bin/ym-node"
#!/usr/bin/env bash
export NODE_PATH=/usr/lib/node_modules
exec /usr/bin/node "\$@"
EOF
fi
chmod +x "$HOME/.local/bin/ym-node"
success "Скрипты установлены в ~/.local/bin"

# 2. Install Waybar assets & SVGs
info "Установка иконок и стилей Waybar..."
mkdir -p "$HOME/.config/waybar/svg" "$HOME/.config/waybar/modules"
cp -r "$SCRIPT_DIR/waybar/svg/"* "$HOME/.config/waybar/svg/"
cp "$SCRIPT_DIR/waybar/modules/ym_mpris.sh" "$HOME/.config/waybar/modules/"
chmod +x "$HOME/.config/waybar/modules/ym_mpris.sh"

# Copy modular definitions
cp "$SCRIPT_DIR/waybar/yamusic-modules.json" "$HOME/.config/waybar/yamusic-modules.json"

# Render CSS template with actual SVG path
SVG_ESC_DIR="$HOME/.config/waybar/svg"
sed "s|{{SVG_DIR}}|$SVG_ESC_DIR|g" "$SCRIPT_DIR/waybar/yamusic.css.template" > "$HOME/.config/waybar/yamusic.css"

# Import CSS into user's style.css if not already present
STYLE_CSS="$HOME/.config/waybar/style.css"
if [[ -f "$STYLE_CSS" ]]; then
    if ! grep -q "yamusic.css" "$STYLE_CSS"; then
        # Prepend or append @import
        echo -e '\n@import "yamusic.css";' >> "$STYLE_CSS"
        success "Импорт yamusic.css добавлен в style.css"
    fi
else
    echo '@import "yamusic.css";' > "$STYLE_CSS"
fi

# 3. Patch Waybar config via Python script
info "Инъекция модулей в $WAYBAR_CONFIG..."
python3 "$SCRIPT_DIR/scripts/waybar_manager.py" patch \
    "$WAYBAR_CONFIG" \
    "$BAR_INDEX" \
    "$SECTION" \
    "$POSITION" \
    "$TARGET_MODULE" \
    "$MODS_CSV" \
    "$HOME/.config/waybar/yamusic-modules.json"
success "Конфигурация Waybar успешно обновлена."

# 4. Configure Hyprland
info "Настройка горячих клавиш Hyprland..."
HYPR_CONF="$HOME/.config/hypr/yamusic.conf"
sed -e "s|{{MODIFIER}}|$HYPR_MOD|g" \
    -e "s|{{KEY_LIKE}}|$KEY_LIKE|g" \
    -e "s|{{KEY_PLAY}}|$KEY_PLAY|g" \
    -e "s|{{KEY_NEXT}}|$KEY_NEXT|g" \
    -e "s|{{KEY_PREV}}|$KEY_PREV|g" \
    "$SCRIPT_DIR/hypr/yamusic.conf.template" > "$HYPR_CONF"

HYPRLAND_MAIN="$HOME/.config/hypr/hyprland.conf"
if [[ -f "$HYPRLAND_MAIN" ]]; then
    if ! grep -q "yamusic.conf" "$HYPRLAND_MAIN"; then
        echo -e '\nsource = ~/.config/hypr/yamusic.conf' >> "$HYPRLAND_MAIN"
        success "Подключение yamusic.conf добавлено в $HYPRLAND_MAIN"
    fi
fi

# 5. Systemd User Services
info "Активация фоновых служб systemd..."
cp "$SCRIPT_DIR/systemd/"*.service "$HOME/.config/systemd/user/"
systemctl --user daemon-reload
systemctl --user enable --now ym-like-watch.service ym-vol-watch.service
success "Службы ym-like-watch и ym-vol-watch запущены и добавлены в автозапуск."

# 6. Optional Waybar restart
echo ""
echo -n "Перезапустить Waybar прямо сейчас для применения изменений? [Y/n]: "
read -r restart_bar
if [[ "${restart_bar:-y}" =~ ^[Yy]?$ ]]; then
    info "Перезапуск Waybar..."
    killall -q waybar || true
    sleep 1
    if [[ -f "$HOME/.local/bin/waybar-single" ]]; then
        nohup "$HOME/.local/bin/waybar-single" >/dev/null 2>&1 &
    else
        nohup waybar >/dev/null 2>&1 &
    fi
    success "Waybar перезапущен."
fi

echo ""
echo -e "${GREEN}${BOLD}======================================================${RESET}"
echo -e "${GREEN}${BOLD}       Установка успешно завершена!                   ${RESET}"
echo -e "${GREEN}${BOLD}======================================================${RESET}"
echo "Для удаления или отката в любой момент выполните: ./uninstall.sh"
