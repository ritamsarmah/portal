#!/usr/bin/env bash

set -a
source .env
set +a

./portal > /var/log/portal.log 2>&1

# 1. Add /etc/logrotate.d/portal to limit log size
# /var/log/portal.log {
#   size 10M
#   rotate 10
#   compress
#   missingok
#   notifempty
#   copytruncate
# }

# 2. Create log file beforehand with user permissions
# sudo touch /var/log/portal.log
# sudo chown $USER /var/log/portal.log
# chmod 644 /var/log/portal.log
