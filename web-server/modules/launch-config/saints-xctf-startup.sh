#!/usr/bin/env bash

# Bash script which is run when the SaintsXCTF server instances first boot up
# Author: Andrew Jarombek
# Date: 12/11/2018

echo "[Start] saints-xctf-startup.sh"

# Add the application files not in version control
sudo aws s3api get-object --bucket saints-xctf-credentials-${ENV} --key date.js /var/www/html/date.js
sudo aws s3api get-object --bucket saints-xctf-credentials-${ENV} --key api/cred.php /var/www/html/api/cred.php
sudo aws s3api get-object --bucket saints-xctf-credentials-${ENV} --key api/apicred.php /var/www/html/api/apicred.php
sudo aws s3api get-object --bucket saints-xctf-credentials-${ENV} --key \
        models/clientcred.php /var/www/html/models/clientcred.php

# The SaintsXCTF application looks at this environment variable to determine which API URL to use
sudo bash -c echo "\"ENV=\"${ENV}\"\" >> /etc/environment"

# Execute a python script which alters the Apache config for the given environment
cd /home/ubuntu
sudo chmod +x apache-config.py
sudo ./apache-config.py ${ENV}

# Enable the new SaintsXCTF config for Apache and disable the default config
sudo a2ensite saintsxctf.com.conf
sudo a2dissite 000-default.conf

# Make sure the Apache configuration changes are valid and restart the web server
sudo apache2ctl configtest
sudo systemctl restart apache2

echo "[End] saints-xctf-startup.sh"