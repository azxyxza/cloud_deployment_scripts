#!/bin/bash

# Copyright (c) 2020 Teradici Corporation
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.
AD_SERVICE_ACCOUNT_PASSWORD=${ad_service_account_password}
AD_SERVICE_ACCOUNT_USERNAME=${ad_service_account_username}
AWS_REGION=${aws_region}
CUSTOMER_MASTER_KEY_ID=${customer_master_key_id}
DOMAIN_CONTROLLER_IP=${domain_controller_ip}
DOMAIN_NAME=${domain_name}
PCOIP_REGISTRATION_CODE=${pcoip_registration_code}
TERADICI_DOWNLOAD_TOKEN=${teradici_download_token}

exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1

LOG_FILE="/var/log/teradici/provisioning.log"
METADATA_IP="http://169.254.169.254"
TERADICI_REPO_SETUP_SCRIPT_URL="https://dl.teradici.com/$TERADICI_DOWNLOAD_TOKEN/pcoip-agent/cfg/setup/bash.rpm.sh"

log() {
    local message="$1"
    echo "[$(date)] $message"
}

# Try command until zero exit status or exit(1) when non-zero status after max tries
retry() {
    local counter="$1"
    local interval="$2"
    local command="$3"
    local log_message="$4"
    local err_message="$5"
    local count=0

    while [ true ]
    do
        ((count=count+1))
        eval $command && break
        if [ $count -gt $counter ]
        then
            log "$err_message"
            return 1
        else
            log "$log_message Retrying in $interval seconds"
            sleep $interval
        fi
    done
}

