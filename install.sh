#!/usr/bin/env bash
# =========================================================================
# Yandex Music Waybar & Hyprland Installer
# Interactive, non-destructive installer with custom placement, hotkeys,
# automatic dependency resolution, and selective component installation.
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

# =========================================================================
# 1. Dependency Resolution & Automatic Installation
# =========================================================================
info "Определение пакетного менеджера системы..."
PKG_MANAGER=""
INSTALL_CMD=""

if command -v pacman &>/dev/null; then
    PKG_MANAGER="pacman"
    INSTALL_CMD="sudo pacman -S --needed"
elif command -v yay &>/dev/null; then
    PKG_MANAGER="yay"
    INSTALL_CMD="yay -S --needed"
elif command -v paru &>/dev/null; then
    PKG_MANAGER="paru"
    INSTALL_CMD="paru -S --needed"
elif command -v dnf &>/dev/null; then
    PKG_MANAGER="dnf"
    INSTALL_CMD="sudo dnf install -y"
elif command -v apt-get &>/dev/null; then
    PKG_MANAGER="apt"
    INSTALL_CMD="sudo apt-get install -y"
fi

if [[ -n "$PKG_MANAGER" ]]; then
    info "Обнаружен пакетный менеджер: ${BOLD}$PKG_MANAGER${RESET}"
else
    warn "Автоматически определяемый пакетный менеджер не найден (pacman/yay/paru/dnf/apt)."
fi

info "Проверка системных зависимостей..."
MISSING_DEPS=()
for cmd in curl jq playerctl python3; do
    if ! command -v "$cmd" &>/dev/null; then
        MISSING_DEPS+=("$cmd")
    fi
done

# Проверка Node.js / Electron
NODE_FOUND=false
if command -v electron34 &>/dev/null || command -v electron &>/dev/null; then
    NODE_FOUND=true
elif command -v node &>/dev/null; then
    if node -e 'process.exit(0)' 2>/dev/null; then
        NODE_FOUND=true
    fi
fi

if [[ "$NODE_FOUND" == "false" ]]; then
    MISSING_DEPS+=("nodejs" "npm")
fi

if [[ ${#MISSING_DEPS[@]} -gt 0 ]]; then
    warn "Отсутствуют необходимые пакеты: ${BOLD}${MISSING_DEPS[*]}${RESET}"
    if [[ -n "$INSTALL_CMD" ]]; then
        echo -n "Хотите установить их автоматически через $PKG_MANAGER? [Y/n]: "
        read -r ans
        if [[ "${ans:-y}" =~ ^[Yy]?$ ]]; then
            info "Запуск установки: $INSTALL_CMD ${MISSING_DEPS[*]}..."
            $INSTALL_CMD "${MISSING_DEPS[@]}"
            success "Пакеты успешно установлены."
        else
            error "Пожалуйста, установите ${MISSING_DEPS[*]} вручную и перезапустите скрипт."
            exit 1
        fi
    else
        error "Пожалуйста, установите ${MISSING_DEPS[*]} через ваш пакетный менеджер."
        exit 1
    fi
fi

# Определение конкретного исполняемого файла JS
NODE_EXEC=""
if command -v electron34 &>/dev/null; then
    NODE_EXEC="electron34"
elif command -v electron &>/dev/null; then
    NODE_EXEC="electron"
elif command -v node &>/dev/null; then
    NODE_EXEC="node"
else
    NODE_EXEC="node"
fi
success "Среда выполнения JS: $NODE_EXEC"

# Проверка WebSocket библиотеки (ws) для Node.js
info "Проверка библиотеки WebSocket ('ws')..."
WS_OK=false
if command -v node &>/dev/null && node -e "require('ws')" 2>/dev/null; then
    WS_OK=true
elif [[ -d "/usr/lib/node_modules/ws" ]]; then
    WS_OK=true
fi

if [[ "$WS_OK" == "false" ]]; then
    warn "Библиотека 'ws' (WebSocket) для Node.js не найдена."
    if command -v npm &>/dev/null; then
        echo -n "Установить глобально через npm (sudo npm i -g ws)? [Y/n]: "
        read -r ans_npm
        if [[ "${ans_npm:-y}" =~ ^[Yy]?$ ]]; then
            info "Установка ws через npm..."
            sudo npm i -g ws
            WS_OK=true
            success "Библиотека ws успешно установлена."
        else
            warn "Без ws служба лайков не сможет подключиться к плееру."
        fi
    else
        warn "npm не найден. Пожалуйста, установите npm и выполните: sudo npm i -g ws"
    fi
else
    success "Библиотека WebSocket ('ws') в наличии."
fi

# =========================================================================
# 2. Selection of Components (Waybar, Hyprland or Both)
# =========================================================================
echo ""
echo -e "${BOLD}? Какие компоненты вы хотите настроить?${RESET}"
echo "  1) Waybar + Hyprland (Полная связка: панель + хоткеи) [По умолчанию]"
echo "  2) Только Waybar     (Модули плеера в панели, без биндов Hyprland)"
echo "  3) Только Hyprland   (Хоткеи и фоновые службы, без Waybar)"
echo -n "Ваш выбор [1-3, по умолчанию 1]: "
read -r mode_choice

INSTALL_WAYBAR=true
INSTALL_HYPR=true

case "${mode_choice:-1}" in
    2)
        INSTALL_HYPR=false
        info "Выбран режим: Только Waybar"
        ;;
    3)
        INSTALL_WAYBAR=false
        info "Выбран режим: Только Hyprland"
        ;;
    *)
        info "Выбран режим: Waybar + Hyprland (Полная интеграция)"
        ;;
