#!/usr/bin/env bash
#===============================================================================
# ssh-audit-harden.sh - Auditoria e hardening do servico OpenSSH
#
# Trabalho: Sistemas Operacionais Linux - Ciberseguranca
# Grupo 6 - Red Hat Enterprise Linux
#
# Le a configuracao EFETIVA do sshd (sshd -T), compara com uma baseline de
# 20 diretivas, e aplica as correcoes em um drop-in dedicado. Toda alteracao
# e validada com "sshd -t" antes do reload; se a validacao falhar, o backup
# anterior e restaurado automaticamente.
#
# Codigos de saida:
#   0 - sucesso, nenhum achado
#   1 - achado (configuracao fora da baseline) ou falha na aplicacao
#   2 - erro de uso (parametro invalido)
#   3 - dependencia ausente ou ambiente invalido
#===============================================================================

set -euo pipefail

#------------------------------------------------------------------------------
# Constantes
#------------------------------------------------------------------------------
readonly VERSAO="1.0.0"
readonly NOME_SCRIPT="${0##*/}"
readonly ARQUIVO_LOG="/var/log/ssh-audit-harden.log"
readonly DIR_DROPIN="/etc/ssh/sshd_config.d"
readonly ARQ_DROPIN="${DIR_DROPIN}/99-hardening-grupo6.conf"
readonly ARQ_PRINCIPAL="/etc/ssh/sshd_config"
readonly DIR_BACKUP="/var/backups/ssh-audit-harden"
readonly PONTEIRO_BACKUP="${DIR_BACKUP}/ULTIMO"

readonly EXIT_OK=0
readonly EXIT_ACHADO=1
readonly EXIT_USO=2
readonly EXIT_DEPENDENCIA=3

# Baseline de hardening.
#   "no maximo"      -> prefixo "<=" (ex.: "<=3")
#   "dentro da faixa"-> "min..max"  (ex.: "1..30", evita que 0 desligue o controle)
#   igualdade exata  -> valor puro
# Ao aplicar, o valor gravado e o limite superior da faixa.
declare -A BASELINE=(
    [PermitRootLogin]="no"
    [PasswordAuthentication]="no"
    [KbdInteractiveAuthentication]="no"
    [PubkeyAuthentication]="yes"
    [PermitEmptyPasswords]="no"
    [HostbasedAuthentication]="no"
    [IgnoreRhosts]="yes"
    [MaxAuthTries]="1..3"
    [LoginGraceTime]="1..30"
    [ClientAliveInterval]="1..300"
    [ClientAliveCountMax]="0..2"
    [MaxSessions]="1..4"
    [X11Forwarding]="no"
    [AllowTcpForwarding]="no"
    [AllowAgentForwarding]="no"
    [GatewayPorts]="no"
    [PermitUserEnvironment]="no"
    [Compression]="no"
    [LogLevel]="VERBOSE"
    [Banner]="/etc/issue.net"
)

# Preenchidas pelo processamento de parametros
MODO=""
GRUPO_PERMITIDO="${SSH_ALLOW_GROUP:-ssh-admins}"
PORTA_DESEJADA=""
TMP_DIR=""
ACHADOS=0

#------------------------------------------------------------------------------
# Funcao: limpar
# Remove arquivos temporarios. Chamada pelo trap de saida.
#------------------------------------------------------------------------------
limpar() {
    if [[ -n "${TMP_DIR}" && -d "${TMP_DIR}" ]]; then
        rm -rf -- "${TMP_DIR}"
    fi
}
trap limpar EXIT

#------------------------------------------------------------------------------
# Funcao: log
# Registra mensagem com timestamp e nivel no stdout e no arquivo de log.
# Uso: log INFO "mensagem"
#------------------------------------------------------------------------------
log() {
    local nivel="$1"
    shift
    local mensagem="$*"
    local carimbo
    carimbo="$(date '+%Y-%m-%d %H:%M:%S')"
    local linha="${carimbo} [${nivel}] ${mensagem}"

    printf '%s\n' "${linha}"
    if [[ -w "$(dirname "${ARQUIVO_LOG}")" || -w "${ARQUIVO_LOG}" ]]; then
        printf '%s\n' "${linha}" >>"${ARQUIVO_LOG}" 2>/dev/null || true
    fi
}

