#!/bin/bash
#
# Copyright 2015 Google Inc. All Rights Reserved.
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

# This script is specific to preparing a Google-hosted virtual machine
# for running Spinnaker when the instance was created with metadata
# holding configuration information.

set -e
set -u

# We're running as root, but HOME might not be defined.
AWS_DIR=/home/spinnaker/.aws
KUBE_DIR=/home/spinnaker/.kube
KUBE_VERSION=v1.3.4
# Google Container Registry (GCR) password file directory.
GCR_DIR=/home/spinnaker/.gcr
SPINNAKER_INSTALL_DIR=/opt/spinnaker
LOCAL_CONFIG_DIR=$SPINNAKER_INSTALL_DIR/config

# This status prefix provides a hook to inject output signals with status
# messages for consumers like the Google Deployment Manager Coordinator.
# Normally this isn't needed. Callers will populate it as they need
# using --status_prefix.
STATUS_PREFIX="*"

METADATA_URL="http://metadata.google.internal/computeMetadata/v1"
INSTANCE_METADATA_URL="$METADATA_URL/instance"

SPINNAKER_SUBSYSTEMS="spinnaker-clouddriver spinnaker-deck spinnaker-echo spinnaker-fiat spinnaker-front50 spinnaker-gate spinnaker-igor spinnaker-orca spinnaker-rosco spinnaker"
SPINNAKER_DEPENDENCIES="redis-server"

# By default we'll tradeoff the utmost in security for less startup latency
# (often several minutes worth if there are any OS updates at all).
# Note that this is only the initial boot off the image in this script, which is
# intended to configure spinnaker from metadata, which is typically an adhoc or trial
# scenario. A production instance would probably be using a different means to configure
# spinnaker, or might be baked in, or might have different security policies not requiring
# an initial upgrade.
RESTART_BEFORE_UPGRADE="true"


function write_default_value() {
  name="$1"
  value="$2"
  if egrep "^$name=" /etc/default/spinnaker > /dev/null; then
      sed -i "s/^$name=.*/$name=$value/" /etc/default/spinnaker
  else
      echo "$name=$value" >> /etc/default/spinnaker
  fi
}

function get_instance_metadata_attribute() {
  local name="$1"
  local value=$(curl -s -f -H "Metadata-Flavor: Google" \
                     $INSTANCE_METADATA_URL/attributes/$name)
  if [[ $? -eq 0 ]]; then
    echo "$value"
  else
    echo ""
  fi
}

function write_instance_metadata() {
  gcloud compute instances add-metadata `hostname` \
      --zone $MY_ZONE \
      --metadata "$@"
  return $?
}

function clear_metadata_to_file() {
  local key="$1"
  local path="$2"
  local value=$(get_instance_metadata_attribute "$key")

  if [[ $value = *[![:space:]]* ]]; then
     echo "$value" > $path
     chown spinnaker:spinnaker $path
     clear_instance_metadata "$key"
     if [[ $? -ne 0 ]]; then
       die "Could not clear metadata from $key"
     fi
     return 0
  elif [[ $value != "" ]]; then
     # Clear key anyway, but act as if it werent there.
     clear_instance_metadata "$key"
  fi

  return 1
}

function clear_instance_metadata() {
  gcloud compute instances remove-metadata `hostname` \
      --zone $MY_ZONE \
      --keys "$1"
  return $?
}

function replace_startup_script() {
  # Keep the original around for reference.
  # From now on, all we need to do is start_spinnaker
  local original=$(get_instance_metadata_attribute "startup-script")
  echo "$original" > "$SPINNAKER_INSTALL_DIR/scripts/original_startup_script.sh"
  clear_instance_metadata "startup-script"
}

function extract_spinnaker_local_yaml() {
  local yml_path=$LOCAL_CONFIG_DIR/spinnaker-local.yml
  if clear_metadata_to_file "spinnaker_local" $yml_path; then
    chown spinnaker:spinnaker $yml_path
    chmod 600 $yml_path
  fi
  return 0
}

function extract_spinnaker_credentials() {
    extract_spinnaker_google_credentials
    extract_spinnaker_aws_credentials
    extract_spinnaker_kube_credentials
    extract_spinnaker_gcr_credentials
}

