# DomainPilot

DomainPilot is a Caddy-based local HTTPS reverse proxy, inspired by the jwilder/nginx-proxy style. It provides an easy way to set up and manage local development environments with automatic HTTPS.

## Features

- Automatic HTTPS for local development
- Easy configuration for multiple domains
- Caddy-powered for modern, efficient reverse proxying
- Docker-based for easy setup and portability

## Prerequisites

- Docker
- Docker Compose

## Quick Start

1. Clone this repository:
   
   ```bash
   git clone https://github.com/Phillarmonic/domainpilot.git && cd domainpilot
   ```

2. Add your local domains (prererredly ending with .docker.local) to /etc/hosts:
   
   ```bash
   127.0.0.1 hello-world.docker.local
   127.0.0.1 testing.docker.local
   ```

3. Start DomainPilot. It will create a docker network called domainpilot-proxy if it doesn't yet exists in your machine and start the docker container. Make sure to have port 80 and 443 available.
   
   ```bash
   ./start
   ```

4. Add the environment variable indicating the domain to containers you'd like to be accessed through the DomainPilot proxy (with the DOMAINPILOT_VHOST environment variable), as well as the external network
   
   ```yaml
   # The version statement was deprecated. It is no longer necessary.
   services:
   webserver:
     image: phillarmonic/hello-world
     # Here we don't expose ports because the port will be proxied
     # By the Docker networking
     environment:
       - DOMAINPILOT_VHOST: hello-world.docker.local
   
     # Use the network in the container you'd like to be accessed
     networks:
       - domainpilot-proxy
   
   # Declare the network in the bottom
   networks:
     domainpilot-proxy:
         external: true
   ```

5. DomainPilot will look for a port 80 on your containers (you don't need to externally expose them) and forward the domain traffic to it.

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

You should no longer see SSL related errors on your local domais.

Chrome:
Google chrome settings for installing certificate authority vary from operating system to operating system. Please google how to import a certificate authority for your OS.



## Project Structure

**docker-compose.yml**: Main compose file for DomainPilot

**start**: Script to start DomainPilot

**update-ca**: Script to update the Certificate Authority

**caddy_config**: Directory for Caddy configuration

**caddy_data**: Directory for Caddy data

**docker**/: Contains the source Dockerfile and helper scripts (for building purposes)

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