#------------------------------------------------------------------------------
# Funcao: uso
# Exibe a ajuda do script.
#------------------------------------------------------------------------------
uso() {
    cat <<FIM
${NOME_SCRIPT} v${VERSAO} - Auditoria e hardening do OpenSSH (Grupo 6 - RHEL)

USO:
    ${NOME_SCRIPT} --audit
    ${NOME_SCRIPT} --apply [-g GRUPO] [-p PORTA]
    ${NOME_SCRIPT} --rollback
    ${NOME_SCRIPT} -h | --help

MODOS:
    -a, --audit         Somente le e compara. Nao altera nada.
    -A, --apply         Aplica a baseline no drop-in ${ARQ_DROPIN}.
    -r, --rollback      Restaura o ultimo backup criado por --apply.

OPCOES:
    -g, --grupo GRUPO   Grupo usado em AllowGroups (padrao: ${GRUPO_PERMITIDO}).
    -p, --porta PORTA   Define a porta do sshd. Exige rotulo SELinux e regra de
                        firewalld ja existentes; caso contrario o script recusa.
    -h, --help          Exibe esta ajuda.
    -V, --version       Exibe a versao.

CODIGOS DE SAIDA:
    0 sucesso | 1 achado | 2 erro de uso | 3 dependencia/ambiente

EXEMPLOS:
    sudo ${NOME_SCRIPT} --audit
    sudo ${NOME_SCRIPT} --apply --grupo ssh-admins
    sudo ${NOME_SCRIPT} --rollback
FIM
}

#------------------------------------------------------------------------------
# Funcao: verificar_privilegio
# Garante execucao como root (sshd -T e escrita em /etc/ssh exigem).
#------------------------------------------------------------------------------
verificar_privilegio() {
    if [[ "${EUID}" -ne 0 ]]; then
        log ERROR "Execute como root (EUID atual: ${EUID}). Use sudo."
        exit "${EXIT_DEPENDENCIA}"
    fi
}

#------------------------------------------------------------------------------
# Funcao: verificar_dependencias
# Confere a presenca de todos os binarios usados pelo script.
#------------------------------------------------------------------------------
verificar_dependencias() {
    local dependencias=(sshd systemctl awk grep sed sort cmp mktemp getent date)
    local ausentes=()
    local dep

    for dep in "${dependencias[@]}"; do
        if ! command -v "${dep}" >/dev/null 2>&1; then
            ausentes+=("${dep}")
        fi
    done

    if [[ "${#ausentes[@]}" -gt 0 ]]; then
        log ERROR "Dependencias ausentes: ${ausentes[*]}"
        exit "${EXIT_DEPENDENCIA}"
    fi
    log INFO "Dependencias verificadas: ${#dependencias[@]} binarios presentes."
}

#------------------------------------------------------------------------------
# Funcao: ler_config_efetiva
# Grava a saida de "sshd -T" em ${TMP_DIR}/efetiva.txt.
#------------------------------------------------------------------------------
ler_config_efetiva() {
    if ! sshd -T >"${TMP_DIR}/efetiva.txt" 2>"${TMP_DIR}/erro.txt"; then
        log ERROR "Nao foi possivel ler a configuracao efetiva do sshd."
        log ERROR "Detalhe: $(tr '\n' ' ' <"${TMP_DIR}/erro.txt")"
        exit "${EXIT_DEPENDENCIA}"
    fi
    log INFO "Configuracao efetiva lida com sshd -T."
}

#------------------------------------------------------------------------------
# Funcao: obter_valor
# Retorna o valor efetivo de uma diretiva (a saida de sshd -T e minuscula).
#------------------------------------------------------------------------------
obter_valor() {
    local chave="${1,,}"
    local valor
    valor="$(awk -v k="${chave}" '$1 == k {$1=""; sub(/^ /,""); print; exit}' \
        "${TMP_DIR}/efetiva.txt")"
    if [[ -z "${valor}" ]]; then
        printf '%s' "(ausente)"
    else
        printf '%s' "${valor}"
    fi
}

#------------------------------------------------------------------------------
# Funcao: comparar
# Compara valor atual com o esperado. Suporta o prefixo "<=" para numeros.
# Retorna 0 se conforme, 1 se nao conforme.
#------------------------------------------------------------------------------
comparar() {
    local atual="$1"
    local esperado="$2"

    if [[ "${esperado}" == "<="* ]]; then
        local limite="${esperado#<=}"
        if [[ "${atual}" =~ ^[0-9]+$ ]] && [[ "${atual}" -le "${limite}" ]]; then
            return 0
        fi
        return 1
    fi

    if [[ "${esperado}" == *".."* ]]; then
        local minimo="${esperado%%..*}"
        local maximo="${esperado##*..}"
        if [[ "${atual}" =~ ^[0-9]+$ ]] \
            && [[ "${atual}" -ge "${minimo}" && "${atual}" -le "${maximo}" ]]; then
            return 0
        fi
        return 1
    fi

    if [[ "${atual,,}" == "${esperado,,}" ]]; then
        return 0
    fi
    return 1
}

