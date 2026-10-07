# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 OShell contributors

# OShell shell integration v1. Source from ~/.bashrc or ~/.zshrc; do not execute.
# No history options/files are changed. No commands are sent by the terminal.
# Tested syntax: Bash 3.2+, Zsh 5.x. Disable with OSHELL_INTEGRATION=0.
case $- in *i*) ;; *) return 0 ;; esac
[ -t 1 ] || return 0
[ "${OSHELL_INTEGRATION-1}" != 0 ] || return 0

__oshell_report_host() {
    local __oshell_status=$?
    local __oshell_host __oshell_ip __oshell_interfaces __oshell_peer __oshell_peer_port __oshell_server_port
    if [ "${OSHELL_INTEGRATION-1}" = 0 ]; then return "$__oshell_status"; fi
    if [ "${__oshell_cache_connection-}" != "${SSH_CONNECTION-}" ] || [ "${__oshell_cache_until-0}" -le "${SECONDS-0}" ]; then
        __oshell_host=$(command hostname 2>/dev/null) || __oshell_host=
        case "$__oshell_host" in ''|*[!a-zA-Z0-9_.-]*) return "$__oshell_status" ;; esac
        [ "${#__oshell_host}" -le 253 ] || return "$__oshell_status"
        __oshell_ip=
        IFS=' ' read -r __oshell_peer __oshell_peer_port __oshell_ip __oshell_server_port <<EOF
${SSH_CONNECTION-}
EOF
        case "$__oshell_ip" in *[!0-9a-fA-F:.]*) __oshell_ip= ;; esac
        __oshell_interfaces=
        if [ -z "$__oshell_ip" ]; then
            __oshell_interfaces=$(command hostname -I 2>/dev/null) || __oshell_interfaces=
            if [ -z "$__oshell_interfaces" ]; then
                if command -v ip >/dev/null 2>&1; then
                    __oshell_interfaces=$(command ip -o addr show scope global 2>/dev/null | command awk '{print $4}') || __oshell_interfaces=
                elif [ -x /sbin/ip ]; then
                    __oshell_interfaces=$(/sbin/ip -o addr show scope global 2>/dev/null | command awk '{print $4}') || __oshell_interfaces=
                elif [ -x /sbin/ifconfig ]; then
                    __oshell_interfaces=$(/sbin/ifconfig 2>/dev/null | command awk '$1=="inet" || $1=="inet6" {print $2}') || __oshell_interfaces=
                fi
            fi
        fi
        # Do not allow host/network command output to introduce OSC delimiters.
        __oshell_interfaces=$(builtin printf '%s' "$__oshell_interfaces" | LC_ALL=C command tr -cd '0-9a-fA-F:./ \n' | command tr '\n' ' ') || __oshell_interfaces=
        __oshell_cached_payload="$__oshell_host|$__oshell_ip|${__oshell_interfaces:0:3000}"
        __oshell_cache_connection=${SSH_CONNECTION-}
        __oshell_cache_until=$(( ${SECONDS-0} + 30 ))
    fi
    if [ -n "${__oshell_cached_payload-}" ]; then
        builtin printf '\033]777;OShellHost=1;%s\007' "$__oshell_cached_payload"
    fi
    return "$__oshell_status"
}

if [ -n "${ZSH_VERSION-}" ]; then
    # A nonzero precmd hook aborts later hooks in Zsh, so report success here.
    __oshell_zsh_precmd() { __oshell_report_host; return 0; }
    autoload -Uz add-zsh-hook
    add-zsh-hook precmd __oshell_zsh_precmd
elif [ -n "${BASH_VERSION-}" ]; then
    # Prepend our status-preserving hook. Leave existing string/array hooks intact.
    case "${PROMPT_COMMAND[*]-}" in
        *__oshell_report_host*) ;;
        *)
            case "$(declare -p PROMPT_COMMAND 2>/dev/null)" in
                'declare -'*r*' PROMPT_COMMAND='*) ;; # A readonly PROMPT_COMMAND cannot be changed.
                'declare -'*a*' PROMPT_COMMAND='*)
                    if [ "${BASH_VERSINFO[0]}" -gt 5 ] || { [ "${BASH_VERSINFO[0]}" -eq 5 ] && [ "${BASH_VERSINFO[1]}" -ge 1 ]; }; then
                        PROMPT_COMMAND=(__oshell_report_host "${PROMPT_COMMAND[@]}")
                    else
                        # Older Bash only executes element zero of this variable.
                        PROMPT_COMMAND[0]="__oshell_report_host${PROMPT_COMMAND[0]:+$'\n'${PROMPT_COMMAND[0]}}"
                    fi
                    ;;
                *) PROMPT_COMMAND="__oshell_report_host${PROMPT_COMMAND:+$'\n'$PROMPT_COMMAND}" ;;
            esac
            ;;
    esac
fi
