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

    # Start Caddy
    caddy start --config "$config_file"

    # Wait for Caddy to start and be ready
    cPrint info "Waiting for Caddy to be ready..."

    while [ $attempt -le $max_attempts ]; do
        # Sleep first to give Caddy time to start
        sleep $delay

        # Try to check admin API
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

        # Check if reload was successful
        if [ $? -eq 0 ]; then
            cPrint info "Caddy reloaded successfully on attempt $attempt."
            return 0
        fi

        cPrint warning "Attempt $attempt to reload Caddy failed. Waiting ${delay}s before retry..."
        sleep $delay

        # Exponential backoff (1s, 2s, 4s, 8s)
        delay=$((delay * 2))
        attempt=$((attempt + 1))
    done

    cPrint error "Failed to reload Caddy after $max_attempts attempts."

    # Check admin API status
    cPrint info "Checking Caddy admin API status..."
    if curl -s -o /dev/null -w "%{http_code}" http://localhost:2019/config/ &>/dev/null; then
        cPrint info "Admin API appears to be running now."
    else
        cPrint error "Admin API is not responding. Caddy may need to be restarted."

        # Try to restart Caddy as a last resort
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

# Function to debug the current Caddy configuration
debug_caddy_config() {
    cPrint info "Debugging Caddy configuration..."

    # Check if the config file exists
    if [ ! -f "$CADDY_CONFIG_JSON" ]; then
        cPrint error "Caddy configuration file not found at $CADDY_CONFIG_JSON"
        return 1
    fi

    # Check if error pages directory exists
    if [ ! -d "$ERROR_PAGES_DIR" ]; then
        cPrint error "Error pages directory not found at $ERROR_PAGES_DIR"
        mkdir -p "$ERROR_PAGES_DIR"
        cPrint info "Created error pages directory at $ERROR_PAGES_DIR"
    fi

    # List error pages
    cPrint info "Error pages in $ERROR_PAGES_DIR:"
    ls -la "$ERROR_PAGES_DIR"

    # Check error handlers in Caddy config
    local error_handlers=$(jq '.apps.http.servers.srv0.errors' "$CADDY_CONFIG_JSON")
    cPrint info "Error handlers configuration:"
    echo "$error_handlers" | jq .

    # Check if specific error pages exist and are readable
    local error_paths=$(jq -r '.apps.http.servers.srv0.errors.routes[0].handle[0].paths | keys[]' "$CADDY_CONFIG_JSON" 2>/dev/null)
    if [ -n "$error_paths" ]; then
        cPrint info "Checking error page paths:"
        while IFS= read -r code; do
            local path=$(jq -r ".apps.http.servers.srv0.errors.routes[0].handle[0].paths[\"$code\"]" "$CADDY_CONFIG_JSON")
            cPrint info "Error code $code -> $path"
            if [ -f "$path" ]; then
                cPrint info "  File exists and is readable"
            else
                cPrint error "  File does not exist or is not readable"
            fi
        done <<< "$error_paths"
    else
        cPrint error "No error paths found in configuration"
    fi

    # Check Caddy status - this may not work on all Caddy versions
    cPrint info "Caddy status:"
    caddy status 2>/dev/null || cPrint info "Status command not available in this version of Caddy"
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

# Function to create error page handlers JSON configuration
create_error_handlers_config() {
    local handlers_json='{
        "error_pages": {
            "handler": "error_pages",
            "error_codes": [400, 401, 403, 404, 500, 502, 503, 504],
            "paths": {
                "400": "/opt/error_pages/generic.html",
                "401": "/opt/error_pages/generic.html",
                "403": "/opt/error_pages/403.html",
                "404": "/opt/error_pages/404.html",
                "500": "/opt/error_pages/500.html",
                "502": "/opt/error_pages/502.html",
                "503": "/opt/error_pages/500.html",
                "504": "/opt/error_pages/500.html",
                "*": "/opt/error_pages/generic.html"
            }
        }
    }'

    echo "$handlers_json"
}

