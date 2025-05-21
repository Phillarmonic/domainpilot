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

# Function to validate JSON before writing to configuration file
validate_and_write_config() {
    local config="$1"
    local output_file="$2"

    # Create a temporary file
    local temp_file=$(mktemp)

    # Write the config to the temporary file
    echo "$config" > "$temp_file"

    # Validate JSON
    if jq '.' "$temp_file" > /dev/null 2>&1; then
        # JSON is valid, write to the actual config file
        cat "$temp_file" > "$output_file"
        rm "$temp_file"
        return 0
    else
        # JSON is invalid, log error and keep the old config
        cPrint error "Invalid JSON configuration generated. Keeping previous configuration."
        cPrint error "This is likely a bug in DomainPilot. Please report this issue."
        # Debug info if DEBUG is enabled
        if [ "${DEBUG}" == "1" ]; then
            cPrint error "Invalid JSON:"
            cat "$temp_file"
        fi
        rm "$temp_file"
        return 1
    fi
}

# Function to list all domain mappings and save to a file
list_domain_mappings() {
    cPrint info "Listing all domain mappings..."

    # Clear the previous mappings
    > $DOMAIN_MAPPINGS_FILE

    # Set column widths and calculate total width
    local domain_col_width=40
    local target_col_width=35
    local total_width=$((domain_col_width + target_col_width + 7)) # 7 for borders and spacing

    # Create the table header with dynamic width
    print_line() {
        local char="$1"
        local width=$total_width
        printf -v line '%*s' "$width" ""
        echo -e "${line// /$char}" >> $DOMAIN_MAPPINGS_FILE
    }

    print_header_line() {
        local left="$1"
        local middle="$2"
        local right="$3"
        local text="$4"
        local position="$5" # center, left, or right

        local padding=$((total_width - ${#text} - 2))
        local left_padding=0
        local right_padding=0

        if [ "$position" = "center" ]; then
            left_padding=$((padding / 2))
            right_padding=$((padding - left_padding))
        elif [ "$position" = "left" ]; then
            left_padding=1
            right_padding=$((padding - 1))
        elif [ "$position" = "right" ]; then
            left_padding=$((padding - 1))
            right_padding=1
        fi

        printf "%s%*s%s%*s%s\n" "$left" "$left_padding" "" "$text" "$right_padding" "" "$right" >> $DOMAIN_MAPPINGS_FILE
    }

    # Add header
    print_line "═"
    print_header_line "║" "" "║" "DomainPilot Mappings" "center"

    # Print column headers line
    echo -e "╠═$(printf '%.0s═' $(seq 1 $domain_col_width))═╦═$(printf '%.0s═' $(seq 1 $target_col_width))═╣" >> $DOMAIN_MAPPINGS_FILE

    # Print column headers
    echo -e "║ $(printf "%-${domain_col_width}s" "Domain") ║ $(printf "%-${target_col_width}s" "Target") ║" >> $DOMAIN_MAPPINGS_FILE

    # Print line after column headers
    echo -e "╠═$(printf '%.0s═' $(seq 1 $domain_col_width))═╬═$(printf '%.0s═' $(seq 1 $target_col_width))═╣" >> $DOMAIN_MAPPINGS_FILE

    # Read current configuration and extract domain mappings
    local current_config=$(cat $CADDY_CONFIG_JSON)

    # Get all routes
    local routes=$(jq -c '.apps.http.servers.srv0.routes[]' <<< "$current_config")
    local found_routes=0

    # Process each route
    while IFS= read -r route; do
        local domain=$(jq -r '.match[].host[]' <<< "$route" 2>/dev/null)
        if [ -n "$domain" ]; then
            # Truncate domain if necessary
            local display_domain=$(truncate_text "$domain" $((domain_col_width - 1)))

            local target_info=$(jq -r '.handle[].upstreams[].dial' <<< "$route" 2>/dev/null)
            if [[ "$target_info" == host.docker.internal:* ]]; then
                # It's a host route
                local port=${target_info#host.docker.internal:}
                local target_text="localhost:$port"
                # Truncate target if necessary
                local display_target=$(truncate_text "$target_text" $((target_col_width - 1)))
                echo -e "║ $(printf "%-${domain_col_width}s" "$display_domain") ║ $(printf "%-${target_col_width}s" "$display_target") ║" >> $DOMAIN_MAPPINGS_FILE
            else
                # It's a container route
                local container=${target_info%%:*}
                local port=${target_info#*:}
                local target_text="container: $container:$port"
                # Truncate target if necessary
                local display_target=$(truncate_text "$target_text" $((target_col_width - 1)))
                echo -e "║ $(printf "%-${domain_col_width}s" "$display_domain") ║ $(printf "%-${target_col_width}s" "$display_target") ║" >> $DOMAIN_MAPPINGS_FILE
            fi
            found_routes=1
        fi
    done <<< "$routes"

    # If no routes found, display a message
    if [ $found_routes -eq 0 ]; then
        echo -e "║ $(printf "%-${domain_col_width}s" "No domains configured yet") ║ $(printf "%-${target_col_width}s" "Add some in host-routes.conf") ║" >> $DOMAIN_MAPPINGS_FILE
    fi

    # Print bottom line
    echo -e "╚═$(printf '%.0s═' $(seq 1 $domain_col_width))═╩═$(printf '%.0s═' $(seq 1 $target_col_width))═╝" >> $DOMAIN_MAPPINGS_FILE

    # Print the results
    cat $DOMAIN_MAPPINGS_FILE
}

# Check if the Caddy JSON configuration exists, if not create it
if [ ! -f "$CADDY_CONFIG_JSON" ]; then
    cPrint info "Creating initial Caddy JSON configuration."
    # Create an initial JSON configuration with admin API, basic HTTP server settings, and logging
    echo '{
            "admin": {
              "listen": "localhost:2019"
            },
            "logging": {
              "logs": {
                "default": {
                  "level": "INFO"
                },
                "access": {
                  "level": "INFO",
                  "writer": {
                    "output": "file",
                    "filename": "'$ACCESS_LOG_FILE'"
                  },
                  "encoder": {
                    "format": "json"
                  }
                }
              }
            },
            "apps": {
              "http": {
                "servers": {
                  "srv0": {
                    "listen": [":80", ":443"],
                    "routes": [],
                    "logs": {
                      "logger_names": {
                        "*": "access"
                      }
                    }
                  }
                }
              },
              "tls": {
                "automation": {
                  "policies": [
                    {
                      "subjects": ["*.docker.local"],
                      "issuers": [
                        {
                          "module": "internal",
                          "ca": "local",
                          "lifetime": "87600h"
                        }
                      ]
                    }
                  ]
                }
              }
            }
          }
' > $CADDY_CONFIG_JSON
    cPrint info "Caddy JSON configuration created at $CADDY_CONFIG_JSON"
fi

# Function to update Caddy JSON configuration for containers
update_caddy_json_config() {
    local container_name=$1
    local action=$2

    # Extract domain name using 'DOMAINPILOT_VHOST' environment variable
    local domain=$(docker inspect --format '{{range $index, $value := .Config.Env}}{{println $value}}{{end}}' $container_name | grep 'DOMAINPILOT_VHOST=' | cut -d '=' -f2)

    if [ -z "$domain" ]; then
        cPrint info "No domain found for container $cL_info$container_name$cl_reset"
        return
    fi

    # Extract container port using 'DOMAINPILOT_CONTAINER_PORT' environment variable, default to 80 if not set
    local container_port=$(docker inspect --format '{{range $index, $value := .Config.Env}}{{println $value}}{{end}}' $container_name | grep 'DOMAINPILOT_CONTAINER_PORT=' | cut -d '=' -f2)

    # Set default port to 80 if not specified
    if [ -z "$container_port" ]; then
        container_port=80
        cPrint info "No custom port specified for container $container_name, using default port 80"
    else
        cPrint info "Using custom port $container_port for container $container_name"
    fi

    # Read current configuration
    local current_config=$(cat $CADDY_CONFIG_JSON)

    # Update the JSON configuration based on action
    if [ "$action" == "start" ]; then
        # Check if the domain already exists in the routes
        local domain_exists=$(jq '.apps.http.servers.srv0.routes[] | select(.match[].host[] == "'$domain'") | length > 0' <<< "$current_config" | grep -c "true")

        if [ "$domain_exists" -eq "0" ]; then
            # Add configuration for new domain
            cPrint info "Adding the domain $domain to Caddy HTTP configuration..."
            local new_config=$(jq '.apps.http.servers.srv0.routes += [{"match": [{"host": ["'$domain'"]}],"handle": [{"handler": "reverse_proxy","upstreams": [{"dial": "'$container_name':'$container_port'"}]}],"terminal": true}]' <<< "$current_config")

            # Check if we need to add TLS policy (only if not already covered by wildcard)
            local is_docker_local=$(echo "$domain" | grep -c "\.docker\.local$")
            if [ "$is_docker_local" -eq "0" ]; then
                # Only add explicit TLS policy if not covered by the wildcard *.docker.local
                local tls_exists=$(jq '.apps.tls.automation.policies[] | select(.subjects[] == "'$domain'") | length > 0' <<< "$new_config" | grep -c "true")
                if [ "$tls_exists" -eq "0" ]; then
                    cPrint info "Adding TLS policy for $domain..."
                    new_config=$(jq '.apps.tls.automation.policies += [{"subjects": ["'$domain'"],"issuers": [{"module": "internal", "lifetime": "87600h"}]}]' <<< "$new_config")
                fi
            fi

            # Write the updated configuration
            echo "$new_config" > $CADDY_CONFIG_JSON

            # Check if DEBUG environment variable is set and equals 1
            if [ "${DEBUG}" == "1" ]; then
                echo $new_config
            fi

            # Reload Caddy to apply changes
            cPrint info "Reloading Caddy"
            caddy reload --config $CADDY_CONFIG_JSON

            # Update the domain mappings
            list_domain_mappings
        else
            cPrint info "Domain $domain already exists in configuration"
        fi
    elif [ "$action" == "die" ]; then
        # Remove configuration for the domain
        cPrint info "Removing the domain $domain from Caddy configuration..."
        local new_config=$(jq 'del(.apps.http.servers.srv0.routes[] | select(.match[].host[] == "'$domain'"))' <<< "$current_config")

        # Check if this domain has a specific TLS policy (not covered by wildcard)
        local is_docker_local=$(echo "$domain" | grep -c "\.docker\.local$")
        if [ "$is_docker_local" -eq "0" ]; then
            # Only remove explicit TLS policy if not covered by the wildcard *.docker.local
            new_config=$(jq 'del(.apps.tls.automation.policies[] | select(.subjects[] == "'$domain'"))' <<< "$new_config")
        fi

        # Write the updated configuration
        echo "$new_config" > $CADDY_CONFIG_JSON

        # Check if DEBUG environment variable is set and equals 1
        if [ "${DEBUG}" == "1" ]; then
            echo $new_config
        fi

        # Reload Caddy to apply changes
        cPrint info "Reloading Caddy"
        caddy reload --config $CADDY_CONFIG_JSON

        # Update the domain mappings
        list_domain_mappings
    fi
}

# Function to configure host routes from the host-routes.conf file
configure_host_routes() {
    cPrint info "Configuring host routes from $HOST_ROUTES_CONF"

    # Create the host routes file if it doesn't exist
    if [ ! -f "$HOST_ROUTES_CONF" ]; then
        cPrint info "Creating initial host routes configuration file"
        echo "# DomainPilot Host Routes Configuration
# Format: domain port
#
# Examples:
# local-api.docker.local 3000
# my-frontend.docker.local 8080
# websocket-service.docker.local 9000" > $HOST_ROUTES_CONF
    fi

    # Read current configuration
    local current_config=$(cat $CADDY_CONFIG_JSON)

    # Clear the host routes tracker file
    > $HOST_ROUTES_TRACKER

    # First, remove all host routes by recreating a configuration without them
    cPrint info "Removing existing host routes..."

    # Create a new base configuration with empty routes array
    local new_config=$(jq '.apps.http.servers.srv0.routes = []' <<< "$current_config")

    # Get all non-host routes first (container routes)
    local container_routes=$(jq -c '.apps.http.servers.srv0.routes[] | select(.handle[].handler == "reverse_proxy" and (.handle[].upstreams[].dial | test("host.docker.internal") | not))' <<< "$current_config")

    # If we have container routes, add them back
    if [ -n "$container_routes" ]; then
        # First check if we have multiple routes by counting newlines
        local route_count=$(echo "$container_routes" | wc -l)

        if [ "$route_count" -gt 1 ]; then
            # Multiple routes - we need to format them as an array
            local container_routes_array="["
            while IFS= read -r route; do
                container_routes_array+="$route,"
            done <<< "$container_routes"
            # Remove the trailing comma and close the array
            container_routes_array="${container_routes_array%,}]"

            # Add the routes back to the config
            new_config=$(jq --argjson routes "$container_routes_array" '.apps.http.servers.srv0.routes = $routes' <<< "$new_config")
        elif [ "$route_count" -eq 1 ]; then
            # Single route - add it as a single-element array
            new_config=$(jq --argjson route "$container_routes" '.apps.http.servers.srv0.routes = [$route]' <<< "$new_config")
        fi
        # If route_count is 0, we already have an empty routes array
    fi

    # Now add new host routes from the configuration file
    while read -r line || [ -n "$line" ]; do
        # Skip comments and empty lines
        if [[ "$line" =~ ^#.*$ ]] || [[ -z "${line// }" ]]; then
            continue
        fi

        # Extract domain and port
        read -r domain port <<< "$line"

        if [ -n "$domain" ] && [ -n "$port" ]; then
            cPrint info "Adding host route: $domain -> host.docker.internal:$port"

            # Add the domain to the tracker file for future cleanup
            echo "$domain" >> $HOST_ROUTES_TRACKER

            # Add the host route to the configuration
            new_config=$(jq '.apps.http.servers.srv0.routes += [{"match": [{"host": ["'$domain'"]}],"handle": [{"handler": "reverse_proxy","upstreams": [{"dial": "host.docker.internal:'$port'"}]}],"terminal": true}]' <<< "$new_config")

            # Check if we need to add TLS policy (only if not already covered by wildcard)
            local is_docker_local=$(echo "$domain" | grep -c "\.docker\.local$")
            if [ "$is_docker_local" -eq "0" ]; then
                # Only add explicit TLS policy if not covered by the wildcard *.docker.local
                local tls_exists=$(jq '.apps.tls.automation.policies[] | select(.subjects[] == "'$domain'") | length > 0' <<< "$new_config" | grep -c "true")
                if [ "$tls_exists" -eq "0" ]; then
                    cPrint info "Adding TLS policy for $domain..."
                    new_config=$(jq '.apps.tls.automation.policies += [{"subjects": ["'$domain'"],"issuers": [{"module": "internal", "lifetime": "87600h"}]}]' <<< "$new_config")
                fi
            fi
        fi
    done < "$HOST_ROUTES_CONF"

    # Write the updated configuration
    echo "$new_config" > $CADDY_CONFIG_JSON

    # Reload Caddy to apply changes
    cPrint info "Reloading Caddy with host routes"
    caddy reload --config $CADDY_CONFIG_JSON

    # Update the domain mappings
    list_domain_mappings
}

# Function to scan for existing containers
scan_existing_containers() {
    cPrint info "Scanning for existing containers..."

    # Get all running containers that are connected to the domainpilot-proxy network
    local containers=$(docker network inspect domainpilot-proxy -f '{{range .Containers}}{{.Name}} {{end}}')

    for container in $containers; do
        # Skip the DomainPilot container itself
        if [[ $container != *"caddy-proxy"* ]]; then
            cPrint info "Found existing container: $container"
            update_caddy_json_config "$container" "start"
        fi
    done
}

# Function to watch for changes in the host-routes.conf file
watch_host_routes() {
    while true; do
        inotifywait -e modify,create,delete,move "$HOST_ROUTES_CONF" 2>/dev/null || sleep 5
        cPrint info "Host routes file changed, reconfiguring..."
        configure_host_routes
    done
}

# Function to tail the access log
tail_access_log() {
    cPrint info "Tailing access log from $ACCESS_LOG_FILE"
    if [ -f "$ACCESS_LOG_FILE" ]; then
        tail -n 20 -f "$ACCESS_LOG_FILE"
    else
        cPrint error "Access log file not found. It will be created when requests are made."
        # Wait for the log file to be created
        while [ ! -f "$ACCESS_LOG_FILE" ]; do
            sleep 1
        done
        tail -f "$ACCESS_LOG_FILE"
    fi
}

# Check for list domains command
if [ "$1" == "list" ]; then
    # If Caddy config exists, list domains
    if [ -f "$CADDY_CONFIG_JSON" ]; then
        list_domain_mappings
    else
        cPrint error "Caddy configuration not found. Is DomainPilot running?"
    fi
    exit 0
fi

# Check for tail logs command
if [ "$1" == "logs" ]; then
    tail_access_log
    exit 0
fi

# Start Caddy with the initial configuration
caddy start --config $CADDY_CONFIG_JSON

figlet "DomainPilot"
echo -e "${cl_success}Your Trusted Copilot for Secure Web Traffic 🌎${cl_reset}"
echo -e "${cl_cyan}By Phillarmonic Software <https://github.com/phillarmonic>${cl_reset}"
cPrint info "Make sure to add the env var ${cl_info}'DOMAINPILOT_VHOST'${cl_reset} to your containers with the domain name you want to use."
cPrint info "You can set ${cl_info}'DOMAINPILOT_CONTAINER_PORT'${cl_reset} to specify a non-default port (default is 80)."
cPrint info "Make sure to add the network ${cl_info}'domainpilot-proxy'${cl_reset} (as external) for the containers you want to use with DomainPilot."
cPrint info "To route localhost ports, edit ${cl_info}'/opt/host-routes.conf'${cl_reset} with format: 'domain port'"
cPrint info "To list all domain mappings, run: ${cl_info}'docker exec -it caddy-proxy domainpilot list'${cl_reset}"
cPrint info "To view access logs, run: ${cl_info}'docker exec -it caddy-proxy domainpilot logs'${cl_reset} or check ${cl_info}'./caddy_data/access.log'${cl_reset}"

# Configure host routes initially
configure_host_routes

# Scan for existing containers before starting the event listener
scan_existing_containers

# Start watching host-routes.conf file for changes in background
watch_host_routes &

cPrint status "Listening to Docker container events..."
# Listen for Docker start and die events
docker events --filter 'event=start' --filter 'event=die' --format '{{json .}}' | while read event; do
    container_name=$(echo $event | jq -r '.Actor.Attributes.name')
    event_status=$(echo $event | jq -r '.status')
    if [ "$event_status" == "start" ] || [ "$event_status" == "die" ]; then
        update_caddy_json_config $container_name $event_status
    fi
done