function extract_spinnaker_google_credentials() {
  local json_path="$LOCAL_CONFIG_DIR/google-credentials.json"
  mkdir -p $(dirname $json_path)

  if clear_metadata_to_file "managed_project_credentials" $json_path; then
    # This is a workaround for difficulties using the Google Deployment Manager
    # to express no value. We'll use the value "None". But we don't want
    # to officially support this, so we'll just strip it out of this first
    # time boot if we happen to see it, and assume the Google Deployment Manager
    # got in the way.
    sed -i s/^None$//g $json_path
    if [[ -s $json_path ]]; then
      chmod 400 $json_path
      chown spinnaker $json_path
      echo "Extracted google credentials to $json_path"
    else
      rm $json_path
    fi
    write_default_value "SPINNAKER_GOOGLE_PROJECT_CREDENTIALS_PATH" "$json_path"
  else
    clear_instance_metadata "managed_project_credentials"
    json_path=""
  fi

  local consul_enabled=$(get_instance_metadata_attribute "consul_enabled")
  if [ -n "$consul_enabled" ]; then
      echo "Setting google consul enabled to $consul_enabled"
      write_default_value "SPINNAKER_GOOGLE_CONSUL_ENABLED" "$consul_enabled"
  fi

  # This cant be configured when we create the instance because
  # the path is local within this instance (file transmitted in metadata)
  # Remove the old line, if one existed, and replace it with a new one.
  # This way it does not matter whether the user supplied it or not
  # (and might have had it point to something client side).
  if [[ -f "$LOCAL_CONFIG_DIR/spinnaker-local.yml" ]]; then
      sed -i "s/\( \+jsonPath:\).\+/\1 ${json_path//\//\\\/}/g" \
          $LOCAL_CONFIG_DIR/spinnaker-local.yml
  fi
}

function extract_spinnaker_aws_credentials() {
  local credentials_path="$AWS_DIR/credentials"
  mkdir -p $(dirname $credentials_path)
  chown -R spinnaker:spinnaker $(dirname $credentials_path)

  if clear_metadata_to_file "aws_credentials" $credentials_path; then
    # This is a workaround for difficulties using the Google Deployment Manager
    # to express no value. We'll use the value "None". But we don't want
    # to officially support this, so we'll just strip it out of this first
    # time boot if we happen to see it, and assume the Google Deployment Manager
    # got in the way.
    sed -i s/^None$//g $credentials_path
    if [[ -s $credentials_path ]]; then
      chmod 600 $credentials_path
      chown spinnaker:spinnaker $credentials_path
      echo "Extracted aws credentials to $credentials_path"
    else
       rm $credentials_path
    fi
    write_default_value "SPINNAKER_AWS_ENABLED" "true"
  else
    clear_instance_metadata "aws_credentials"
  fi
}

function attempt_write_kube_credentials() {
  local config_path="$KUBE_DIR/config"
  mkdir -p $(dirname $config_path)
  chown -R spinnaker:spinnaker $(dirname $config_path)

  local kube_cluster=$(get_instance_metadata_attribute "kube_cluster")
  local kube_zone=$(get_instance_metadata_attribute "kube_zone")
  local kube_config=$(get_instance_metadata_attribute "kube_config")

  if [ -n "$kube_cluster" ] && [ -n "$kube_config" ]; then
    echo "WARNING: Both \"kube_cluster\" and \"kube_config\" were supplied as instance metadata, relying on \"kube_config\""
  fi

  if [ -n "$kube_config" ]; then
    echo "Attempting to write kube_config to $config_path..."
    if clear_metadata_to_file "kube_config" $config_path; then
      # This is a workaround for difficulties using the Google Deployment Manager
      # to express no value. We'll use the value "None". But we don't want
      # to officially support this, so we'll just strip it out of this first
      # time boot if we happen to see it, and assume the Google Deployment Manager
      # got in the way.
      sed -i s/^None$//g $config_path
      if [[ -s $config_path ]]; then
        chmod 400 $config_path
        chown spinnaker $config_path
        echo "Successfully wrote kube_config to $config_path"

        return 0
      else
        echo "Failed to write kube_config to $config_path"
        rm $config_path

        return 1
      fi
    fi
  fi

  if [ -n "$kube_cluster" ]; then
    echo "Downloading credentials for cluster $kube_cluster in zone $kube_zone..."

    if [ -z "$kube_zone" ]; then
      kube_zone=$MY_ZONE
    fi

    export KUBECONFIG=$config_path
    gcloud config set container/use_client_certificate true
    gcloud container clusters get-credentials $kube_cluster --zone $kube_zone 

    if [[ -s $config_path ]]; then
      echo "Kubernetes credentials successfully extracted to $config_path"
      chmod 400 $config_path
      chown spinnaker:spinnaker $config_path

      return 0
    else
      echo "Failed to extract kubernetes credentials to $config_path"
      rm $config_path

      return 1
    fi
  fi

  echo "No kubernetes credentials or cluster provided."
  return 1
}