# Function to ensure error handlers are properly configured
ensure_error_handlers() {
    cPrint info "Ensuring error handlers are configured..."

    # Check if config file exists first
    if [ ! -f "$CADDY_CONFIG_JSON" ]; then
        cPrint info "Config file doesn't exist. Creating initial configuration first."
        create_initial_config
        return 0
    fi

    # Read current configuration
    local current_config=$(cat $CADDY_CONFIG_JSON)

    # Check if the file is empty or contains invalid JSON
    if [ -z "$current_config" ]; then
        cPrint info "Config file is empty. Creating initial configuration."
        create_initial_config
        return 0
    else
        # Validate JSON format
        if ! jq '.' <<< "$current_config" > /dev/null 2>&1; then
            cPrint error "Invalid JSON in config file. Creating new configuration."
            create_initial_config
            return 0
        fi
    fi

    # Check if basic structure exists
    local has_apps=$(jq 'has("apps")' <<< "$current_config")

    if [ "$has_apps" != "true" ]; then
        cPrint info "Basic configuration structure missing. Creating new configuration."
        create_initial_config
        return 0
    fi

    # Check if error handling structure exists
    local has_errors=$(jq '.apps.http.servers.srv0 | has("errors")' <<< "$current_config" 2>/dev/null)

    if [ "$has_errors" != "true" ]; then
        cPrint info "Error handling configuration missing. Adding it..."

        # Add error handling configuration
        local new_config=$(jq '.apps.http.servers.srv0.errors = {
            "routes": [
                {
                    "handle": [
                        {
                            "handler": "static_response",
                            "headers": {
                                "Content-Type": ["text/html"]
                            },
                            "status_code": "{http.error.status_code}",
                            "body": {
                                "file": "/opt/error_pages/{http.error.status_code}.html",
                                "fallback": "/opt/error_pages/generic.html"
                            }
                        }
                    ]
                }
            ]
        }' <<< "$current_config")

        if validate_and_write_config "$new_config" "$CADDY_CONFIG_JSON"; then
            cPrint info "Error handling configuration added successfully."

            # Reload Caddy to apply changes
            cPrint info "Reloading Caddy with updated error handlers"
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

# Function to ensure error pages exist
setup_error_pages() {
    cPrint info "Setting up error pages..."

    # Create the error pages directory if it doesn't exist
    mkdir -p "$ERROR_PAGES_DIR"

    # Define the error pages to check
    declare -A error_pages=(
        ["404.html"]="404 - Page Not Found"
        ["403.html"]="403 - Forbidden"
        ["500.html"]="500 - Server Error"
        ["502.html"]="502 - Bad Gateway"
        ["generic.html"]="Generic Error Page"
    )

    # Check if the error pages exist, otherwise copy from the default templates or create simple ones
    for page in "${!error_pages[@]}"; do
        if [ ! -f "$ERROR_PAGES_DIR/$page" ]; then
            # If there's a default template, copy it
            if [ -f "/opt/default_error_pages/$page" ]; then
                cPrint info "Creating default error page: $page"
                cp "/opt/default_error_pages/$page" "$ERROR_PAGES_DIR/$page"
            else
                # Otherwise create a simple error page
                cPrint info "Creating simple error page: $page"
                echo "<!DOCTYPE html>
<html>
<head>
    <title>${error_pages[$page]} | DomainPilot</title>
    <style>
        body { font-family: sans-serif; line-height: 1.6; color: #333; max-width: 650px; margin: 0 auto; padding: 20px; }
        h1 { color: #3498db; }
        .error-container { background-color: #f8f9fa; border-radius: 5px; padding: 20px; margin-top: 20px; }
    </style>
</head>
<body>
    <h1>${error_pages[$page]}</h1>
    <div class='error-container'>
        <p>The page you requested could not be displayed.</p>
        <p>You can customize this error page by editing <code>$ERROR_PAGES_DIR/$page</code></p>
    </div>
    <p><small>Powered by DomainPilot</small></p>
</body>
</html>" > "$ERROR_PAGES_DIR/$page"
            fi
        fi
    done

    # Print the available error pages
    cPrint info "Available error pages:"
    ls -la "$ERROR_PAGES_DIR"
}

# Function to fix error handlers
fix_error_handlers() {
    cPrint info "Fixing error handlers configuration..."

    # Read current configuration
    local current_config=$(cat $CADDY_CONFIG_JSON)

    # Get the error handlers configuration
    local error_handlers_json=$(create_error_handlers_config)

    # Create a new configuration with correct error handlers
    local new_config=$(jq '.apps.http.servers.srv0.errors.routes[0].handle = []' <<< "$current_config")
    new_config=$(jq --argjson handlers "$(echo "$error_handlers_json" | jq .error_pages)" '.apps.http.servers.srv0.errors.routes[0].handle = [$handlers]' <<< "$new_config")

    # Validate and write the updated configuration
    if validate_and_write_config "$new_config" "$CADDY_CONFIG_JSON"; then
        cPrint info "Error handlers successfully fixed."

        # Reload Caddy to apply changes
        cPrint info "Reloading Caddy with fixed error handlers"
        reload_caddy "$CADDY_CONFIG_JSON"
        return 0
    else
        cPrint error "Failed to fix error handlers."
        return 1
    fi
}

# Function to create initial Caddy configuration
# Function to create initial Caddy configuration
create_initial_config() {
    cPrint info "Creating initial Caddy JSON configuration."

    # Create an initial JSON configuration with admin API, basic HTTP server settings, and logging
    cat > "$CADDY_CONFIG_JSON" << EOL
{
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
                    "filename": "${ACCESS_LOG_FILE}"
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
                    },
                    "errors": {
                        "routes": [
                            {
                                "handle": [
                                    {
                                        "handler": "rewrite",
                                        "uri": "/{http.error.status_code}.html"
                                    }
                                ]
                            },
                            {
                                "handle": [
                                    {
                                        "handler": "file_server",
                                        "root": "/opt/error_pages",
                                        "index_names": []
                                    }
                                ]
                            }
                        ]
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
EOL
    cPrint info "Caddy JSON configuration created at $CADDY_CONFIG_JSON"
}

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

            # Validate and write the updated configuration
            if validate_and_write_config "$new_config" "$CADDY_CONFIG_JSON"; then
                # Check if DEBUG environment variable is set and equals 1
                if [ "${DEBUG}" == "1" ]; then
                    echo $new_config
                fi

                # Reload Caddy to apply changes
                cPrint info "Reloading Caddy"
                reload_caddy "$CADDY_CONFIG_JSON"

                # Ensure error handlers are configured
                ensure_error_handlers

                # Update the domain mappings
                list_domain_mappings
            fi
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

        # Validate and write the updated configuration
        if validate_and_write_config "$new_config" "$CADDY_CONFIG_JSON"; then
            # Check if DEBUG environment variable is set and equals 1
            if [ "${DEBUG}" == "1" ]; then
                echo $new_config
            fi

            # Reload Caddy to apply changes
            cPrint info "Reloading Caddy"
            reload_caddy "$CADDY_CONFIG_JSON"

            # Ensure error handlers are configured
            ensure_error_handlers

            # Update the domain mappings
            list_domain_mappings
        fi
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

    # Validate and write the updated configuration
    if validate_and_write_config "$new_config" "$CADDY_CONFIG_JSON"; then
        # Reload Caddy to apply changes
        cPrint info "Reloading Caddy with host routes"
        reload_caddy "$CADDY_CONFIG_JSON"

        # Ensure error handlers are configured
        ensure_error_handlers

        # Update the domain mappings
        list_domain_mappings
    else
        cPrint error "Failed to update host routes. Keeping previous configuration."
    fi
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

# Check for debug command
if [ "$1" == "debug" ]; then
    debug_caddy_config
    exit 0
fi

# Check for fix command to manually fix error handlers
if [ "$1" == "fix" ]; then
    setup_error_pages
    fix_error_handlers
    exit 0
fi

# Setup error pages
setup_error_pages

# Ensure error handlers are configured
ensure_error_handlers

# Start Caddy with the initial configuration and wait for it to be ready
start_caddy "$CADDY_CONFIG_JSON"

figlet "DomainPilot"
echo -e "${cl_success}Your Trusted Copilot for Secure Web Traffic 🌎${cl_reset}"
echo -e "${cl_cyan}By Phillarmonic Software <https://github.com/phillarmonic>${cl_reset}"
cPrint info "Make sure to add the env var ${cl_info}'DOMAINPILOT_VHOST'${cl_reset} to your containers with the domain name you want to use."
cPrint info "You can set ${cl_info}'DOMAINPILOT_CONTAINER_PORT'${cl_reset} to specify a non-default port (default is 80)."
cPrint info "Make sure to add the network ${cl_info}'domainpilot-proxy'${cl_reset} (as external) for the containers you want to use with DomainPilot."
cPrint info "To route localhost ports, edit ${cl_info}'/opt/host-routes.conf'${cl_reset} with format: 'domain port'"
cPrint info "To list all domain mappings, run: ${cl_info}'docker exec -it caddy-proxy domainpilot list'${cl_reset}"
cPrint info "To view access logs, run: ${cl_info}'docker exec -it caddy-proxy domainpilot logs'${cl_reset} or check ${cl_info}'./caddy_data/access.log'${cl_reset}"
cPrint info "Custom error pages are located at: ${cl_info}'./caddy_config/error_pages/'${cl_reset}"
cPrint info "If error pages are not working, run: ${cl_info}'docker exec -it caddy-proxy domainpilot fix'${cl_reset}"

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