esac

# =========================================================================
# 3. Waybar Configuration & Interactive Placement
# =========================================================================
WAYBAR_CONFIG=""
BAR_INDEX=0
SECTION="modules-left"
POSITION="end"
TARGET_MODULE=""
MODS_CSV=""

if [[ "$INSTALL_WAYBAR" == "true" ]]; then
    info "Поиск конфигурации Waybar..."
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
        if [[ ! "${ans:-y}" =~ ^[Yy]?$ ]]; then
            info "Установка отменена пользователем."
            exit 0
        fi
        python3 "$SCRIPT_DIR/scripts/waybar_manager.py" unpatch "$WAYBAR_CONFIG"
        SCAN_JSON="$(python3 "$SCRIPT_DIR/scripts/waybar_manager.py" scan "$WAYBAR_CONFIG")"
    fi

    # Target Bar selection (multi-monitor)
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

    # Select Section
    echo ""
    echo -e "${BOLD}? В какую секцию панели вы хотите поместить плеер?${RESET}"
    echo "  1) modules-left   (Слева, например рядом с воркспейсами) [Рекомендуется]"
    echo "  2) modules-center (По центру, рядом с часами/погодой)"
    echo "  3) modules-right  (Справа, в системной области)"
    echo -n "Ваш выбор [1-3, по умолчанию 1]: "
    read -r sec_choice

    case "${sec_choice:-1}" in
        2) SECTION="modules-center" ;;
        3) SECTION="modules-right"  ;;
        *) SECTION="modules-left"   ;;
    esac
    success "Выбрана секция: $SECTION"

    # Select Position within Section
    mapfile -t CURRENT_MODULES < <(echo "$SCAN_JSON" | jq -r ".bars[0][\"$SECTION\"][]" 2>/dev/null || true)
    MOD_COUNT=${#CURRENT_MODULES[@]}

    echo ""
    echo -e "${BOLD}? Где именно внутри '$SECTION' разместить блоки?${RESET}"
    echo "  1) В самом начале секции (перед всеми модулями)"
    echo "  2) В самом конце секции (после всех модулей) [По умолчанию]"
    if [[ $MOD_COUNT -gt 0 ]]; then
        echo "  3) Вставить строго после определенного существующего модуля"
    fi
    echo -n "Ваш выбор: "
    read -r pos_choice

    case "${pos_choice:-2}" in
        1) POSITION="start" ;;
        3)
            echo "Существующие модули в $SECTION:"
            for ((idx=0; idx<MOD_COUNT; idx++)); do
                echo "  $((idx+1))) ${CURRENT_MODULES[$idx]}"
            done
            echo -n "Выберите номер модуля, после которого разместить блок [1-$MOD_COUNT]: "
            read -r mod_num
            idx=$(( ${mod_num:-1} - 1 ))
            POSITION="after"
            if [[ $idx -ge 0 && $idx -lt $MOD_COUNT ]]; then
                TARGET_MODULE="${CURRENT_MODULES[$idx]}"
            else
                POSITION="start"
            fi
            ;;
        *) POSITION="end" ;;
    esac
    success "Позиция: $POSITION ${TARGET_MODULE:+($TARGET_MODULE)}"

    # Select Components & Order
    echo ""
    echo -e "${BOLD}? Какие компоненты управления включить в Waybar?${RESET}"
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
    success "Выбранные модули для Waybar: $MODS_CSV"
