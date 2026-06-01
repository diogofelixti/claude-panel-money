#!/bin/bash
# lib_prices.sh — tabela de preços de modelos (fonte: LiteLLM), com cache 24h e fallback.
#
# API pública:
#   load_model_prices            -> garante um arquivo de cache de preços válido; ecoa o caminho
#   model_price <modelo> <campo> -> ecoa o custo POR TOKEN (USD) do campo pedido
#                                   campos: input | output | cache_creation | cache_read
#
# Garantias:
#   - nunca trava nem demora mais que ~2s (curl com --connect-timeout 1 --max-time 2)
#   - rede falhou? usa o cache anterior. sem cache? usa a tabela mínima embutida (Opus/Sonnet/Haiku).
#   - o cache é um JSON enxuto (só os 4 preços por modelo), rápido de ler a cada render.
#
# NOTA DE LOCALE: a sessão pode rodar com LC_NUMERIC=pt_BR, onde awk/printf emitem
# vírgula decimal (1,5e-05) e geram JSON inválido. Todo awk que produz número usa
# LC_NUMERIC=C. (jq já emite ponto independente do locale.)

# Diretório de cache compartilhado com o statusline.sh
PRICES_CACHE_DIR="${PRICES_CACHE_DIR:-/tmp/claude}"
PRICES_CACHE_FILE="${PRICES_CACHE_DIR}/statusline-litellm-prices.json"
PRICES_CACHE_MAX_AGE="${PRICES_CACHE_MAX_AGE:-86400}"   # 24h
PRICES_URL="${PRICES_URL:-https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json}"

# ---- Tabela mínima embutida (por 1M tokens) ---------------------------------
# Usada só quando não há rede E não há cache anterior. Valores por 1M; convertidos
# para por-token ao gravar. Opus reflete o preço atual (4.5+: $5/$25); Opus 4/4.1
# antigos eram $15/$75, mas este fallback só age offline-sem-cache e os modelos
# atuais usam esta faixa. cache_creation/cache_read = preços 5m da Anthropic.
# Formato: "chave  input  output  cache_creation  cache_read"
_embedded_prices() {
    cat <<'EOF'
opus    5   25  6.25   0.50
sonnet  3   15  3.75   0.30
haiku   1   5   1.25   0.10
EOF
}

# Constrói o JSON enxuto da tabela embutida (custos por token).
# LC_NUMERIC=C: garante ponto decimal (sob pt_BR o awk emitiria vírgula -> JSON inválido).
_embedded_prices_json() {
    _embedded_prices | LC_NUMERIC=C awk '
        BEGIN { printf "{\"source\":\"embedded\",\"models\":{" ; first=1 }
        {
            if (!first) printf ","
            first=0
            printf "\"%s\":{\"input\":%.10g,\"output\":%.10g,\"cache_creation\":%.10g,\"cache_read\":%.10g}", \
                $1, $2/1e6, $3/1e6, $4/1e6, $5/1e6
        }
        END { printf "}}" }
    '
}

# Idade em segundos de um arquivo (GNU stat -c, fallback BSD stat -f). Retorna !=0 se não existe.
_file_age() {
    local f="$1" mtime now
    [ -f "$f" ] || return 1
    mtime=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null) || return 1
    now=$(date +%s)
    echo $(( now - mtime ))
}