#------------------------------------------------------------------------------
# Funcao: auditar
# Percorre a baseline, imprime o relatorio e conta os achados.
#------------------------------------------------------------------------------
auditar() {
    local chaves=()
    local chave atual esperado situacao

    mapfile -t chaves < <(printf '%s\n' "${!BASELINE[@]}" | sort)

    printf '\n%-32s %-22s %-22s %s\n' "DIRETIVA" "ATUAL" "ESPERADO" "SITUACAO"
    printf '%s\n' "$(printf '=%.0s' {1..92})"

    for chave in "${chaves[@]}"; do
        atual="$(obter_valor "${chave}")"
        esperado="${BASELINE[${chave}]}"
        if comparar "${atual}" "${esperado}"; then
            situacao="CONFORME"
        else
            situacao="NAO-CONFORME"
            ACHADOS=$((ACHADOS + 1))
        fi
        printf '%-32s %-22s %-22s %s\n' "${chave}" "${atual}" "${esperado}" "${situacao}"
    done

    # Verificacoes adicionais que nao sao comparacao simples de valor
    auditar_allowgroups
    auditar_porta
    printf '%s\n\n' "$(printf '=%.0s' {1..92})"

    if [[ "${ACHADOS}" -eq 0 ]]; then
        log INFO "Auditoria concluida: nenhum achado."
    else
        log WARN "Auditoria concluida: ${ACHADOS} achado(s) fora da baseline."
    fi
}

#------------------------------------------------------------------------------
# Funcao: auditar_allowgroups
# AllowGroups precisa existir e o grupo precisa existir no sistema.
#------------------------------------------------------------------------------
auditar_allowgroups() {
    local atual
    atual="$(obter_valor allowgroups)"

    if [[ "${atual}" == "(ausente)" ]]; then
        printf '%-32s %-22s %-22s %s\n' "AllowGroups" "${atual}" \
            "${GRUPO_PERMITIDO}" "NAO-CONFORME"
        ACHADOS=$((ACHADOS + 1))
        return
    fi

    printf '%-32s %-22s %-22s %s\n' "AllowGroups" "${atual}" \
        "${GRUPO_PERMITIDO}" "CONFORME"

    if ! getent group "${GRUPO_PERMITIDO}" >/dev/null 2>&1; then
        log WARN "O grupo '${GRUPO_PERMITIDO}' nao existe no sistema."
    fi
}

#------------------------------------------------------------------------------
# Funcao: auditar_porta
# Informa a porta atual e se ela e a porta padrao.
#------------------------------------------------------------------------------
auditar_porta() {
    local porta
    porta="$(obter_valor port)"

    if [[ "${porta}" == "22" ]]; then
        printf '%-32s %-22s %-22s %s\n' "Port" "${porta}" "nao-padrao" "NAO-CONFORME"
        ACHADOS=$((ACHADOS + 1))
    else
        printf '%-32s %-22s %-22s %s\n' "Port" "${porta}" "nao-padrao" "CONFORME"
    fi
}

#------------------------------------------------------------------------------
# Funcao: verificar_porta_pronta
# Recusa mudanca de porta se o rotulo SELinux ou a regra de firewalld faltarem.
# Evita que o script derrube a propria sessao que o executa.
#------------------------------------------------------------------------------
verificar_porta_pronta() {
    local porta="$1"
    local pronto=0

    if command -v semanage >/dev/null 2>&1; then
        if ! semanage port -l 2>/dev/null | grep -qE "^ssh_port_t.*\b${porta}\b"; then
            log ERROR "Porta ${porta} sem rotulo ssh_port_t no SELinux."
            log ERROR "Execute antes: semanage port -a -t ssh_port_t -p tcp ${porta}"
            pronto=1
        fi
    else
        log WARN "semanage ausente (policycoreutils-python-utils). Rotulo nao verificado."
    fi

    if command -v firewall-cmd >/dev/null 2>&1; then
        # Aceita tanto "2222/tcp" (add-port) quanto 'port port="2222"' (rich rule)
        if ! firewall-cmd --list-all 2>/dev/null \
            | grep -qE "(^|[[:space:]])${porta}/tcp([[:space:]]|$)|port=\"${porta}\""; then
            log ERROR "Porta ${porta}/tcp nao liberada no firewalld."
            log ERROR "Execute antes: firewall-cmd --permanent --add-port=${porta}/tcp && firewall-cmd --reload"
            pronto=1
        fi
    else
        log WARN "firewall-cmd ausente. Regra de firewall nao verificada."
    fi

    return "${pronto}"
}

