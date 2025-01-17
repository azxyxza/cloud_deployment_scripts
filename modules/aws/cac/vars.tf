/*
 * Copyright Teradici Corporation 2020-2022;  © Copyright 2022 HP Development Company, L.P.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

variable "aws_region" {
  description = "AWS region"
  default     = "us-west-1"
}

variable "prefix" {
  description = "Prefix to add to name of new resources"
  default     = ""
}

variable "manager_url" {
  description = "Anyware Manager URL (e.g. https://cas.teradici.com)"
  type        = string
}

variable "cac_flag_manager_insecure" {
  description = "CAC install flag that allows unverified SSL access to Anyware Manager"
  type        = bool
  default     = false
}

variable "awm_deployment_sa_file" {
  description = "Location of Anyware Manager Deployment Service Account JSON file"
  type        = string
}

variable "domain_name" {
  description = "Name of the domain to join"
  type        = string

  /* validation notes:
      - the name is at least 2 levels and at most 3, as we have only tested up to 3 levels
  */
  validation {
    condition = (
      length(regexall("([.]local$)", var.domain_name)) == 0 &&
      length(var.domain_name) < 256 &&
      can(regex(
        "(^[A-Za-z0-9][A-Za-z0-9-]{0,13}[A-Za-z0-9][.])([A-Za-z0-9][A-Za-z0-9-]{0,61}[A-Za-z0-9][.]){0,1}([A-Za-z]{2,}$)",
      var.domain_name))
    )
    error_message = "Domain name is invalid. Please try again."
  }
}

variable "domain_controller_ip" {
  description = "Internal IP of the Domain Controller"
  type        = string
}

variable "ad_service_account_username" {
  description = "Active Directory Service Account username"
  type        = string
}

variable "ad_service_account_password" {
  description = "Active Directory Service Account password"
  type        = string
  sensitive   = true
}

variable "lls_ip" {
  description = "Internal IP of the PCoIP License Server"
  default     = ""
}

variable "bucket_name" {
  description = "Name of bucket to retrieve provisioning script."
  type        = string
}

variable "zone_list" {
  description = "Availability Zones in which to deploy Connectors"
  type        = list(string)
}

variable "subnet_list" {
  description = "Subnets to deploy the Cloud Access Connector"
  type        = list(string)
}

variable "instance_count_list" {
  description = "Number of Cloud Access Connector instances to deploy in each Availability Zone"
  type        = list(number)
}

variable "security_group_ids" {
  description = "Security Groups to be applied to the Cloud Access Connector"
  type        = list(string)
}

variable "instance_type" {
  description = "Instance type for the Cloud Access Connector (min 4 GB RAM, 2 vCPUs)"
  default     = "t2.xlarge"
}

variable "disk_size_gb" {
  description = "Disk size (GB) of the Cloud Access Connector (min 12 GB)"
  default     = "50"
}

variable "ami_owner" {
  description = "Owner of AMI for the Cloud Access Connector"
  default     = "099720109477"
}

variable "ami_name" {
  description = "Name of the AMI to create Cloud Access Connector from"
  default     = "ubuntu/images/hvm-ssd/ubuntu-bionic-18.04-amd64-server-*"
}

variable "host_name" {
  description = "Name to give the host"
  default     = "vm-cac"
}

variable "admin_ssh_key_name" {
  description = "Name of Admin SSH Key"
  type        = string
}

variable "cac_version" {
  description = "Version of the Cloud Access Connector to install"
  default     = "latest"
}

variable "teradici_download_token" {
  description = "Token used to download from Teradici"
  default     = "yj39yHtgj68Uv2Qf"
}

variable "ssl_key" {
  description = "SSL private key for the Connector"
  default     = ""

  validation {
    condition     = var.ssl_key == "" ? true : fileexists(var.ssl_key)
    error_message = "The ssl_key file specified does not exist. Please check the file path."
  }
}

variable "ssl_cert" {
  description = "SSL certificate for the Connector"
  default     = ""

  validation {
    condition     = var.ssl_cert == "" ? true : fileexists(var.ssl_cert)
    error_message = "The ssl_cert file specified does not exist. Please check the file path."
  }
}

variable "cac_extra_install_flags" {
  description = "Additional flags for installing CAC"
  default     = ""
}

variable "customer_master_key_id" {
  description = "The ID of the AWS KMS Customer Master Key used to decrypt secrets"
  default     = ""
}

variable "cloudwatch_setup_script" {
  description = "The script that sets up the AWS CloudWatch Logs agent"
  type        = string
}

variable "cloudwatch_enable" {
  description = "Enable AWS CloudWatch Agent for sending logs to AWS CloudWatch"
  default     = true
}

variable "aws_ssm_enable" {
  description = "Enable AWS Session Manager integration for easier SSH/RDP admin access to EC2 instances"
  default     = true
}
