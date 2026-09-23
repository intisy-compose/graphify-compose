#!/bin/bash
# Unix counterpart of docker-compose.ps1. Commands: up | down | restart | logs
cd "$(dirname "$0")"

require_setup() {
    if [ ! -f .env ]; then
        echo "No .env found - copy .env.example to .env and fill it in." >&2; exit 1
    fi
    if [ ! -f repo/Dockerfile ]; then
        echo "No build context - run: git clone https://github.com/Graphify-Labs/graphify repo" >&2; exit 1
    fi
}

show_urls() {
    echo
    echo "  MCP endpoint   : http://localhost:8770/mcp"
    echo "  Demo explorer  : http://localhost:8771/demo/graph.html"
    echo "  Any project    : http://localhost:8771/projects/<path>/graphify-out/graph.html"
}

case "${1:-up}" in
    up)      require_setup; echo "Starting graphify..."; docker compose up -d --build && show_urls ;;
    down)    echo "Stopping everything..."; docker compose down ;;
    restart) require_setup; echo "Recreating..."; docker compose up -d --build --force-recreate && show_urls ;;
    logs)    docker compose logs -f ;;
    *)
        echo "Usage: ./docker-compose.sh [up|down|restart|logs]"
        echo "  up       Build and start the stack (default)"
        echo "  down     Stop and remove everything"
        echo "  restart  Rebuild and recreate the stack"
        echo "  logs     Follow logs"
        exit 1
        ;;
esac