fi

# =========================================================================
# 4. Hyprland Keybindings Setup
# =========================================================================
HYPR_MOD="SUPER"
KEY_LIKE="grave"
KEY_PLAY="X"
KEY_NEXT="C"
KEY_PREV="Z"

if [[ "$INSTALL_HYPR" == "true" ]]; then
    echo ""
    echo -e "${BOLD}? Настройка горячих клавиш в Hyprland:${RESET}"
    echo "  1) SUPER (Клавиша Windows) [По умолчанию]"
    echo "  2) ALT"
    echo -n "Выберите клавишу-модификатор [1-2, по умолчанию 1]: "
    read -r mod_key_choice
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
fi

# =========================================================================
# 5. Confirmation & Execution
# =========================================================================
echo ""
echo -e "${MAGENTA}${BOLD}------------------------------------------------------${RESET}"
echo -e "${BOLD}Итог установки:${RESET}"
if [[ "$INSTALL_WAYBAR" == "true" ]]; then
    echo "  • Конфиг Waybar:  $WAYBAR_CONFIG"
    echo "  • Размещение:     $SECTION -> $POSITION ${TARGET_MODULE:+($TARGET_MODULE)}"
    echo "  • Модули Waybar:  $MODS_CSV"
else
    echo "  • Waybar:         Пропущен (не устанавливается)"
fi
if [[ "$INSTALL_HYPR" == "true" ]]; then
    echo "  • Хоткеи Hyprland: $HYPR_MOD + [$KEY_LIKE, $KEY_PLAY, $KEY_NEXT, $KEY_PREV]"
else
    echo "  • Hyprland:       Пропущен (не настраивается)"
fi
echo -e "${MAGENTA}${BOLD}------------------------------------------------------${RESET}"
echo -n "Применить все изменения? [Y/n]: "
read -r confirm
if [[ ! "${confirm:-y}" =~ ^[Yy]?$ ]]; then
    warn "Установка отменена пользователем."
    exit 0
fi

# Создание каталогов
mkdir -p "$HOME/.local/bin" "$HOME/.config/systemd/user"

# Резервные копии
info "Создание резервных копий конфигураций..."
if [[ "$INSTALL_WAYBAR" == "true" && -n "$WAYBAR_CONFIG" ]]; then
    cp "$WAYBAR_CONFIG" "$WAYBAR_CONFIG.bak.$TIMESTAMP"
    [[ -f "$HOME/.config/waybar/style.css" ]] && cp "$HOME/.config/waybar/style.css" "$HOME/.config/waybar/style.css.bak.$TIMESTAMP"
fi
if [[ "$INSTALL_HYPR" == "true" && -f "$HOME/.config/hypr/hyprland.conf" ]]; then
    cp "$HOME/.config/hypr/hyprland.conf" "$HOME/.config/hypr/hyprland.conf.bak.$TIMESTAMP"
fi
success "Резервные копии созданы с суффиксом .bak.$TIMESTAMP"

# 1. Установка исполняемых файлов в ~/.local/bin/
info "Установка скриптов в ~/.local/bin/..."
cp "$SCRIPT_DIR/bin/"* "$HOME/.local/bin/"
chmod +x "$HOME/.local/bin/"ym-* "$HOME/.local/bin/"ym_* "$HOME/.local/bin/"yandex-music* "$HOME/.local/bin/"mpris-ym 2>/dev/null || true

