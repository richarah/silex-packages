#!/bin/sh
# Fix apt sandbox permissions when running as root
echo 'APT::Sandbox::User "root";' > /etc/apt/apt.conf.d/99sandbox
mkdir -p /var/lib/apt/lists/partial
chown -R _apt:root /var/lib/apt/lists 2>/dev/null || true
chmod 755 /var/lib/apt/lists