get_credentials() {
    # Disable logging of secrets by wrapping the region with set +x and set -x
    set +x
    if [[ -z "$CUSTOMER_MASTER_KEY_ID" ]]; then
        log "--> Script is not using encryption for secrets."

    else
        log "--> Script is using encryption key: '$CUSTOMER_MASTER_KEY_ID'."

        if [[ "$PCOIP_REGISTRATION_CODE" ]]; then
            log "--> Decrypting pcoip_registration_code..."
            PCOIP_REGISTRATION_CODE=$(aws kms decrypt --region $AWS_REGION --ciphertext-blob fileb://<(echo "$PCOIP_REGISTRATION_CODE" | base64 -d) --output text --query Plaintext | base64 -d)
        fi

        log "--> Decrypting ad_service_account_password..."
        AD_SERVICE_ACCOUNT_PASSWORD=$(aws kms decrypt --region $AWS_REGION --ciphertext-blob fileb://<(echo "$AD_SERVICE_ACCOUNT_PASSWORD" | base64 -d) --output text --query Plaintext | base64 -d)
    fi
    set -x
}

check_required_vars() {
    set +x
    if [[ -z "$AD_SERVICE_ACCOUNT_PASSWORD" ]]; then
        log "--> ERROR: Missing Active Directory Service Account Password."
        missing_vars="true"
    fi

    set -x

    if [[ "$missing_vars" = "true" ]]; then
        log "--> Exiting..."
        exit 1
    fi
}

# Update the hostname to match this instance's "Name" Tag
update_hostname() {
    TOKEN=`curl -X PUT "$METADATA_IP/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60"`
    ID=`curl $METADATA_IP/latest/meta-data/instance-id -H "X-aws-ec2-metadata-token: $TOKEN"`
    REGION=`curl $METADATA_IP/latest/dynamic/instance-identity/document/ -H "X-aws-ec2-metadata-token: $TOKEN" | jq -r .region`
    NEW_HOSTNAME=`aws ec2 describe-tags --region $REGION --filters "Name=resource-id,Values=$ID" "Name=key,Values=Name" --output json | jq -r .Tags[0].Value`

    sudo hostnamectl set-hostname $NEW_HOSTNAME.$DOMAIN_NAME
}

exit_and_restart() {
    log "--> Rebooting..."
    (sleep 1; reboot -p) &
    exit
}

install_pcoip_agent() {
    log "--> Getting Teradici PCoIP agent repo..."
    curl --retry 3 --retry-delay 5 -u "token:$TERADICI_DOWNLOAD_TOKEN" -1sLf $TERADICI_REPO_SETUP_SCRIPT_URL | bash
    if [ $? -ne 0 ]; then
        log "--> ERROR: Failed to install PCoIP agent repo."
        exit 1
    fi
    log "--> PCoIP agent repo installed successfully."

    log "--> Installing USB dependencies..."
    retry   3 \
            5 \
            "yum install -y usb-vhci" \
            "--> Non-zero exit status." \
            "--> Warning: Failed to install usb-vhci."

    log "--> Installing PCoIP standard agent..."
    retry   3 \
            5 \
            "yum -y install pcoip-agent-standard" \
            "--> Non-zero exit status." \
            "--> ERROR: Failed to download PCoIP agent."
    if [ $? -eq 1 ]; then
        exit 1
    fi
    log "--> PCoIP agent installed successfully."

    set +x
    if [[ "$PCOIP_REGISTRATION_CODE" ]]; then
        log "--> Registering PCoIP agent license..."
        n=0
        while true; do
            /usr/sbin/pcoip-register-host --registration-code="$PCOIP_REGISTRATION_CODE" && break
            n=$[$n+1]

            if [ $n -ge 10 ]; then
                log "--> ERROR: Failed to register PCoIP agent after $n tries."
                exit 1
            fi

            log "--> ERROR: Failed to register PCoIP agent. Retrying in 10s..."
            sleep 10
        done
        log "--> PCoIP agent registered successfully."

    else
        log "--> No PCoIP Registration Code provided. Skipping PCoIP agent registration..."
    fi
    set -x
}

# Join domain
join_domain() {
    local dns_record_file="dns_record"
    if [[ ! -f "$dns_record_file" ]]
    then
        log "--> DOMAIN NAME: $DOMAIN_NAME"
        log "--> USERNAME: $AD_SERVICE_ACCOUNT_USERNAME"
        log "--> DOMAIN CONTROLLER: $DOMAIN_CONTROLLER_IP"

        # default hostname has the form ip-10-0-0-1.us-west-1.compute.internal,
        # get the first part of it
        VM_NAME=$(echo $(hostname) | sed -n 's/\(^[^.]*\).*/\1/p')

        # Wait for AD service account to be set up
        yum -y install openldap-clients
        log "--> Waiting for AD account $AD_SERVICE_ACCOUNT_USERNAME@$DOMAIN_NAME to be available..."
        set +x
        until ldapwhoami -H ldap://$DOMAIN_CONTROLLER_IP -D $AD_SERVICE_ACCOUNT_USERNAME@$DOMAIN_NAME -w "$AD_SERVICE_ACCOUNT_PASSWORD" -o nettimeout=1 > /dev/null 2>&1
        do
            log "--> $AD_SERVICE_ACCOUNT_USERNAME@$DOMAIN_NAME not available yet, retrying in 10 seconds..."
            sleep 10
        done
        set -x

        # Join domain
        log "--> Installing required packages to join domain..."
        yum -y install sssd realmd oddjob oddjob-mkhomedir adcli samba-common samba-common-tools krb5-workstation openldap-clients policycoreutils-python

        log "--> Joining the domain '$DOMAIN_NAME'..."
        local retries=10

        set +x
        while true
        do
            echo "$AD_SERVICE_ACCOUNT_PASSWORD" | realm join --user="$AD_SERVICE_ACCOUNT_USERNAME@$DOMAIN_NAME" "$DOMAIN_NAME" --verbose >&2

            local rc=$?
            if [[ $rc -eq 0 ]]
            then
                log "--> Successfully joined domain '$DOMAIN_NAME'."
                break
            fi

            if [ $retries -eq 0 ]
            then
                log "--> ERROR: Failed to join domain '$DOMAIN_NAME'."
                return 106
            fi

            log "--> ERROR: Failed to join domain '$DOMAIN_NAME'. $retries retries remaining..."
            retries=$((retries-1))
            sleep 60
        done
        set -x

        domainname "$VM_NAME.$DOMAIN_NAME"
        echo "%$DOMAIN_NAME\\\\Domain\\ Admins ALL=(ALL) ALL" > /etc/sudoers.d/sudoers

        log "--> Registering with DNS..."
        DOMAIN_UPPER=$(echo "$DOMAIN_NAME" | tr '[:lower:]' '[:upper:]')
        IP_ADDRESS=$(hostname -I | grep -Eo '10.([0-9]*\.){2}[0-9]*')
        set +x
        echo "$AD_SERVICE_ACCOUNT_PASSWORD" | kinit "$AD_SERVICE_ACCOUNT_USERNAME"@"$DOMAIN_UPPER"
        set -x
        touch "$dns_record_file"
        echo "server $DOMAIN_CONTROLLER_IP" > "$dns_record_file"
        echo "update add $VM_NAME.$DOMAIN_NAME 600 a $IP_ADDRESS" >> "$dns_record_file"
        echo "send" >> "$dns_record_file"
        nsupdate -g "$dns_record_file" > /var/sky

        log "--> Configuring settings..."
        sed -i '$ a\dyndns_update = True\ndyndns_ttl = 3600\ndyndns_refresh_interval = 43200\ndyndns_update_ptr = True\nldap_user_principal = nosuchattribute' /etc/sssd/sssd.conf
        sed -c -i "s/\\(use_fully_qualified_names *= *\\).*/\\1False/" /etc/sssd/sssd.conf
        sed -c -i "s/\\(fallback_homedir *= *\\).*/\\1\\/home\\/%u/" /etc/sssd/sssd.conf

        # sssd.conf configuration is required first before enabling sssd
        log "--> Restarting messagebus service..."
        if ! (systemctl restart messagebus)
        then
            log "--> ERROR: Failed to restart messagebus service."
            return 106
        fi

        log "--> Enabling and starting sssd service..."
        if ! (systemctl enable sssd --now)
        then
            log "--> ERROR: Failed to start sssd service."
            return 106
        fi
    fi
}

# Open up firewall for PCoIP Agent. By default eth0 is in firewall zone "public"
update_firewall() {
    log "--> Adding 'pcoip-agent' service to public firewall zone..."
    firewall-offline-cmd --zone=public --add-service=pcoip-agent
    systemctl enable firewalld
    systemctl start firewalld
}

if (rpm -q pcoip-agent-standard); then
    exit
fi

if [[ ! -f "$LOG_FILE" ]]
then
    mkdir -p "$(dirname $LOG_FILE)"
    touch "$LOG_FILE"
    chmod +644 "$LOG_FILE"
fi

log "$(date)"

# Print all executed commands to the terminal
set -x

# Redirect stdout and stderr to the log file
exec &>>$LOG_FILE

# EPEL needed for GraphicsMagick-c++, required by PCoIP Agent
yum -y install epel-release
yum -y update
yum install -y wget awscli jq

get_credentials

check_required_vars

update_hostname

# Install GNOME and set it as the desktop
log "--> Installing Linux GUI..."
yum -y groupinstall "GNOME Desktop" "Graphical Administration Tools"
# yum -y groupinstall "Server with GUI"

log "--> Setting default to graphical target..."
systemctl set-default graphical.target

join_domain

if ! (rpm -q pcoip-agent-standard)
then
    install_pcoip_agent
else
    log "--> pcoip-agent-standard is already installed."
fi

update_firewall

log "--> Installation is complete!"

exit_and_restart