#------------------------------------------------------------------------------
# Funcao: fazer_backup
# Copia sshd_config e o diretorio de drop-ins para um backup datado.
#------------------------------------------------------------------------------
fazer_backup() {
    local carimbo destino
    carimbo="$(date '+%Y%m%d-%H%M%S')"
    destino="${DIR_BACKUP}/${carimbo}"

    mkdir -p "${destino}/sshd_config.d"
    cp -a "${ARQ_PRINCIPAL}" "${destino}/sshd_config"
    if compgen -G "${DIR_DROPIN}/*.conf" >/dev/null; then
        cp -a "${DIR_DROPIN}"/*.conf "${destino}/sshd_config.d/"
    fi
    printf '%s\n' "${carimbo}" >"${PONTEIRO_BACKUP}"

    log INFO "Backup criado em ${destino}"
}

#------------------------------------------------------------------------------
# Funcao: gerar_dropin
# Monta o conteudo desejado do drop-in em ${TMP_DIR}/dropin.novo.
# A saida e deterministica (chaves ordenadas), garantindo idempotencia.
#------------------------------------------------------------------------------
gerar_dropin() {
    local chaves=() chave esperado valor
    mapfile -t chaves < <(printf '%s\n' "${!BASELINE[@]}" | sort)

    {
        printf '# Gerado por %s v%s\n' "${NOME_SCRIPT}" "${VERSAO}"
        printf '# Baseline de hardening do Grupo 6 - RHEL\n'
        printf '# NAO EDITAR MANUALMENTE: este arquivo e reescrito a cada --apply.\n\n'

        if [[ -n "${PORTA_DESEJADA}" ]]; then
            printf 'Port %s\n' "${PORTA_DESEJADA}"
        fi
        printf 'AllowGroups %s\n' "${GRUPO_PERMITIDO}"

        for chave in "${chaves[@]}"; do
            esperado="${BASELINE[${chave}]}"
            case "${esperado}" in
                "<="*) valor="${esperado#<=}" ;;
                *..*)  valor="${esperado##*..}" ;;
                *)     valor="${esperado}" ;;
            esac
            printf '%s %s\n' "${chave}" "${valor}"
        done
    } >"${TMP_DIR}/dropin.novo"
}

#------------------------------------------------------------------------------
# Funcao: validar_e_recarregar
# Testa a sintaxe com sshd -t; em caso de falha restaura o backup e sai com 1.
#------------------------------------------------------------------------------
validar_e_recarregar() {
    if ! sshd -t 2>"${TMP_DIR}/validacao.txt"; then
        log ERROR "sshd -t reprovou a configuracao. Restaurando backup."
        log ERROR "Detalhe: $(tr '\n' ' ' <"${TMP_DIR}/validacao.txt")"
        restaurar_backup
        exit "${EXIT_ACHADO}"
    fi
    log INFO "sshd -t aprovou a configuracao."

    if systemctl reload sshd 2>"${TMP_DIR}/reload.txt"; then
        log INFO "sshd recarregado. Sessoes abertas nao foram derrubadas."
    else
        log ERROR "Falha ao recarregar o sshd: $(tr '\n' ' ' <"${TMP_DIR}/reload.txt")"
        restaurar_backup
        exit "${EXIT_ACHADO}"
    fi
}

#------------------------------------------------------------------------------
# Funcao: restaurar_backup
# Restaura o conteudo do ultimo backup registrado no ponteiro.
#------------------------------------------------------------------------------
restaurar_backup() {
    local carimbo origem

    if [[ ! -f "${PONTEIRO_BACKUP}" ]]; then
        log ERROR "Nenhum backup registrado em ${PONTEIRO_BACKUP}."
        return 1
    fi

    carimbo="$(<"${PONTEIRO_BACKUP}")"
    origem="${DIR_BACKUP}/${carimbo}"

    if [[ ! -d "${origem}" ]]; then
        log ERROR "Backup ${origem} nao encontrado."
        return 1
    fi

    cp -a "${origem}/sshd_config" "${ARQ_PRINCIPAL}"
    rm -f -- "${DIR_DROPIN}"/*.conf
    if compgen -G "${origem}/sshd_config.d/*.conf" >/dev/null; then
        cp -a "${origem}/sshd_config.d"/*.conf "${DIR_DROPIN}/"
    fi

    if command -v restorecon >/dev/null 2>&1; then
        restorecon -R /etc/ssh >/dev/null 2>&1 || true
    fi

    log INFO "Backup ${carimbo} restaurado."
    return 0
}

#------------------------------------------------------------------------------
# Funcao: aplicar
# Grava o drop-in apenas se houver diferenca, valida e recarrega o servico.
#------------------------------------------------------------------------------
aplicar() {
    if [[ -n "${PORTA_DESEJADA}" ]] && ! verificar_porta_pronta "${PORTA_DESEJADA}"; then
        log ERROR "Mudanca de porta abortada: ambiente nao preparado."
        exit "${EXIT_ACHADO}"
    fi

    if ! getent group "${GRUPO_PERMITIDO}" >/dev/null 2>&1; then
        log ERROR "Grupo '${GRUPO_PERMITIDO}' inexistente. Criar antes de aplicar"
        log ERROR "AllowGroups, sob risco de bloquear todos os acessos."
        exit "${EXIT_ACHADO}"
    fi

    mkdir -p "${DIR_DROPIN}" "${DIR_BACKUP}"
    gerar_dropin

    if [[ -f "${ARQ_DROPIN}" ]] && cmp -s "${TMP_DIR}/dropin.novo" "${ARQ_DROPIN}"; then
        log INFO "Configuracao ja esta na baseline. Nada a fazer (idempotente)."
        return
    fi

    fazer_backup
    install -o root -g root -m 0600 "${TMP_DIR}/dropin.novo" "${ARQ_DROPIN}"
    if command -v restorecon >/dev/null 2>&1; then
        restorecon "${ARQ_DROPIN}" >/dev/null 2>&1 || true
    fi
    log INFO "Drop-in gravado em ${ARQ_DROPIN}"

    validar_e_recarregar
    log WARN "Valide o acesso em uma SEGUNDA sessao antes de fechar esta."
}

#------------------------------------------------------------------------------
# Funcao: processar_parametros
# Le os argumentos da linha de comando.
#------------------------------------------------------------------------------
processar_parametros() {
    if [[ $# -eq 0 ]]; then
        uso
        exit "${EXIT_USO}"
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -a|--audit)    MODO="audit" ;;
            -A|--apply)    MODO="apply" ;;
            -r|--rollback) MODO="rollback" ;;
            -g|--grupo)
                [[ $# -ge 2 ]] || { log ERROR "Faltou o valor de $1"; exit "${EXIT_USO}"; }
                GRUPO_PERMITIDO="$2"
                shift
                ;;
            -p|--porta)
                [[ $# -ge 2 ]] || { log ERROR "Faltou o valor de $1"; exit "${EXIT_USO}"; }
                if [[ ! "$2" =~ ^[0-9]+$ ]] || [[ "$2" -lt 1 || "$2" -gt 65535 ]]; then
                    log ERROR "Porta invalida: $2"
                    exit "${EXIT_USO}"
                fi
                PORTA_DESEJADA="$2"
                shift
                ;;
            -h|--help)     uso; exit "${EXIT_OK}" ;;
            -V|--version)  printf '%s v%s\n' "${NOME_SCRIPT}" "${VERSAO}"; exit "${EXIT_OK}" ;;
            *)
                log ERROR "Parametro desconhecido: $1"
                uso
                exit "${EXIT_USO}"
                ;;
        esac
        shift
    done

    if [[ -z "${MODO}" ]]; then
        log ERROR "Escolha um modo: --audit, --apply ou --rollback."
        exit "${EXIT_USO}"
    fi
}

#------------------------------------------------------------------------------
# Funcao: main
#------------------------------------------------------------------------------
main() {
    processar_parametros "$@"
    verificar_privilegio
    verificar_dependencias

    TMP_DIR="$(mktemp -d /tmp/ssh-audit-harden.XXXXXX)"
    log INFO "Iniciando ${NOME_SCRIPT} v${VERSAO} no modo ${MODO}."

    case "${MODO}" in
        audit)
            ler_config_efetiva
            auditar
            [[ "${ACHADOS}" -eq 0 ]] && exit "${EXIT_OK}" || exit "${EXIT_ACHADO}"
            ;;
        apply)
            ler_config_efetiva
            auditar
            aplicar
            exit "${EXIT_OK}"
            ;;
        rollback)
            if restaurar_backup; then
                validar_e_recarregar
                exit "${EXIT_OK}"
            fi
            exit "${EXIT_ACHADO}"
            ;;
    esac
}

main "$@"
