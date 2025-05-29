#!/usr/bin/env bash
source /opt/includes.sh

cPrint info "Starting up the container..."

# File where the JSON configuration will be stored
CADDY_CONFIG_JSON="/etc/caddy/config.json"

# Host routes configuration file
HOST_ROUTES_CONF="/opt/host-routes.conf"

# File to track host routes for cleaning up
HOST_ROUTES_TRACKER="/tmp/host_routes_tracker.txt"

# File to store the domain mappings list
DOMAIN_MAPPINGS_FILE="/opt/domain_mappings.txt"

# Access log file path
ACCESS_LOG_FILE="/data/access.log"

# Error pages directory
ERROR_PAGES_DIR="/opt/error_pages"

# Function to truncate text and add ellipsis if needed
truncate_text() {
    local text="$1"
    local max_length="$2"

    if [ ${#text} -gt $max_length ]; then
        echo "${text:0:$((max_length-3))}..."
    else
        echo "$text"
    fi
}

# Function to start Caddy and wait for it to be ready
start_caddy() {
    local config_file=$1
    local max_attempts=5
    local attempt=1
    local delay=2

    cPrint info "Starting Caddy..."
    caddy start --config "$config_file"
    cPrint info "Waiting for Caddy to be ready..."

    while [ $attempt -le $max_attempts ]; do
        sleep $delay
        if curl -s -o /dev/null -w "%{http_code}" http://localhost:2019/config/ &>/dev/null; then
            cPrint info "Caddy is ready and admin API is accessible."
            return 0
        fi
        cPrint warning "Attempt $attempt: Caddy admin API not yet accessible. Waiting ${delay}s..."
        delay=$((delay * 2))
        attempt=$((attempt + 1))
    done
    cPrint warning "Caddy may not be fully started after $max_attempts attempts, but will continue."
    return 0
}

# Function to reload Caddy with retries
reload_caddy() {
    local max_attempts=5
    local attempt=1
    local delay=1
    local config_file=$1

    cPrint info "Reloading Caddy..."
    while [ $attempt -le $max_attempts ]; do
        caddy reload --config "$config_file" 2>/dev/null
        if [ $? -eq 0 ]; then
            cPrint info "Caddy reloaded successfully on attempt $attempt."
            return 0
        fi
        cPrint warning "Attempt $attempt to reload Caddy failed. Waiting ${delay}s before retry..."
        sleep $delay
        delay=$((delay * 2))
        attempt=$((attempt + 1))
    done

    cPrint error "Failed to reload Caddy after $max_attempts attempts."
    cPrint info "Checking Caddy admin API status..."
    if curl -s -o /dev/null -w "%{http_code}" http://localhost:2019/config/ &>/dev/null; then
        cPrint info "Admin API appears to be running now."
    else
        cPrint error "Admin API is not responding. Caddy may need to be restarted."
        cPrint info "Attempting to restart Caddy..."
        caddy stop
        sleep 2
        caddy start --config "$config_file"
    fi
    return 1
}

# Function to validate JSON before writing to configuration file
validate_and_write_config() {
    local config="$1"
    local output_file="$2"
    local temp_file=$(mktemp)
    echo "$config" > "$temp_file"

    if jq '.' "$temp_file" > /dev/null 2>&1; then
        # JSON is valid, write to the actual config file
        cat "$temp_file" > "$output_file"
        rm "$temp_file"
        return 0
    else
        # JSON is invalid, log error and keep the old config
        cPrint error "Invalid JSON configuration generated. Keeping previous configuration."
        cPrint error "This is likely a bug in DomainPilot. Please report this issue."
        if [ "${DEBUG}" == "1" ]; then
            cPrint error "Invalid JSON:"
            cat "$temp_file"
        fi
        rm "$temp_file"
        return 1
    fi
}

# Function to debug the current Caddy configuration
debug_caddy_config() {
    cPrint info "Debugging Caddy configuration..."

    if [ ! -f "$CADDY_CONFIG_JSON" ]; then
        cPrint error "Caddy configuration file not found at $CADDY_CONFIG_JSON"
        return 1
    fi

    if [ ! -d "$ERROR_PAGES_DIR" ]; then
        cPrint warning "Error pages directory not found at $ERROR_PAGES_DIR. Creating it."
        mkdir -p "$ERROR_PAGES_DIR"
    fi

    cPrint info "Error pages in $ERROR_PAGES_DIR:"
    ls -la "$ERROR_PAGES_DIR"

    local error_handlers=$(jq '.apps.http.servers.srv0.errors' "$CADDY_CONFIG_JSON")
    cPrint info "Error handlers configuration:"
    echo "$error_handlers" | jq .

    cPrint info "Caddy status:"
    caddy status 2>/dev/null || cPrint info "Status command not available in this version of Caddy"
}

# Function to list all domain mappings and save to a file
list_domain_mappings() {
    cPrint info "Listing all domain mappings..."
    > "$DOMAIN_MAPPINGS_FILE"

    local domain_col_width=40
    local target_col_width=35
    local total_width=$((domain_col_width + target_col_width + 7))

    print_line() {
        printf -v line '%*s' "$total_width" ""; echo -e "${line// /$1}" >> "$DOMAIN_MAPPINGS_FILE"
    }
    print_header_line() {
        local text="$1"; local padding=$((total_width - ${#text} - 2)); local lp=$((padding / 2)); local rp=$((padding - lp))
        printf "║%*s%s%*s║\n" "$lp" "" "$text" "$rp" "" >> "$DOMAIN_MAPPINGS_FILE"
    }

    print_line "═"
    print_header_line "DomainPilot Mappings"
    echo -e "╠═$(printf '%.0s═' $(seq 1 $domain_col_width))═╦═$(printf '%.0s═' $(seq 1 $target_col_width))═╣" >> "$DOMAIN_MAPPINGS_FILE"
    echo -e "║ $(printf "%-${domain_col_width}s" "Domain") ║ $(printf "%-${target_col_width}s" "Target") ║" >> "$DOMAIN_MAPPINGS_FILE"
    echo -e "╠═$(printf '%.0s═' $(seq 1 $domain_col_width))═╬═$(printf '%.0s═' $(seq 1 $target_col_width))═╣" >> "$DOMAIN_MAPPINGS_FILE"

    local current_config=$(cat "$CADDY_CONFIG_JSON")
    # Exclude healthcheck and the *.docker.local catch-all for not_configured.html
    local routes=$(jq -c '.apps.http.servers.srv0.routes[] | select(
        ((.match[0].path[0]? != "/_healthz") or (.match[0].host[]? != "localhost")) and
        ((.match[0].host[]? != "*.docker.local") or (.handle[0].uri? != "/not_configured.html")) and
        (.handle[].handler == "reverse_proxy") # Only show reverse proxy routes
    )' <<< "$current_config")
    local found_routes=0

    while IFS= read -r route; do
        local domain=$(jq -r '.match[].host[]?' <<< "$route" 2>/dev/null)
        if [ -z "$domain" ]; then continue; fi

        local display_domain=$(truncate_text "$domain" $((domain_col_width - 1)))
        local target_info=$(jq -r '.handle[].upstreams[].dial' <<< "$route" 2>/dev/null)
        local target_text
        if [[ "$target_info" == host.docker.internal:* ]]; then
            target_text="localhost:${target_info#host.docker.internal:}"
        else
            target_text="container: $target_info"
        fi
        local display_target=$(truncate_text "$target_text" $((target_col_width - 1)))
        echo -e "║ $(printf "%-${domain_col_width}s" "$display_domain") ║ $(printf "%-${target_col_width}s" "$display_target") ║" >> "$DOMAIN_MAPPINGS_FILE"
        found_routes=1
    done <<< "$routes"

    if [ $found_routes -eq 0 ]; then
        echo -e "║ $(printf "%-${domain_col_width}s" "No domains configured yet") ║ $(printf "%-${target_col_width}s" "Add some in host-routes.conf") ║" >> "$DOMAIN_MAPPINGS_FILE"
    fi
    print_line "═" # This should be the bottom line, using ╚ and ╩
    # Corrected bottom line:
    echo -e "╚═$(printf '%.0s═' $(seq 1 $domain_col_width))═╩═$(printf '%.0s═' $(seq 1 $target_col_width))═╝" >> "$DOMAIN_MAPPINGS_FILE"

    cat "$DOMAIN_MAPPINGS_FILE"
}

# Function to ensure error handlers are properly configured
ensure_error_handlers() {
    cPrint info "Ensuring error handlers are configured..."

    if [ ! -f "$CADDY_CONFIG_JSON" ]; then
        cPrint info "Config file doesn't exist. Creating initial configuration first."
        create_initial_config
        return 0
    fi

    local current_config=$(cat "$CADDY_CONFIG_JSON")
    if [ -z "$current_config" ] || ! jq '.' <<< "$current_config" > /dev/null 2>&1; then
        cPrint error "Invalid or empty JSON in config file. Creating new configuration."
        create_initial_config
        return 0
    fi

    if ! jq 'has("apps") and (.apps | has("http")) and (.apps.http | has("servers")) and (.apps.http.servers | has("srv0"))' <<< "$current_config" | grep -q "true"; then
        cPrint info "Basic configuration structure missing or incomplete. Creating new configuration."
        create_initial_config
        return 0
    fi

    if ! jq '.apps.http.servers.srv0 | has("errors")' <<< "$current_config" 2>/dev/null | grep -q "true"; then
        cPrint info "Error handling configuration missing. Adding it..."
        local new_config=$(jq '.apps.http.servers.srv0.errors = {
            "routes": [
                {"handle": [{"handler": "rewrite", "uri": "/{http.error.status_code}.html"}]},
                {"handle": [{"handler": "file_server", "root": "'"$ERROR_PAGES_DIR"'", "index_names": []}]}
            ]
        }' <<< "$current_config")

        if validate_and_write_config "$new_config" "$CADDY_CONFIG_JSON"; then
            cPrint info "Error handling configuration added successfully. Reloading Caddy."
            reload_caddy "$CADDY_CONFIG_JSON"
        else
            cPrint error "Failed to add error handling configuration."
            return 1
        fi
    else
        cPrint info "Error handlers already configured."
    fi
    return 0
}

# Function to ensure error pages exist (now simplified)
setup_error_pages() {
    cPrint info "Setting up error pages..."
    # Ensure the directory exists, though it should be mounted or created by Dockerfile
    if [ ! -d "$ERROR_PAGES_DIR" ]; then
        cPrint warning "Error pages directory '$ERROR_PAGES_DIR' not found. Creating it."
        cPrint warning "Please ensure error HTML files (40x.html, 50x.html, generic.html, not_configured.html) are present in this directory."
        mkdir -p "$ERROR_PAGES_DIR"
    fi

    cPrint info "Available error pages in $ERROR_PAGES_DIR:"
    ls -la "$ERROR_PAGES_DIR"
}

# Function to fix error handlers
fix_error_handlers() {
    cPrint info "Fixing error handlers configuration..."
    if [ ! -f "$CADDY_CONFIG_JSON" ]; then
        cPrint error "Caddy configuration file not found. Cannot fix handlers."
        create_initial_config # Attempt to create a base config
        return 1
    fi
    local current_config=$(cat "$CADDY_CONFIG_JSON")
    local error_routes_json='[
        {"handle": [{"handler": "rewrite", "uri": "/{http.error.status_code}.html"}]},
        {"handle": [{"handler": "file_server", "root": "'"$ERROR_PAGES_DIR"'", "index_names": []}]}
    ]'
    local new_config=$(jq --argjson er "$error_routes_json" '.apps.http.servers.srv0.errors.routes = $er' <<< "$current_config")

    if validate_and_write_config "$new_config" "$CADDY_CONFIG_JSON"; then
        cPrint info "Error handlers successfully fixed. Reloading Caddy."
        reload_caddy "$CADDY_CONFIG_JSON"
        return 0
    else
        cPrint error "Failed to fix error handlers."
        return 1
    fi
}

# Function to create initial Caddy configuration
create_initial_config() {
    cPrint info "Creating initial Caddy JSON configuration."

    local healthcheck_route_json='{
        "match": [{"host": ["localhost"], "path": ["/_healthz"]}],
        "handle": [{"handler": "static_response", "status_code": 200, "body": "OK"}],
        "terminal": true
    }'
    local wildcard_catch_all_route_json='{
        "match": [{"host": ["*.docker.local"]}],
        "handle": [
            {"handler": "rewrite", "uri": "/not_configured.html"},
            {"handler": "file_server", "root": "'"$ERROR_PAGES_DIR"'"}
        ],
        "terminal": true
    }'

    local initial_json_template='{
        "admin": {"listen": "localhost:2019"},
        "logging": {
            "logs": {
                "default": {"level": "DEBUG"},
                "access": {
                    "level": "INFO",
                    "writer": {"output": "file", "filename": "'"${ACCESS_LOG_FILE}"'"},
                    "encoder": {"format": "json"}
                }
            }
        },
        "apps": {
            "http": {
                "servers": {
                    "srv0": {
                        "listen": [":80", ":443"],
                        "routes": [],
                        "logs": {"logger_names": {"*": "access"}},
                        "errors": {
                            "routes": [
                                {"handle": [{"handler": "rewrite", "uri": "/{http.error.status_code}.html"}]},
                                {"handle": [{"handler": "file_server", "root": "'"$ERROR_PAGES_DIR"'", "index_names": []}]}
                            ]
                        }
                    }
                }
            },
            "tls": {
                "automation": {
                    "policies": [
                        {
                            "subjects": ["*.docker.local", "localhost"],
                            "issuers": [{"module": "internal", "ca": "local", "lifetime": "87600h"}]
                        }
                    ]
                }
            }
        }
    }'
    # Add routes in specific order: healthcheck first, then wildcard catch-all
    jq --argjson hr "$healthcheck_route_json" --argjson wc "$wildcard_catch_all_route_json" \
       '.apps.http.servers.srv0.routes = [$hr, $wc]' <<< "$initial_json_template" > "$CADDY_CONFIG_JSON"

    cPrint info "Caddy JSON configuration created at $CADDY_CONFIG_JSON"
}

# Function to update Caddy JSON configuration for containers
update_caddy_json_config() {
    local container_name=$1
    local action=$2

    local domain=$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$container_name" | grep 'DOMAINPILOT_VHOST=' | cut -d '=' -f2)
    if [ -z "$domain" ]; then
        cPrint info "No DOMAINPILOT_VHOST found for container $cL_info$container_name$cl_reset"
        return
    fi

    local container_port=$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$container_name" | grep 'DOMAINPILOT_CONTAINER_PORT=' | cut -d '=' -f2)
    container_port=${container_port:-80} # Default to port 80 if not set
    cPrint info "Container $cL_info$container_name$cl_reset: domain=$cL_info$domain$cl_reset, port=$cL_info$container_port$cl_reset, action=$cL_info$action$cl_reset"

    local current_config=$(cat "$CADDY_CONFIG_JSON")
    local new_config

    if [ "$action" == "start" ]; then
        # Check if a route for this domain already exists
        if jq -e --arg d "$domain" '.apps.http.servers.srv0.routes[] | select(.match[].host[]? == $d)' <<< "$current_config" > /dev/null; then
            cPrint info "Domain $cL_info$domain$cl_reset already exists in configuration. Skipping."
            return
        fi

        cPrint info "Adding route for $cL_info$domain$cl_reset -> $cL_info$container_name:$container_port$cl_reset"
        local new_route_json=$(jq -n --arg d "$domain" --arg cn "$container_name" --arg cp "$container_port" \
            '{match: [{"host": [$d]}], handle: [{"handler": "reverse_proxy", "upstreams": [{"dial": ($cn + ":" + $cp)}]}], terminal: true}')

        # Find the index of the wildcard catch-all route ("*.docker.local")
        # It's usually the last one before we start adding specific routes, or second if only healthcheck exists.
        local catch_all_index=$(jq '.apps.http.servers.srv0.routes | map(.match[0].host[]? == "*.docker.local") | index(true)' <<< "$current_config")

        if [ "$catch_all_index" == "null" ] || [ "$catch_all_index" -lt 0 ]; then
             # Should not happen if initial_config ran, but as a fallback, add to end.
            new_config=$(jq --argjson nr "$new_route_json" '.apps.http.servers.srv0.routes += [$nr]' <<< "$current_config")
        else
            # Insert the new route just BEFORE the wildcard catch-all
            new_config=$(jq --argjson nr "$new_route_json" --argjson index "$catch_all_index" \
                '.apps.http.servers.srv0.routes = (.apps.http.servers.srv0.routes[:($index|tonumber)] + [$nr] + .apps.http.servers.srv0.routes[($index|tonumber):])' <<< "$current_config")
        fi

        # TLS policy (if not *.docker.local or localhost)
        local is_docker_local=$(echo "$domain" | grep -c "\.docker\.local$")
        if [ "$is_docker_local" -eq "0" ] && [ "$domain" != "localhost" ]; then
            if ! jq -e --arg d "$domain" '.apps.tls.automation.policies[] | select(.subjects[]? == $d)' <<< "$new_config" > /dev/null; then
                cPrint info "Adding TLS policy for $cL_info$domain$cl_reset"
                new_config=$(jq --arg d "$domain" '.apps.tls.automation.policies += [{"subjects": [$d], "issuers": [{"module": "internal", "lifetime": "87600h"}]}]' <<< "$new_config")
            fi
        fi

    elif [ "$action" == "die" ]; then
        cPrint info "Removing route for $cL_info$domain$cl_reset"
        new_config=$(jq --arg d "$domain" 'del(.apps.http.servers.srv0.routes[] | select(.match[].host[]? == $d))' <<< "$current_config")

        # Remove TLS policy if it's not *.docker.local or localhost and no other route uses this specific domain
        local is_docker_local=$(echo "$domain" | grep -c "\.docker\.local$")
        if [ "$is_docker_local" -eq "0" ] && [ "$domain" != "localhost" ]; then
             # Check if any other route still uses this domain before removing policy
            if ! jq -e --arg d "$domain" '.apps.http.servers.srv0.routes[] | select(.match[].host[]? == $d)' <<< "$new_config" > /dev/null; then
                cPrint info "Removing TLS policy for $cL_info$domain$cl_reset"
                new_config=$(jq --arg d "$domain" 'del(.apps.tls.automation.policies[] | select(.subjects[]? == $d and (.subjects | length) == 1))' <<< "$new_config")
                # If a policy has multiple subjects, and one is this domain, we might want to remove just that subject from the array.
                # This simplified version removes the whole policy if this was the only subject.
            fi
        fi
    else
        cPrint error "Unknown action: $action"
        return 1
    fi

    if validate_and_write_config "$new_config" "$CADDY_CONFIG_JSON"; then
        if [ "${DEBUG}" == "1" ]; then
            echo "$new_config" | jq .
        fi
        cPrint info "Reloading Caddy for $cL_info$domain$cl_reset ($action)"
        reload_caddy "$CADDY_CONFIG_JSON"
        ensure_error_handlers # Good to run after reloads
        list_domain_mappings
    fi
}

# Function to configure host routes from the host-routes.conf file
configure_host_routes() {
    cPrint info "Configuring host routes from $HOST_ROUTES_CONF"

    if [ ! -f "$HOST_ROUTES_CONF" ]; then
        cPrint info "Creating initial host routes configuration file: $HOST_ROUTES_CONF"
        echo -e "# DomainPilot Host Routes Configuration\n# Format: domain port\n#\n# Examples:\n# local-api.docker.local 3000\n# my-frontend.docker.local 8080" > "$HOST_ROUTES_CONF"
    fi

    local base_config=$(cat "$CADDY_CONFIG_JSON")
    > "$HOST_ROUTES_TRACKER"

    cPrint info "Rebuilding routes configuration including host routes..."

    local healthcheck_route_json='{"match": [{"host": ["localhost"], "path": ["/_healthz"]}], "handle": [{"handler": "static_response", "status_code": 200, "body": "OK"}], "terminal": true}'
    local wildcard_catch_all_route_json='{"match": [{"host": ["*.docker.local"]}], "handle": [{"handler": "rewrite", "uri": "/not_configured.html"}, {"handler": "file_server", "root": "'"$ERROR_PAGES_DIR"'"}], "terminal": true}'

    # Start with healthcheck
    local combined_routes_array=$(jq -n --argjson hr "$healthcheck_route_json" '[$hr]')

    # Get existing container routes (non-host.docker.internal, not healthcheck, not wildcard catch-all)
    local container_routes_array=$(jq '[.apps.http.servers.srv0.routes[]? | select(
        ((.match[0].path[0]? != "/_healthz") or (.match[0].host[]? != "localhost")) and
        ((.match[0].host[]? != "*.docker.local") or (.handle[0].uri? != "/not_configured.html")) and
        (.handle[].handler == "reverse_proxy") and
        (.handle[].upstreams[].dial | test("host.docker.internal") | not)
    )] // []' <<< "$base_config")

    if [[ "$container_routes_array" != "[]" ]]; then
        combined_routes_array=$(jq -n --argjson r1 "$combined_routes_array" --argjson r2 "$container_routes_array" '$r1 + $r2')
    fi

    local host_routes_from_file_array="[]"
    local config_for_tls_updates="$base_config"

    while IFS= read -r line || [ -n "$line" ]; do
        if [[ "$line" =~ ^#.*$ ]] || [[ -z "${line// }" ]]; then continue; fi
        read -r domain port <<< "$line"
        if [ -n "$domain" ] && [ -n "$port" ]; then
            cPrint info "Adding host route: $cL_info$domain$cl_reset -> host.docker.internal:$cL_info$port$cl_reset"
            echo "$domain" >> "$HOST_ROUTES_TRACKER"
            local host_route_entry=$(jq -n --arg d "$domain" --arg p "$port" \
                '{match: [{"host": [$d]}], handle: [{"handler": "reverse_proxy", "upstreams": [{"dial": ("host.docker.internal:" + $p)}]}], terminal: true}')
            host_routes_from_file_array=$(jq -n --argjson arr "$host_routes_from_file_array" --argjson entry "$host_route_entry" '$arr + [$entry]')

            local is_docker_local=$(echo "$domain" | grep -c "\.docker\.local$")
            if [ "$is_docker_local" -eq "0" ] && [ "$domain" != "localhost" ]; then
                if ! jq -e --arg d "$domain" '.apps.tls.automation.policies[]? | select(.subjects[]? == $d)' <<< "$config_for_tls_updates" > /dev/null 2>&1; then
                    cPrint info "Adding TLS policy for host route $cL_info$domain$cl_reset"
                    config_for_tls_updates=$(jq --arg d "$domain" '.apps.tls.automation.policies += [{"subjects": [$d],"issuers": [{"module": "internal", "lifetime": "87600h"}]}]' <<< "$config_for_tls_updates")
                fi
            fi
        fi
    done < "$HOST_ROUTES_CONF"

    if [[ "$host_routes_from_file_array" != "[]" ]]; then
        combined_routes_array=$(jq -n --argjson r1 "$combined_routes_array" --argjson r2 "$host_routes_from_file_array" '$r1 + $r2')
    fi

    # Add wildcard catch-all as the last route
    combined_routes_array=$(jq -n --argjson r1 "$combined_routes_array" --argjson wc "$wildcard_catch_all_route_json" '$r1 + [$wc]')

    local new_full_config=$(jq --argjson routes "$combined_routes_array" \
                         '.apps.http.servers.srv0.routes = $routes' <<< "$config_for_tls_updates")

    if validate_and_write_config "$new_full_config" "$CADDY_CONFIG_JSON"; then
        if [ "${DEBUG}" == "1" ]; then echo "$new_full_config" | jq .; fi
        cPrint info "Reloading Caddy with updated host routes"
        reload_caddy "$CADDY_CONFIG_JSON"
        ensure_error_handlers
        list_domain_mappings
    else
        cPrint error "Failed to update host routes. Keeping previous configuration."
    fi
}

# Function to scan for existing containers
scan_existing_containers() {
    cPrint info "Scanning for existing containers..."
    local containers=$(docker network inspect domainpilot-proxy -f '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null)
    if [ -z "$containers" ]; then
        cPrint warning "No containers found on 'domainpilot-proxy' network or network does not exist."
        return
    fi

    for container in $containers; do
        if [[ $container != *"caddy-proxy"* ]]; then # Skip self
            cPrint info "Found existing container: $cL_info$container$cl_reset"
            update_caddy_json_config "$container" "start"
        fi
    done
}

# Function to watch for changes in the host-routes.conf file
watch_host_routes() {
    while true; do
        # Use timeout with inotifywait to prevent blocking indefinitely if file is removed/recreated
        inotifywait -q -e modify,create,delete,move --timeout 60 "$HOST_ROUTES_CONF" 2>/dev/null
        # Check if file still exists, as inotifywait might exit if watched file is deleted
        if [ -f "$HOST_ROUTES_CONF" ]; then
            cPrint info "Host routes file ($HOST_ROUTES_CONF) changed, reconfiguring..."
            configure_host_routes
        else
            cPrint warning "$HOST_ROUTES_CONF not found. Will check again."
            sleep 5 # Wait before trying again if file is gone
        fi
    done
}

# Function to tail the access log
tail_access_log() {
    cPrint info "Tailing access log from $ACCESS_LOG_FILE"
    if [ ! -f "$ACCESS_LOG_FILE" ]; then
        cPrint warning "Access log file not found. It will be created when requests are made."
        # Create an empty file so tail -f doesn't complain immediately
        touch "$ACCESS_LOG_FILE"
    fi
    # Continuously try to tail, in case it's rotated or recreated
    while true; do
        tail -n 20 -f "$ACCESS_LOG_FILE"
        cPrint warning "Access log stream ended or file unavailable. Retrying in 5s..."
        sleep 5
    done
}

# --- Main Execution ---

# Handle command-line arguments
case "$1" in
    list)
        if [ -f "$CADDY_CONFIG_JSON" ]; then list_domain_mappings; else cPrint error "Caddy config not found."; fi
        exit 0 ;;
    logs)
        tail_access_log
        exit 0 ;;
    debug)
        debug_caddy_config
        exit 0 ;;
    fix)
        setup_error_pages # Ensure dir exists
        fix_error_handlers # This will also ensure initial config if needed
        exit 0 ;;
