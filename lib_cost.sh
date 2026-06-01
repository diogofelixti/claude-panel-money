#!/bin/bash
# lib_cost.sh — cálculo de custo estimado (USD->BRL) varrendo os JSONL do Claude Code.
#
# Depende de: lib_prices.sh (model_price/load_model_prices) e lib_fx.sh (usd_brl).
#
# API pública:
#   compute_costs [cwd]  -> ecoa JSON (cacheado 60s):
#       {"session_brl":N,"today_brl":N,"session_usd":N,"today_usd":N,"rate":N,"at":epoch}
#     - session = TODAS as sessões do projeto atual (pasta derivada do cwd)
#     - today   = TODOS os projetos, só registros com data LOCAL de hoje
#
# Regras:
#   - por registro assistant, soma os 4 contadores x preço do modelo daquele registro (LiteLLM)
#   - modelo desconhecido (sem preço): ignorado, não quebra
#   - nunca trava: na pior das hipóteses ecoa zeros; varredura é gated por cache de 60s

# Resolve diretório das libs irmãs e carrega se ainda não estiverem em memória.
_COST_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
command -v load_model_prices >/dev/null 2>&1 || source "${_COST_LIB_DIR}/lib_prices.sh"
command -v usd_brl           >/dev/null 2>&1 || source "${_COST_LIB_DIR}/lib_fx.sh"

PROJECTS_DIR="${PROJECTS_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects}"
COST_CACHE_DIR="${COST_CACHE_DIR:-/tmp/claude}"
COST_CACHE_MAX_AGE="${COST_CACHE_MAX_AGE:-60}"   # 60s

# Idade em segundos de um arquivo (GNU stat -c, fallback BSD stat -f). Retorna !=0 se não existe.
_cost_file_age() {
    local f="$1" mtime now
    [ -f "$f" ] || return 1
    mtime=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null) || return 1
    now=$(date +%s)
    echo $(( now - mtime ))
}

# Encoding do cwd -> nome da pasta em ~/.claude/projects (Claude Code troca / . _ por -).
_encode_project_dir() {
    printf '%s' "$1" | sed 's#[/._]#-#g'
}

