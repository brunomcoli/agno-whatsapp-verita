#!/bin/bash

############################################################################
#
#    Agno Container Entrypoint
#
############################################################################

# Colors
ORANGE='\033[38;5;208m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

echo ""
echo -e "${ORANGE}"
cat << 'BANNER'
     █████╗  ██████╗ ███╗   ██╗ ██████╗
    ██╔══██╗██╔════╝ ████╗  ██║██╔═══██╗
    ███████║██║  ███╗██╔██╗ ██║██║   ██║
    ██╔══██║██║   ██║██║╚██╗██║██║   ██║
    ██║  ██║╚██████╔╝██║ ╚████║╚██████╔╝
    ╚═╝  ╚═╝ ╚═════╝ ╚═╝  ╚═══╝ ╚═════╝
BANNER
echo -e "${NC}"

if [[ "$PRINT_ENV_ON_LOAD" = true || "$PRINT_ENV_ON_LOAD" = True ]]; then
    echo -e "    ${DIM}Environment:${NC}"
    printenv | sed 's/^/    /'
    echo ""
fi

if [[ "$WAIT_FOR_DB" = true || "$WAIT_FOR_DB" = True ]]; then
    # A precedencia tem que ser a MESMA de db/url.py: DATABASE_URL vence DB_HOST.
    # Se o app usa DATABASE_URL mas sobrou um DB_HOST antigo no ambiente (ex: `db`
    # copiado do .env.example), esperar pelo DB_HOST trava o boot ate o timeout
    # e o healthcheck da Railway expira antes do uvicorn abrir a porta.
    DB_WAIT_TARGET=""

    if [[ -n "$DATABASE_URL" ]]; then
        DB_WAIT_TARGET="$(python - <<'PY'
from os import getenv
from urllib.parse import urlparse

parsed = urlparse(getenv("DATABASE_URL", ""))
if parsed.hostname:
    print(f"{parsed.hostname}:{parsed.port or 5432}")
PY
)"
    fi

    if [[ -z "$DB_WAIT_TARGET" && -n "$DB_HOST" ]]; then
        DB_WAIT_TARGET="${DB_HOST}:${DB_PORT:-5432}"
    fi

    # Tem que ser bem menor que o `healthcheckTimeout` do railway.json, senao a
    # espera pelo banco consome a janela inteira do healthcheck sozinha.
    DB_WAIT_TIMEOUT="${DB_WAIT_TIMEOUT:-45s}"

    if [[ -n "$DB_WAIT_TARGET" ]]; then
        echo -e "    ${DIM}Waiting for database at ${DB_WAIT_TARGET} (timeout ${DB_WAIT_TIMEOUT})...${NC}"
        if dockerize -wait "tcp://${DB_WAIT_TARGET}" -timeout "$DB_WAIT_TIMEOUT"; then
            echo -e "    ${BOLD}Database ready.${NC}"
        else
            # Nao aborta de proposito: e melhor subir e falhar com um erro de
            # Postgres legivel do que morrer aqui sem nunca abrir a porta HTTP.
            echo -e "    ${BOLD}WARNING: database unreachable at ${DB_WAIT_TARGET} after ${DB_WAIT_TIMEOUT}. Starting anyway.${NC}"
        fi
        echo ""
    else
        echo -e "    ${DIM}WAIT_FOR_DB=True, but no DATABASE_URL or DB_HOST was provided. Skipping database wait.${NC}"
    fi
fi

PORT_VALUE="${PORT:-8000}"

case "$1" in
    chill)
        echo -e "    ${DIM}Mode: chill${NC}"
        echo -e "    ${BOLD}Container running.${NC}"
        echo ""
        while true; do sleep 18000; done
        ;;
    serve)
        echo -e "    ${DIM}Mode: serve${NC}"
        echo -e "    ${BOLD}Starting AgentOS on 0.0.0.0:${PORT_VALUE}.${NC}"
        echo ""
        exec uvicorn app.main:app --host 0.0.0.0 --port "$PORT_VALUE"
        ;;
    *)
        echo -e "    ${DIM}> $@${NC}"
        echo ""
        exec "$@"
        ;;
esac
