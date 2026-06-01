#!/bin/bash
# lib_fx.sh — cotação USD->BRL do dia, com cache 6h e fallback.
#
# API pública:
#   usd_brl   -> ecoa a cotação USD->BRL (ponto decimal). Nunca falha; sempre ecoa um número.
#
# Fallback (mesma escada do lib_prices.sh):
#   API ok -> usa e cacheia. API falhou -> cache anterior. Sem cache -> default embutido (5.40).
#
# Garantias:
#   - nunca trava nem demora mais que ~2s (curl --connect-timeout 1 --max-time 2)
#   - LC_NUMERIC=C em todo awk que formata número (sob pt_BR o awk emitiria vírgula).

# Cache compartilhado com o statusline.sh / lib_prices.sh
FX_CACHE_DIR="${FX_CACHE_DIR:-/tmp/claude}"
FX_CACHE_FILE="${FX_CACHE_DIR}/statusline-usdbrl.txt"
FX_CACHE_MAX_AGE="${FX_CACHE_MAX_AGE:-21600}"   # 6h
FX_DEFAULT="${FX_DEFAULT:-5.40}"                 # default embutido (offline e sem cache)
FX_URL="${FX_URL:-https://economia.awesomeapi.com.br/last/USD-BRL}"

# Verdadeiro se $1 parece um número positivo plausível para cotação (ex.: 5.0347).
# Evita cachear "null", strings de erro ou zero.
_fx_is_valid() {
    local v="$1"
    [ -n "$v" ] || return 1
    LC_NUMERIC=C awk -v v="$v" 'BEGIN{ if (v+0 > 0) exit 0; else exit 1 }'
}

# Idade em segundos de um arquivo (GNU stat -c, fallback BSD stat -f). Retorna !=0 se não existe.
_fx_file_age() {
    local f="$1" mtime now
    [ -f "$f" ] || return 1
    mtime=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null) || return 1
    now=$(date +%s)
    echo $(( now - mtime ))
}

# Ecoa a cotação USD->BRL. Sempre ecoa um número válido (no pior caso, o default).
usd_brl() {
    mkdir -p "$FX_CACHE_DIR" 2>/dev/null

    local age cached
    age=$(_fx_file_age "$FX_CACHE_FILE")
    cached=$(cat "$FX_CACHE_FILE" 2>/dev/null)

    # Cache fresco e válido: caminho rápido, sem rede.
    if [ -n "$age" ] && [ "$age" -lt "$FX_CACHE_MAX_AGE" ] && _fx_is_valid "$cached"; then
        echo "$cached"
        return 0
    fi

    # Precisa atualizar. Stampede-lock: toca o arquivo pra outros panes não baixarem junto.
    touch "$FX_CACHE_FILE" 2>/dev/null

    local resp rate
    resp=$(curl -s --connect-timeout 1 --max-time 2 "$FX_URL" 2>/dev/null)
    if [ -n "$resp" ]; then
        rate=$(printf '%s' "$resp" | jq -r '.USDBRL.bid // empty' 2>/dev/null)
        if _fx_is_valid "$rate"; then
            printf '%s' "$rate" > "$FX_CACHE_FILE"
            echo "$rate"
            return 0
        fi
    fi

    # API falhou. Cache anterior ainda serve? (mesmo que stale — melhor que default)
    if _fx_is_valid "$cached"; then
        echo "$cached"
        return 0
    fi

    # Sem rede e sem cache: default embutido.
    echo "$FX_DEFAULT"
    return 0
}

# Execução direta (./lib_fx.sh): mostra a cotação e a fonte provável.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    rate=$(usd_brl)
    echo "USD->BRL: $rate"
fi
