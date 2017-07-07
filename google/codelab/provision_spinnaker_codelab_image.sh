#!/bin/bash

# Copyright 2016 Google Inc. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# This script provisions a fresh spinnaker image with a Jenkins
# server and an aptly repository, served on nginx. It also
# provides a basic Jenkins configuration. This is to be used
# specifically for creating a new (running) codelab image out of a fresh
# spinnaker image.

set -e

if [[ `/usr/bin/id -u` -ne 0 ]]; then
  echo "$0 must be executed with root permissions; exiting"
  exit 1
fi

if [[ ! -d "/opt/spinnaker/pylib" ]]; then
  echo "Spinnaker is not installed. Look at http://www.spinnaker.io for installation instructions."
  exit 1
fi

service spinnaker stop || true
service apache2 stop || true

# this allows us to skip any interactive post-install configuration,
# specifically around keeping defaults for files that were modified.
export DEBIAN_FRONTEND=noninteractive

# we don't want to update these. see github.com/spinnaker/spinnaker/issues/1279
# for context.
SPINNAKER_SUBSYSTEMS="spinnaker-clouddriver spinnaker-deck spinnaker-echo spinnaker-fiat spinnaker-front50 spinnaker-gate spinnaker-igor spinnaker-orca spinnaker-rosco spinnaker"

apt-mark hold $SPINNAKER_SUBSYSTEMS
# update apt
apt-get update
# temporary workaround for where DEBIAN_FRONTEND=noninteractive isn't enough
apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" -y upgrade
apt-mark unhold $SPINNAKER_SUBSYSTEMS

# acquire and configure jenkins
apt-get install -y git
wget http://pkg.jenkins-ci.org/debian/binary/jenkins_2.1_all.deb
# dpkg partially installs jenkins and fails
dpkg -i jenkins_2.1_all.deb || true
rm -f jenkins_2.1_all.deb

# finish installing jenkins and its dependencies
apt-get -f -y install
sed -i "s/HTTP_PORT=.*/HTTP_PORT=5656/" /etc/default/jenkins

# as jenkins, configure aptly
cd /home/jenkins
wget https://dl.bintray.com/smira/aptly/0.9.5/debian-squeeze-x64/aptly
chown jenkins /home/jenkins/aptly
sudo -u jenkins -H sh -c "chmod +x aptly"
sudo -u jenkins -H sh -c "/home/jenkins/aptly repo create hello"
sudo -u jenkins -H sh -c '/home/jenkins/aptly publish repo -architectures="amd64,i386" -component=main -distribution=trusty -skip-signing=true hello'

# as jenkins, configure jenkins config directory
# this storage bucket is public so we can pull the jenkins config from anywhere
cd /var/lib/jenkins
sudo -u jenkins -H sh -c 'wget https://storage.googleapis.com/codelab-jenkins-configuration/jenkins_dir.tar.gz'
sudo -u jenkins -H sh -c 'tar -zxvf jenkins_dir.tar.gz'
sudo -u jenkins -H sh -c 'rm jenkins_dir.tar.gz'
sudo -u jenkins -H sh -c 'git clone https://github.com/kenzanlabs/hello-karyon-rxnetty.git'
sudo -u jenkins -H sh -c 'cd /var/lib/jenkins/jobs/Hello-Build; rm -rf builds lastStable lastSuccessful scm-polling.log nextBuildNumber; echo 1 >> nextBuildNumber'

service jenkins restart

# configure nginx to serve the aptly repo and start it
apt-get install -y nginx
nginx_default="/etc/nginx/sites-enabled/default"
if [[ -e "$nginx_default" ]]; then
  echo "Warning: nginx default file exists. Copying to '/etc/nginx/sites-enabled/default.orig' and writing new default file."
  mv $nginx_default /etc/nginx/sites-enabled/default.orig
fi
cat > $nginx_default <<EOF
server {
        listen 9999 default_server;
        listen [::]:9999 default_server ipv6only=on;
        root /home/jenkins/.aptly/public;
        index index.html index.htm;
        server_name localhost;
        location / {
                try_files \$uri \$uri/ =404;
        }
}
EOF

mv $(dirname $0)/first_codelab_boot.sh /opt/spinnaker/install
chmod 755 /opt/spinnaker/install/first_codelab_boot.sh
chown spinnaker:spinnaker /opt/spinnaker/install/first_codelab_boot.sh

mv $(dirname $0)/codelab_config.py /opt/spinnaker/install
chmod 644 /opt/spinnaker/install/codelab_config.py
chown spinnaker:spinnaker /opt/spinnaker/install/codelab_config.py

service nginx restart

service spinnaker restart
service apache2 restart
