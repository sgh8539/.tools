# Run mitmweb in Docker and route the current shell through it.
mitmproxy_proxy() {
    local container_name="${MITMPROXY_CONTAINER:-mitmproxy}"
    local image="${MITMPROXY_IMAGE:-mitmproxy/mitmproxy:latest}"
    local proxy_url="http://${MITMPROXY_HOST:-127.0.0.1}:${MITMPROXY_PROXY_PORT:-28080}"
    local web_url="http://${MITMPROXY_HOST:-127.0.0.1}:${MITMPROXY_WEB_PORT:-28081}"
    local action="${1:-on}"

    case "$action" in
        on)
            if ! command -v docker >/dev/null 2>&1; then
                printf '%s\n' 'docker is not installed or not on PATH' >&2
                return 1
            fi

            if docker container inspect "$container_name" >/dev/null 2>&1; then
                if [ "$(docker inspect -f '{{.State.Running}}' "$container_name" 2>/dev/null)" != true ]; then
                    docker start "$container_name" >/dev/null || return 1
                fi
            else
                docker run -d \
                    --name "$container_name" \
                    -v "$HOME/.mitmproxy:/home/mitmproxy/.mitmproxy" \
                    -p "${MITMPROXY_PROXY_PORT:-28080}:8080" \
                    -p "${MITMPROXY_WEB_PORT:-28081}:8081" \
                    "$image" \
                    mitmweb \
                    --mode regular \
                    --web-host 0.0.0.0 \
                    --web-port 8081 \
                    --set web_open_browser=false \
                    --set web_password=1234 \
                    >/dev/null || return 1
            fi

            export HTTP_PROXY="$proxy_url" HTTPS_PROXY="$proxy_url"
            export http_proxy="$proxy_url" https_proxy="$proxy_url"
            export NO_PROXY="${NO_PROXY:-localhost,127.0.0.1}"
            export no_proxy="$NO_PROXY"
            printf 'Proxy enabled: %s\nWeb UI: %s\n' "$proxy_url" "$web_url"
            ;;
        off)
            docker stop "$container_name" >/dev/null 2>&1 || true
            docker rm "$container_name" >/dev/null 2>&1 || true
            unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy
            printf '%s\n' 'Proxy disabled and mitmproxy container stopped.'
            ;;
        status)
            docker ps --filter "name=^/${container_name}$" --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
            printf 'Web UI: %s\n' "$web_url"
            ;;
        *)
            printf 'Usage: mitmproxy_proxy [on|off|status]\n' >&2
            return 2
            ;;
    esac
}
