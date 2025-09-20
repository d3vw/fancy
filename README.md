# Dante Setup Script

This repository contains a helper script for installing and configuring a Dante SOCKS server on Debian/Ubuntu systems with an IP allow-list.

## Prerequisites

- A Debian or Ubuntu host with `apt` package management.
- Root privileges to install packages and modify `/etc/danted.conf`.

## Usage

To download the script straight from GitHub and run it:

```bash
curl -fsSL https://raw.githubusercontent.com/d3vw/fancy/main/setup_dante.sh -o setup_dante.sh
chmod +x setup_dante.sh
sudo ./setup_dante.sh -a 203.0.113.5 -a 198.51.100.0/24 -p 1090
```

### Options


- `-a <ip_or_cidr>` – Add one or more IP addresses or CIDR ranges (comma-separated) that are allowed to use the proxy. You can repeat the option.
- `-p <port>` – Port that the Dante server should listen on. Defaults to `1080`.
- `-h` – Show the built-in help text.

The script will:

1. Install the `dante-server` package via `apt` if it is not already installed.
2. Detect the default network interface used for outbound traffic.
3. Back up any existing `/etc/danted.conf` file with a timestamp suffix.
4. Write a new configuration that only allows the specified client networks and uses a passwordless SOCKS policy for those
   clients.
5. Enable and restart the `danted` systemd service.

After the script completes successfully, the Dante server will be listening on the requested port and only the IPs/CIDR blocks supplied through the `-a` option will be permitted.