function extract_spinnaker_kube_credentials() {
  if attempt_write_kube_credentials; then
    write_default_value "SPINNAKER_KUBERNETES_ENABLED" "true"
    clear_instance_metadata "kube_cluster"
    clear_instance_metadata "kube_zone"
    clear_instance_metadata "kube_config"
  fi
}

function extract_spinnaker_gcr_credentials() {
  local config_path="$GCR_DIR/gcr.json"
  mkdir -p $(dirname $config_path)
  chown -R spinnaker:spinnaker $(dirname $config_path)

  local gcr_enabled=$(get_instance_metadata_attribute "gcr_enabled")
  local gcr_account=$(get_instance_metadata_attribute "gcr_account")

  if [ -n "$gcr_enabled" ] || [ -n "$gcr_account" ]; then
    echo "GCR enabled"

    if [ -z "$gcr_account" ]; then
      # This service account is enabled with the Compute API.
      gcr_account=$(curl -s -H "Metadata-Flavor: Google" "$METADATA_URL/instance/service-accounts/default/email")
      clear_instance_metadata "gcr_account"
    fi

    echo "Extracting GCR credentials for email $gcr_account"
    gcloud iam service-accounts keys create $config_path --iam-account=$gcr_account

    if [[ -s $config_path ]]; then
      echo "Extracted GCR credentials to $config_path"

      chmod 400 $config_path
      chown spinnaker:spinnaker $config_path

      local gcr_location=$(get_instance_metadata_attribute "gcr_location")

      if [ -z "$gcr_location" ]; then
        gcr_location="https://gcr.io"
      fi

      write_default_value "SPINNAKER_DOCKER_PASSWORD_FILE" $config_path
      write_default_value "SPINNAKER_DOCKER_USERNAME" "_json_key"
      write_default_value "SPINNAKER_DOCKER_REGISTRY" $gcr_location
    else
      rm $config_path
      echo "Failed to extract GCR credentials to $config_path"
    fi
  else
    echo "GCR not enabled"
    clear_instance_metadata "gcr_account"
    clear_instance_metadata "gcr_enabled"
  fi
}