# Filtra o JSON gigante do LiteLLM (~2700 modelos) para o cache enxuto: só modelos
# que tenham os custos de input E output, guardando os 4 preços por token.
# Lê de stdin (JSON do LiteLLM), ecoa o JSON enxuto. Retorna !=0 se entrada inválida.
_slim_from_litellm() {
    jq -c '
        { source: "litellm",
          fetched_at: (now | floor),
          models: (
            to_entries
            | map(select(.value.input_cost_per_token != null and .value.output_cost_per_token != null))
            | map({ key: .key, value: {
                  input:          (.value.input_cost_per_token          // 0),
                  output:         (.value.output_cost_per_token         // 0),
                  cache_creation: (.value.cache_creation_input_token_cost // (.value.input_cost_per_token * 1.25)),
                  cache_read:     (.value.cache_read_input_token_cost     // (.value.input_cost_per_token * 0.10))
              }})
            | from_entries
          )
        }
    ' 2>/dev/null
}

# Garante um arquivo de cache de preços válido e ecoa seu caminho.
# Estratégia: cache fresco -> usa. Stale/ausente -> tenta baixar (com stampede-lock).
# Falhou o download -> mantém cache antigo se existir, senão grava a tabela embutida.
load_model_prices() {
    mkdir -p "$PRICES_CACHE_DIR" 2>/dev/null

    local age
    age=$(_file_age "$PRICES_CACHE_FILE")
    # Cache fresco e válido: caminho rápido, sem rede.
    if [ -n "$age" ] && [ "$age" -lt "$PRICES_CACHE_MAX_AGE" ] \
       && [ -s "$PRICES_CACHE_FILE" ] && jq -e '.models' "$PRICES_CACHE_FILE" >/dev/null 2>&1; then
        echo "$PRICES_CACHE_FILE"
        return 0
    fi

    # Precisa atualizar. Stampede-lock: toca o arquivo pra outros panes não baixarem junto.
    touch "$PRICES_CACHE_FILE" 2>/dev/null

    local raw slim
    raw=$(curl -s --connect-timeout 1 --max-time 2 "$PRICES_URL" 2>/dev/null)
    if [ -n "$raw" ]; then
        slim=$(printf '%s' "$raw" | _slim_from_litellm)
        if [ -n "$slim" ] && printf '%s' "$slim" | jq -e '.models | length > 0' >/dev/null 2>&1; then
            printf '%s' "$slim" > "$PRICES_CACHE_FILE"
            echo "$PRICES_CACHE_FILE"
            return 0
        fi
    fi

    # Download falhou. Cache anterior ainda serve? (não-vazio e com .models)
    if [ -s "$PRICES_CACHE_FILE" ] && jq -e '.models | length > 0' "$PRICES_CACHE_FILE" >/dev/null 2>&1; then
        echo "$PRICES_CACHE_FILE"
        return 0
    fi

    # Sem rede e sem cache: grava a tabela embutida (e usa).
    _embedded_prices_json > "$PRICES_CACHE_FILE" 2>/dev/null
    echo "$PRICES_CACHE_FILE"
    return 0
}

# Ecoa o custo por token (USD) de <modelo>/<campo>.
# Tenta o nome exato no cache; se faltar, casa por família (opus/sonnet/haiku)
# contra a tabela embutida — cobre modelos novos ainda ausentes no LiteLLM. Ecoa 0 se nada casar.
model_price() {
    local model="$1" field="$2"
    case "$field" in input|output|cache_creation|cache_read) ;; *) echo 0; return 1 ;; esac

    local file val
    file=$(load_model_prices)

    # 1) nome exato
    val=$(jq -r --arg m "$model" --arg f "$field" '.models[$m][$f] // empty' "$file" 2>/dev/null)
    if [ -n "$val" ]; then echo "$val"; return 0; fi

    # 2) família embutida (sempre disponível)
    local fam=""
    case "$model" in
        *opus*)   fam="opus" ;;
        *sonnet*) fam="sonnet" ;;
        *haiku*)  fam="haiku" ;;
    esac
    if [ -n "$fam" ]; then
        val=$(_embedded_prices | LC_NUMERIC=C awk -v fam="$fam" -v f="$field" '
            $1==fam {
                if (f=="input")               printf "%.10g", $2/1e6;
                else if (f=="output")         printf "%.10g", $3/1e6;
                else if (f=="cache_creation") printf "%.10g", $4/1e6;
                else if (f=="cache_read")     printf "%.10g", $5/1e6;
            }')
        [ -n "$val" ] && { echo "$val"; return 0; }
    fi

    echo 0
    return 1
}

# Execução direta (./lib_prices.sh): mostra um resumo legível.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    f=$(load_model_prices)
    src=$(jq -r '.source' "$f" 2>/dev/null)
    n=$(jq -r '.models | length' "$f" 2>/dev/null)
    echo "cache: $f"
    echo "fonte: $src | modelos: $n"
fi
