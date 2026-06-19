#!/bin/bash
# MTProxyL — подменю: обновления и бэкапы

tui_backup_menu() {
    while true; do
        clear_screen
        draw_header "ОБНОВЛЕНИЯ И БЭКАПЫ"
        echo ""
        if [ -n "$_UPDATE_AVAILABLE" ]; then
            echo -e "  ${YELLOW}${BOLD}⬆ Доступно: v${VERSION} → v${_UPDATE_AVAILABLE}${NC}"
        else
            echo -e "  ${GREEN}${SYM_CHECK}${NC} ${DIM}Версия актуальна (v${VERSION})${NC}"
        fi
        echo ""
        echo -e "  ${DIM}[1]${NC} Проверить и установить обновления"
        echo -e "  ${DIM}[2]${NC} Создать бэкап"
        echo -e "  ${DIM}[3]${NC} Восстановить бэкап"
        echo -e "  ${DIM}[4]${NC} Список бэкапов"
        echo -e "  ${DIM}[5]${NC} Зашифрованный бэкап"
        echo -e "  ${DIM}[6]${NC} Восстановить зашифрованный"
        echo -e "  ${DIM}[7]${NC} Экспорт (миграция)"
        echo -e "  ${DIM}[8]${NC} Импорт (миграция)"
        echo -e "  ${DIM}[9]${NC} Автоочистка"
        echo -e "  ${DIM}[0]${NC} Назад"
        local choice; choice=$(read_choice "выбор" "0")
        case "$choice" in
            1) self_update || true; press_any_key ;;
            2) create_backup || true; press_any_key ;;
            3) list_backups; echo -en "  ${BOLD}Файл:${NC} "; local f; read -r f
               [ -n "$f" ] && restore_backup "$f" || true; press_any_key ;;
            4) list_backups; press_any_key ;;
            5) backup_create_encrypted || true; press_any_key ;;
            6) echo -en "  ${BOLD}Файл:${NC} "; local f; read -r f
               [ -n "$f" ] && backup_restore_encrypted "$f" || true; press_any_key ;;
            7) migrate_export || true; press_any_key ;;
            8) echo -en "  ${BOLD}Файл:${NC} "; local f; read -r f
               [ -n "$f" ] && migrate_import "$f" || true; press_any_key ;;
            9) echo -en "  ${BOLD}Удалить старше дней [${BACKUP_RETENTION_DAYS:-30}]:${NC} "; local d; read -r d
               backup_autoclean "${d:-${BACKUP_RETENTION_DAYS:-30}}" || true; press_any_key ;;
            0|"") return ;;
        esac
    done
}