esac

# Initial setup
setup_error_pages
ensure_error_handlers # This calls create_initial_config if CADDY_CONFIG_JSON doesn't exist or is invalid

start_caddy "$CADDY_CONFIG_JSON"

figlet "DomainPilot"
echo -e "${cl_success}Your Trusted Copilot for Secure Web Traffic 🌎${cl_reset}"
echo -e "${cl_cyan}By Phillarmonic Software <https://github.com/phillarmonic>${cl_reset}"
cPrint info "Env vars: ${cl_info}DOMAINPILOT_VHOST${cl_reset} (domain), ${cl_info}DOMAINPILOT_CONTAINER_PORT${cl_reset} (port, def: 80)"
cPrint info "Network: ${cl_info}domainpilot-proxy${cl_reset} (external) for proxied containers"
cPrint info "Host routes: Edit ${cl_info}/opt/host-routes.conf${cl_reset} (format: 'domain port')"
cPrint info "List domains: ${cl_info}docker exec -it caddy-proxy domainpilot list${cl_reset}"
cPrint info "View logs: ${cl_info}docker exec -it caddy-proxy domainpilot logs${cl_reset} or ${cl_info}/data/access.log${cl_reset}"
cPrint info "Error pages: ${cl_info}/opt/error_pages/${cl_reset} (ensure HTML files are present)"
cPrint info "Fix errors: ${cl_info}docker exec -it caddy-proxy domainpilot fix${cl_reset}"

configure_host_routes
scan_existing_containers

watch_host_routes &

cPrint status "Listening to Docker container events..."
docker events --filter 'event=start' --filter 'event=die' --format '{{json .}}' | while read -r event; do
    container_name=$(echo "$event" | jq -r '.Actor.Attributes.name')
    event_status=$(echo "$event" | jq -r '.status')

    if [ -n "$container_name" ] && [[ "$container_name" != *"caddy-proxy"* ]]; then
        if [ "$event_status" == "start" ] || [ "$event_status" == "die" ]; then
            # Add a small delay to allow container's network setup / env vars to be fully available
            sleep 1
            update_caddy_json_config "$container_name" "$event_status"
        fi
    fi
done