# Генерация ym-node
NODE_BIN_PATH="$(command -v "$NODE_EXEC" || echo "$NODE_EXEC")"
if [[ "$NODE_EXEC" == "electron34" || "$NODE_EXEC" == "electron" ]]; then
    cat << EOF > "$HOME/.local/bin/ym-node"
#!/usr/bin/env bash
export NODE_PATH=/usr/lib/node_modules
export ELECTRON_RUN_AS_NODE=1
exec "$NODE_BIN_PATH" "\$@"
EOF
else
    cat << EOF > "$HOME/.local/bin/ym-node"
#!/usr/bin/env bash
export NODE_PATH=/usr/lib/node_modules
exec "$NODE_BIN_PATH" "\$@"
EOF
fi
chmod +x "$HOME/.local/bin/ym-node"
success "Скрипты установлены в ~/.local/bin"

# 2. Установка ресурсов и настройка Waybar (если выбрано)
if [[ "$INSTALL_WAYBAR" == "true" ]]; then
    info "Установка иконок и стилей Waybar..."
    mkdir -p "$HOME/.config/waybar/svg" "$HOME/.config/waybar/modules"
    cp -r "$SCRIPT_DIR/waybar/svg/"* "$HOME/.config/waybar/svg/"
    cp "$SCRIPT_DIR/waybar/modules/ym_mpris.sh" "$HOME/.config/waybar/modules/"
    chmod +x "$HOME/.config/waybar/modules/ym_mpris.sh"

    cp "$SCRIPT_DIR/waybar/yamusic-modules.json" "$HOME/.config/waybar/yamusic-modules.json"

    SVG_ESC_DIR="$HOME/.config/waybar/svg"
    sed "s|{{SVG_DIR}}|$SVG_ESC_DIR|g" "$SCRIPT_DIR/waybar/yamusic.css.template" > "$HOME/.config/waybar/yamusic.css"

    STYLE_CSS="$HOME/.config/waybar/style.css"
    if [[ -f "$STYLE_CSS" ]]; then
        if ! grep -q "yamusic.css" "$STYLE_CSS"; then
            echo -e '\n@import "yamusic.css";' >> "$STYLE_CSS"
            success "Импорт yamusic.css добавлен в style.css"
        fi
    else
        echo '@import "yamusic.css";' > "$STYLE_CSS"
    fi

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
fi

# 3. Настройка Hyprland (если выбрано)
if [[ "$INSTALL_HYPR" == "true" ]]; then
    info "Настройка горячих клавиш Hyprland..."
    mkdir -p "$HOME/.config/hypr"
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
fi

# 4. Фоновые службы systemd
info "Активация фоновых служб systemd..."
for svc_tmpl in "$SCRIPT_DIR/systemd/"*.service; do
    svc_name="$(basename "$svc_tmpl")"
    sed "s|{{HOME}}|$HOME|g" "$svc_tmpl" > "$HOME/.config/systemd/user/$svc_name"
done
systemctl --user daemon-reload
systemctl --user enable --now ym-like-watch.service ym-vol-watch.service 2>/dev/null || true
success "Службы ym-like-watch и ym-vol-watch активированы."

# 5. Перезапуск Waybar (если был настроен)
if [[ "$INSTALL_WAYBAR" == "true" ]]; then
    echo ""
    echo -n "Перезапустить Waybar прямо сейчас для применения изменений? [Y/n]: "
    read -r restart_bar
    if [[ "${restart_bar:-y}" =~ ^[Yy]?$ ]]; then
        info "Перезапуск Waybar..."
        killall -q waybar || true
        sleep 1
        if [[ -f "$HOME/.local/bin/waybar-single" ]]; then
            nohup "$HOME/.local/bin/waybar-single" >/dev/null 2>&1 &
        elif command -v waybar &>/dev/null; then
            nohup waybar >/dev/null 2>&1 &
        fi
        success "Waybar перезапущен."
    fi
fi

echo ""
echo -e "${GREEN}${BOLD}======================================================${RESET}"
echo -e "${GREEN}${BOLD}       Установка успешно завершена!                   ${RESET}"
echo -e "${GREEN}${BOLD}======================================================${RESET}"
echo "Для удаления или отката в любой момент выполните: ./uninstall.sh"
