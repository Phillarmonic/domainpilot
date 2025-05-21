# DomainPilot

DomainPilot is a Caddy-based local HTTPS reverse proxy, inspired by the jwilder/nginx-proxy style. It provides an easy way to set up and manage local development environments with automatic HTTPS.

## Features

- Automatic HTTPS for local development
- Easy configuration for multiple domains
- Route traffic to both Docker containers and local ports on your host
- Caddy-powered for modern, efficient reverse proxying
- Docker-based for easy setup and portability
- Live reloading of configuration changes

## Prerequisites

- Docker
- Docker Compose

## Quick Start

1. Clone this repository:
   
   ```bash
   git clone https://github.com/Phillarmonic/domainpilot.git && cd domainpilot
   ```

2. Add your local domains (preferably ending with .docker.local) to /etc/hosts:
   
   ```bash
   127.0.0.1 hello-world.docker.local
   127.0.0.1 testing.docker.local
   127.0.0.1 local-app.docker.local
   ```

3. Start DomainPilot. It will create a docker network called domainpilot-proxy if it doesn't yet exist in your machine and start the docker container. Make sure to have port 80 and 443 available.
   
   ```bash
   ./start
   ```

4. Configure your domains using one of these methods:

   a) **For Docker containers**: Add environment variables to your compose file
   
   ```yaml
   services:
     webserver:
       image: nginx
       # Here we don't expose ports because the port will be proxied
       # By the Docker networking
       environment:
         - DOMAINPILOT_VHOST=hello-world.docker.local
         - DOMAINPILOT_CONTAINER_PORT=80  # Optional, defaults to 80
     
       # Use the network in the container you'd like to be accessed
       networks:
         - domainpilot-proxy
   
   # Declare the network in the bottom
   networks:
     domainpilot-proxy:
         external: true
   ```

   b) **For local ports on your host**: Use the `host-routes.conf` file or helper script
   
   Either edit the file directly:
   ```
   # Format: domain port
   local-app.docker.local 3000
   ```
   
   Or use the helper script:
   ```bash
   ./add-host-route local-app.docker.local 3000
   ```

5. View all your configured domains and where they're pointing:

   ```bash
   ./list-domains
   ```

## Host Routing (Local Ports)

DomainPilot can route traffic from domains to services running directly on your host machine (similar to ngrok functionality). This is perfect for:

- Local development servers (Node.js, Rails, Django, etc.)
- Frontend frameworks (React, Vue, Angular dev servers)
- Backend APIs running directly on your machine
- Any service listening on a local port

### Adding Host Routes

1. **Using the helper script** (recommended):

   ```bash
   ./add-host-route api.myapp.docker.local 3000
   ```

2. **Manually editing the configuration file**:

   Edit `host-routes.conf` in the project root:

   ```
   # Format: domain port
   api.myapp.docker.local 3000
   frontend.myapp.docker.local 8080
   ```

   Each line represents one mapping from a domain to a local port.

### How It Works

- DomainPilot maps the domain to the specified port on your host machine (using host.docker.internal)
- Changes to host-routes.conf are detected automatically - no need to restart DomainPilot
- All traffic gets automatic HTTPS with locally trusted certificates
- Use the `./list-domains` command to see all active mappings

## SSL trust

You need to add the SSL certificate of caddy to your browser to be able to access the local website without the warnings about certificate issues.

Firefox:
Open Firefox's settings. 
On the search bar, type certificates.
Click View Certificates.
![image](https://github.com/user-attachments/assets/f3a94653-b6e2-4eba-9af5-d298d7f3268f)

Now click on the Authorities tab, and click on Import
![image](https://github.com/user-attachments/assets/b1baabdc-6b67-4901-a1c9-792f12adc4ff)

Find the file in caddy data mentioned in the picture below and open it:
![image](https://github.com/user-attachments/assets/8b6ce6d8-24e9-449b-8d32-3842214c656d)

Trust it to identify websites and click ok:
![image](https://github.com/user-attachments/assets/37abda1e-54d3-48ec-b2fd-e5e481ce2b7e)

You should no longer see SSL related errors on your local domains.

Chrome:
Google chrome settings for installing certificate authority vary from operating system to operating system. Please google how to import a certificate authority for your OS.

## Utility Scripts

DomainPilot includes several helpful utility scripts:

- **./start**: Start DomainPilot (with optional `-d` flag for detached mode)
- **./list-domains**: View all configured domains and their mappings
- **./add-host-route**: Quickly add a new host route (local port mapping)

## Project Structure

**docker-compose.yml**: Main compose file for DomainPilot

**start**: Script to start DomainPilot

**update-ca**: Script to update the Certificate Authority

**list-domains**: Script to list all domain mappings

**add-host-route**: Script to add new host route mappings

**host-routes.conf**: Configuration file for host routes

**caddy_config**: Directory for Caddy configuration

**caddy_data**: Directory for Caddy data

**docker**/: Contains the source Dockerfile and helper scripts (for building purposes)

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.