# Programa jq compartilhado: soma o custo USD dos registros assistant recebidos.
# Args jq: --slurpfile P <prices>  --arg today <YYYY-MM-DD|"">  (today vazio = sem filtro de data)
# Lookup de preço: nome exato -> família (opus/sonnet/haiku) -> null (ignora).
_COST_JQ='
  ($P[0].models) as $models
  | def price($model):
      ($models[$model])
      // (if   ($model|test("opus"))   then $models["opus"]
          elif ($model|test("sonnet")) then $models["sonnet"]
          elif ($model|test("haiku"))  then $models["haiku"]
          else null end);
  def localdate:
      (try (gsub("\\.[0-9]+";"") | fromdateiso8601 | localtime | strftime("%Y-%m-%d")) catch "");
  reduce (inputs
          | select(.type=="assistant")
          | select($today=="" or ((.timestamp // "") | localdate) == $today)
         ) as $r
    (0;
       . + ( ($r.message.model // "") as $mdl
             | (price($mdl)) as $p
             | if $p == null then 0
               else
                 (($r.message.usage.input_tokens                 // 0) * ($p.input          // 0))
               + (($r.message.usage.output_tokens                // 0) * ($p.output         // 0))
               + (($r.message.usage.cache_creation_input_tokens  // 0) * ($p.cache_creation // 0))
               + (($r.message.usage.cache_read_input_tokens      // 0) * ($p.cache_read     // 0))
               end ))
'

# Soma USD de um conjunto de arquivos JSONL. $1=prices_file $2=today(filtro) $3..=arquivos.
# Ecoa 0 se não houver arquivos ou se jq falhar.
_sum_usd() {
    local prices="$1" today="$2"; shift 2
    [ "$#" -eq 0 ] && { echo 0; return 0; }
    local v
    v=$(jq -n -L /dev/null --slurpfile P "$prices" --arg today "$today" "$_COST_JQ" "$@" 2>/dev/null)
    _cost_is_num "$v" && echo "$v" || echo 0
}

_cost_is_num() { [ -n "$1" ] && LC_NUMERIC=C awk -v v="$1" 'BEGIN{ if (v==v+0) exit 0; else exit 1 }' 2>/dev/null; }

# Núcleo da varredura (sem cache). $1=cwd. Ecoa o JSON de resultado.
_compute_costs_raw() {
    local cwd="$1"
    local prices rate today proj_dir
    prices=$(load_model_prices)
    rate=$(usd_brl)
    _cost_is_num "$rate" || rate="5.40"
    today=$(date +%Y-%m-%d)

    # (a) sessão = todas as sessões do projeto atual
    local session_usd=0
    if [ -n "$cwd" ]; then
        proj_dir="${PROJECTS_DIR}/$(_encode_project_dir "$cwd")"
        if [ -d "$proj_dir" ]; then
            local pfiles=()
            while IFS= read -r -d '' file; do pfiles+=("$file"); done \
                < <(find "$proj_dir" -maxdepth 1 -type f -name '*.jsonl' -print0 2>/dev/null)
            session_usd=$(_sum_usd "$prices" "" "${pfiles[@]}")
        fi
    fi

    # (b) hoje = todos os projetos, só registros de hoje.
    # Pré-filtro por mtime: arquivo não modificado hoje não pode conter registros de hoje.
    local today_usd=0 tfiles=()
    if [ -d "$PROJECTS_DIR" ]; then
        while IFS= read -r -d '' file; do tfiles+=("$file"); done \
            < <(find "$PROJECTS_DIR" -type f -name '*.jsonl' -newermt "${today} 00:00:00" -print0 2>/dev/null)
        today_usd=$(_sum_usd "$prices" "$today" "${tfiles[@]}")
    fi

    # Converte para BRL (LC_NUMERIC=C: locale pt_BR usaria vírgula e quebraria o JSON).
    local session_brl today_brl
    session_brl=$(LC_NUMERIC=C awk -v u="$session_usd" -v r="$rate" 'BEGIN{printf "%.4f", u*r}')
    today_brl=$(LC_NUMERIC=C awk -v u="$today_usd"   -v r="$rate" 'BEGIN{printf "%.4f", u*r}')
    session_usd=$(LC_NUMERIC=C awk -v u="$session_usd" 'BEGIN{printf "%.6f", u}')
    today_usd=$(LC_NUMERIC=C awk -v u="$today_usd"   'BEGIN{printf "%.6f", u}')

    printf '{"session_brl":%s,"today_brl":%s,"session_usd":%s,"today_usd":%s,"rate":%s,"at":%s}\n' \
        "$session_brl" "$today_brl" "$session_usd" "$today_usd" "$rate" "$(date +%s)"
}

# API pública: ecoa o JSON de custos, cacheado por 60s (por projeto).
compute_costs() {
    local cwd="${1:-$PWD}"
    mkdir -p "$COST_CACHE_DIR" 2>/dev/null
    local key cache age cached
    key=$(printf '%s' "$cwd" | { sha256sum 2>/dev/null || shasum -a 256 2>/dev/null; } | cut -c1-8)
    cache="${COST_CACHE_DIR}/statusline-cost-${key}.json"

    age=$(_cost_file_age "$cache")
    cached=$(cat "$cache" 2>/dev/null)
    if [ -n "$age" ] && [ "$age" -lt "$COST_CACHE_MAX_AGE" ] \
       && [ -n "$cached" ] && printf '%s' "$cached" | jq -e '.session_brl' >/dev/null 2>&1; then
        printf '%s\n' "$cached"
        return 0
    fi

    local result
    result=$(_compute_costs_raw "$cwd")
    if printf '%s' "$result" | jq -e '.session_brl' >/dev/null 2>&1; then
        printf '%s' "$result" > "$cache"
        printf '%s\n' "$result"
    elif [ -n "$cached" ]; then
        printf '%s\n' "$cached"   # recompute falhou: serve cache antigo
    else
        echo '{"session_brl":0,"today_brl":0,"session_usd":0,"today_usd":0,"rate":0,"at":0}'
    fi
}

# Execução direta: mostra um resumo legível.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    j=$(compute_costs "${1:-$PWD}")
    echo "$j" | jq -r '"sessão (projeto): R$ \(.session_brl)  |  hoje (todos): R$ \(.today_brl)  |  câmbio: \(.rate)  (USD sessão=\(.session_usd))"'
fi