function do_experimental_startup() {
  local install_monitoring=$(get_instance_metadata_attribute "install_monitoring")
  if [[ ! -z $install_monitoring ]]; then
     IFS=' ' read -r -a all_args <<< "$install_monitoring"
     local which=${all_args[0]}
     local flags=${all_args[@]: 1:${#all_args}}
     /opt/spinnaker-monitoring/third_party/$which/install.sh ${flags[@]}

     if [[ ! -f /opt/spinnaker-monitoring/registry ]]; then
         mv /opt/spinnaker-monitoring/registry.example \
            /opt/spinnaker-monitoring/registry
     fi

     service spinnaker-monitoring restart
     clear_instance_metadata "install_monitoring"
  fi
}

function process_args() {
  while [[ $# > 0 ]]
  do
    local key="$1"
    case $key in
    --status_prefix)
      STATUS_PREFIX="$2"
      shift
      ;;

    *)
      echo "ERROR: unknown option '$key'."
      exit -1
      ;;
    esac
    shift
  done
}

MY_ZONE=""
if full_zone=$(curl -s -H "Metadata-Flavor: Google" "$INSTANCE_METADATA_URL/zone"); then
  MY_ZONE=$(basename $full_zone)
  MY_PROJECT=$(curl -s -H "Metadata-Flavor: Google" "$METADATA_URL/project/project-id")
  MY_PROJECT_NUMBER=$(curl -s -H "Metadata-Flavor: Google" "$METADATA_URL/project/numeric-project-id")
else
  echo "Not running on Google Cloud Platform."
  exit -1
fi

process_args


# Spinnaker automatically starts up in the image.
# In this script we are going to reconfigure it,
# therefore we do not want it to become available until we've done so.
# Otherwise it would be running with the wrong (old/default) configuration.
echo "Stopping spinnaker while we configure it."
stop spinnaker || true

echo "$STATUS_PREFIX  Configuring Default Values"
write_default_value "SPINNAKER_GOOGLE_ENABLED" "true"
write_default_value "SPINNAKER_GOOGLE_PROJECT_ID" "$MY_PROJECT"
write_default_value "SPINNAKER_GOOGLE_DEFAULT_ZONE" "$MY_ZONE"
write_default_value "SPINNAKER_GOOGLE_DEFAULT_REGION" "${MY_ZONE%-*}"
write_default_value "SPINNAKER_DEFAULT_STORAGE_BUCKET" "spinnaker-${MY_PROJECT}"
write_default_value "SPINNAKER_GOOGLE_CONSUL_ENABLED" "false"

# Use local project for stackdriver credentials, not the managed one.
write_default_value "SPINNAKER_STACKDRIVER_PROJECT_NAME" "${MY_PROJECT}"
write_default_value "SPINNAKER_STACKDRIVER_CREDENTIALS_PATH" ""

echo "$STATUS_PREFIX  Extracting Configuration Info"
extract_spinnaker_local_yaml

echo "$STATUS_PREFIX  Extracting Credentials"
extract_spinnaker_credentials

echo "$STATUS_PREFIX  Configuring Spinnaker"
$SPINNAKER_INSTALL_DIR/scripts/reconfigure_spinnaker.sh

do_experimental_startup


# Replace this first time boot with the normal startup script
# that just starts spinnaker (and its dependencies) without configuring anymore.
echo "$STATUS_PREFIX  Cleaning Up"
replace_startup_script

if [[ "$RESTART_BEFORE_UPGRADE" != "true" ]]; then
  echo "Waiting for upgrade before restarting spinnaker."
else
  echo "$STATUS_PREFIX  Restarting Spinnaker"
  start spinnaker
fi


# There appears to be a race condition within cassandra starting thrift while
# we perform the dist-upgrade below. So we're going to try working around
# that by waiting for cassandra to get past its thrift initialization.
# Otherwise, we'd prefer to upgrade first, then wait for cassandra to
# be ready for JMX (7199).
if [[ -f /opt/spinnaker/cassandra/SPINNAKER_INSTALLED_CASSANDRA ]]; then
  if ! nc -z localhost 9160; then
    echo "Waiting for Cassandra to start..."
    while ! nc -z localhost 9160; do
       sleep 1
    done
    echo "Cassandra is ready."
  fi
fi


# Apply outstanding OS updates since time of image creation
# but keep spinnaker version itself intact only during forced dist-upgrade
# This can take several minutes so we are performing it at the end after
# spinnaker has already started and is available.

apt-mark hold $SPINNAKER_SUBSYSTEMS $SPINNAKER_DEPENDENCIES
apt-get -y update
DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" -y dist-upgrade
apt-mark unhold $SPINNAKER_SUBSYSTEMS $SPINNAKER_DEPENDENCIES

if [[ -f /opt/spinnaker/cassandra/SPINNAKER_INSTALLED_CASSANDRA ]]; then
  sed -i "s/start_rpc: false/start_rpc: true/" /etc/cassandra/cassandra.yaml
  while ! $(nodetool enablethrift >& /dev/null); do
    sleep 1
    echo "Retrying..."
  done
fi


if [[ "$RESTART_BEFORE_UPGRADE" != "true" ]]; then
  echo "$STATUS_PREFIX  Restarting Spinnaker"
  start spinnaker
fi

echo "$STATUS_PREFIX  Spinnaker is now configured"
