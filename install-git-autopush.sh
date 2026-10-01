#!/usr/bin/env bash
# =====================================================================
#  git-autopush: новая ветка сразу пушится на remote (GitHub/GitLab/...)
#  Срабатывает на: git checkout -b, git switch -c, "New Branch" в PyCharm/IDE.
#
#  Установка (Linux/macOS/Windows через Git Bash):
#     bash install-git-autopush.sh             — для всех репозиториев
#     bash install-git-autopush.sh --repo      — только для текущего репозитория
#     bash install-git-autopush.sh --uninstall — удалить
#
#  Windows, PowerShell/cmd (терминал PyCharm по умолчанию):
#     & "C:\Program Files\Git\bin\bash.exe" install-git-autopush.sh
#
#  После установки:
#     git config autopush.enabled false        — выключить в конкретном репо
#     GIT_NO_AUTOPUSH=1 git checkout -b ...    — не пушить разово
# =====================================================================
set -euo pipefail

MARKER="# managed-by: git-autopush"
DEFAULT_DIR_CFG='~/.git-hooks'          # хранится в git config как есть, git сам раскрывает ~
DEFAULT_DIR="$HOME/.git-hooks"

# Хуки, которые в глобальном режиме пробрасываются в .git/hooks репозитория,
# чтобы не сломать pre-commit, husky-подобные и прочие локальные хуки.
DELEGATED_HOOKS="applypatch-msg pre-applypatch post-applypatch pre-commit pre-merge-commit
prepare-commit-msg commit-msg post-commit pre-rebase post-merge pre-push post-rewrite pre-auto-gc"

write_post_checkout() {
cat > "$1" <<'HOOK'
#!/usr/bin/env bash
# managed-by: git-autopush
# Автопуш только что созданной ветки.

# Если хук установлен глобально (core.hooksPath), сначала вызываем локальный .git/hooks/post-checkout.
local_hook="$(git rev-parse --git-common-dir 2>/dev/null)/hooks/post-checkout"
if [ -f "$local_hook" ] && [ -x "$local_hook" ] && ! [ "$local_hook" -ef "$0" ]; then
    "$local_hook" "$@" || exit $?
fi

[ "${3:-}" = "1" ] || exit 0                                  # не переключение ветки
[ -n "${GIT_NO_AUTOPUSH:-}" ] && exit 0
[ "$(git config --bool autopush.enabled)" = "false" ] && exit 0
[ "${1:-}" = "0000000000000000000000000000000000000000" ] && exit 0   # git clone

branch="$(git symbolic-ref --short -q HEAD)" || exit 0          # detached HEAD (rebase и т.п.)

# Уже связана с удалённой веткой — ничего не делаем
git rev-parse --abbrev-ref --symbolic-full-name "@{u}" >/dev/null 2>&1 && exit 0

# Ветка ещё не публиковалась: в её reflog ровно одна запись "branch: Created from ..."
reflog="$(git reflog show --format=%gs "refs/heads/$branch" -- 2>/dev/null)"
[ "$(printf '%s\n' "$reflog" | grep -c .)" = "1" ] || exit 0
case "$reflog" in "branch: Created from"*) ;; *) exit 0 ;; esac

remote="$(git config checkout.defaultRemote || true)"
[ -n "$remote" ] || remote="origin"
git remote get-url "$remote" >/dev/null 2>&1 || exit 0

echo "[autopush] Публикую новую ветку '$branch' в '$remote'..."
if ! git push -u "$remote" "$branch"; then
    echo "[autopush] Не удалось запушить '$branch' (локально ветка создана)." >&2
fi
exit 0
HOOK
chmod +x "$1"
}

write_delegate() {
cat > "$1" <<'HOOK'
#!/usr/bin/env bash
# managed-by: git-autopush
# Пробрасывает вызов в .git/hooks репозитория (глобальный core.hooksPath их иначе отключает).
h="$(git rev-parse --git-common-dir 2>/dev/null)/hooks/$(basename "$0")"
if [ -f "$h" ] && [ -x "$h" ] && ! [ "$h" -ef "$0" ]; then exec "$h" "$@"; fi
exit 0
HOOK
chmod +x "$1"
}

is_ours() { [ -f "$1" ] && grep -qF "$MARKER" "$1"; }

# Не перезаписываем чужие файлы
safe_target() {
    if [ -e "$1" ] && ! is_ours "$1"; then
        echo "  ! $1 уже существует и не наш — пропускаю (проверьте вручную)" >&2
        return 1
    fi
}

global_dir() {
    local cfg
    cfg="$(git config --global --get core.hooksPath || true)"
    if [ -z "$cfg" ]; then echo ""; return; fi
    case "$cfg" in "~/"*) cfg="$HOME/${cfg#\~/}" ;; esac
    echo "$cfg"
}

install_global() {
    local dir cfg_existing
    dir="$(global_dir)"
    if [ -z "$dir" ]; then
        dir="$DEFAULT_DIR"
        git config --global core.hooksPath "$DEFAULT_DIR_CFG"
        echo "Установлен core.hooksPath = $DEFAULT_DIR_CFG"
    else
        echo "Использую уже настроенный core.hooksPath: $dir"
    fi
    mkdir -p "$dir"

    if safe_target "$dir/post-checkout"; then
        write_post_checkout "$dir/post-checkout"
        echo "  + $dir/post-checkout"
    else
        echo "Ошибка: не удалось установить post-checkout." >&2; exit 1
    fi
    for h in $DELEGATED_HOOKS; do
        if [ ! -e "$dir/$h" ] || is_ours "$dir/$h"; then write_delegate "$dir/$h"; fi
    done
    echo "Готово: новые ветки будут автоматически пушиться во всех репозиториях."
}

install_repo() {
    local hooks
    git rev-parse --git-dir >/dev/null 2>&1 || { echo "Запустите внутри git-репозитория." >&2; exit 1; }
    hooks="$(git rev-parse --git-path hooks)"
    if [ -n "$(git config --get core.hooksPath || true)" ]; then
        echo "Внимание: задан core.hooksPath ($(git config --get core.hooksPath)), хук ставлю туда."
    fi
    mkdir -p "$hooks"
    safe_target "$hooks/post-checkout" || { echo "Ошибка: в репо уже есть свой post-checkout." >&2; exit 1; }
    write_post_checkout "$hooks/post-checkout"
    echo "  + $hooks/post-checkout"
    echo "Готово: автопуш новых веток включён в этом репозитории."
}

uninstall() {
    local dir f
    dir="$(global_dir)"
    if [ -n "$dir" ] && [ -d "$dir" ]; then
        for f in "$dir"/*; do is_ours "$f" && rm -f "$f" && echo "  - $f"; done
        if [ -z "$(ls -A "$dir")" ]; then
            rmdir "$dir"
            git config --global --unset core.hooksPath
            echo "core.hooksPath удалён из глобального конфига."
        fi
    fi
    if git rev-parse --git-dir >/dev/null 2>&1; then
        f="$(git rev-parse --git-path hooks)/post-checkout"
        is_ours "$f" && rm -f "$f" && echo "  - $f"
    fi
    echo "Удалено."
}

command -v git >/dev/null || { echo "git не найден." >&2; exit 1; }

case "${1:-}" in
    "")            install_global ;;
    --repo)        install_repo ;;
    --uninstall)   uninstall ;;
    -h|--help)     sed -n '2,18p' "$0" ;;
    *)             echo "Неизвестный параметр: $1 (см. --help)" >&2; exit 1 ;;
esac
