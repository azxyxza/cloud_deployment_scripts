/*
 * Copyright Teradici Corporation 2021;  © Copyright 2021 HP Development Company, L.P.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

locals {
  prefix      = var.prefix != "" ? "${var.prefix}-" : ""
  bucket_name = "${local.prefix}pcoip-scripts-${random_id.bucket-name.hex}"
  # Name of Anyware Manager deployment service account key file in bucket
  awm_deployment_sa_file = "awm-deployment-sa-key.json"
  all_region_set         = setunion(var.cac_region_list, var.ws_region_list)

  gcp_service_account    = jsondecode(file(var.gcp_credentials_file))["client_email"]
  gcp_project_id         = jsondecode(file(var.gcp_credentials_file))["project_id"]
  ops_linux_setup_script = "ops_setup_linux.sh"
  ops_win_setup_script   = "ops_setup_win.ps1"
  log_bucket_name        = "${local.prefix}logging-bucket"
}

resource "random_id" "bucket-name" {
  byte_length = 3
}

resource "google_storage_bucket" "scripts" {
  name          = local.bucket_name
  location      = var.gcp_region
  storage_class = "REGIONAL"
  force_destroy = true
}

resource "google_storage_bucket_object" "awm-deployment-sa-file" {
  bucket = google_storage_bucket.scripts.name
  name   = local.awm_deployment_sa_file
  source = var.awm_deployment_sa_file
}

resource "google_storage_bucket_object" "ops-setup-linux-script" {
  count = var.gcp_ops_agent_enable ? 1 : 0

  bucket = google_storage_bucket.scripts.name
  name   = local.ops_linux_setup_script
  source = "../../../shared/gcp/${local.ops_linux_setup_script}"
}

resource "google_storage_bucket_object" "ops-setup-win-script" {
  count = var.gcp_ops_agent_enable ? 1 : 0

  bucket = google_storage_bucket.scripts.name
  name   = local.ops_win_setup_script
  source = "../../../shared/gcp/${local.ops_win_setup_script}"
}

# Create a log bucket to store selected logs for easier log management, Terraform won't delete the log bucket it created even though 
# the log bucket will be removed from .tfstate after destroyed the deployment, so the log bucket deletion has to be done manually, 
# the log bucket will be in pending deletion status and will be deleted after 7 days. More info at: 
# https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/logging_project_bucket_config
# _Default log bucket created by Google cannot be deleted and need to be disabled before creating the deployment to avoid saving the same logs
# in both _Defualt log bucket and the log bucket created by Terraform
resource "google_logging_project_bucket_config" "main" {
  count = var.gcp_ops_agent_enable ? 1 : 0

  bucket_id      = local.log_bucket_name
  project        = local.gcp_project_id
  location       = "global"
  retention_days = var.gcp_logging_retention_days
}

# Create a sink to route instance logs to desinated log bucket
resource "google_logging_project_sink" "instance-sink" {
  count = var.gcp_ops_agent_enable ? 1 : 0

  name        = "${local.prefix}sink"
  destination = "logging.googleapis.com/${google_logging_project_bucket_config.main[0].id}"
  filter      = "resource.type = gce_instance AND resource.labels.project_id = ${local.gcp_project_id}"

  unique_writer_identity = true
}

module "dc" {
  source = "../../../modules/gcp/dc"

  prefix = var.prefix

  pcoip_agent_install     = var.dc_pcoip_agent_install
  pcoip_agent_version     = var.dc_pcoip_agent_version
  pcoip_registration_code = var.pcoip_registration_code
  teradici_download_token = var.teradici_download_token

  gcp_service_account         = local.gcp_service_account
  kms_cryptokey_id            = var.kms_cryptokey_id
  domain_name                 = var.domain_name
  admin_password              = var.dc_admin_password
  safe_mode_admin_password    = var.safe_mode_admin_password
  ad_service_account_username = var.ad_service_account_username
  ad_service_account_password = var.ad_service_account_password
  domain_users_list           = var.domain_users_list

  bucket_name = google_storage_bucket.scripts.name
  gcp_zone    = var.gcp_zone
  subnet      = google_compute_subnetwork.dc-subnet.self_link
  private_ip  = var.dc_private_ip
  network_tags = [
    google_compute_firewall.allow-google-dns.name,
    google_compute_firewall.allow-rdp.name,
    google_compute_firewall.allow-winrm.name,
    google_compute_firewall.allow-icmp.name,
  ]

  gcp_ops_agent_enable = var.gcp_ops_agent_enable
  ops_setup_script     = local.ops_win_setup_script

  machine_type = var.dc_machine_type
  disk_size_gb = var.dc_disk_size_gb

  disk_image = var.dc_disk_image
}

module "cac" {
  source = "../../../modules/gcp/cac"

  prefix = var.prefix

  cac_flag_manager_insecure = var.cac_flag_manager_insecure
  gcp_service_account       = local.gcp_service_account
  kms_cryptokey_id          = var.kms_cryptokey_id
  manager_url               = var.manager_url

  domain_name                 = var.domain_name
  domain_controller_ip        = module.dc.internal-ip
  ad_service_account_username = var.ad_service_account_username
  ad_service_account_password = var.ad_service_account_password

  bucket_name            = google_storage_bucket.scripts.name
  awm_deployment_sa_file = local.awm_deployment_sa_file

  gcp_region_list        = var.cac_region_list
  subnet_list            = google_compute_subnetwork.cac-subnets[*].self_link
  external_pcoip_ip_list = google_compute_address.nlb-ip[*].address
  enable_cac_external_ip = var.cac_enable_external_ip
  network_tags = [
    google_compute_firewall.allow-ssh.name,
    google_compute_firewall.allow-icmp.name,
    google_compute_firewall.allow-pcoip.name,
  ]

  instance_count_list = var.cac_instance_count_list
  machine_type        = var.cac_machine_type
  disk_size_gb        = var.cac_disk_size_gb

  disk_image = var.cac_disk_image

  cac_admin_user             = var.cac_admin_user
  cac_admin_ssh_pub_key_file = var.cac_admin_ssh_pub_key_file
  cac_version                = var.cac_version
  teradici_download_token    = var.teradici_download_token

  ssl_key  = var.cac_ssl_key
  ssl_cert = var.cac_ssl_cert

  gcp_ops_agent_enable = var.gcp_ops_agent_enable
  ops_setup_script     = local.ops_linux_setup_script

  cac_extra_install_flags = var.cac_extra_install_flags
}

resource "google_compute_target_pool" "cac" {
  count = length(var.cac_region_list)

  name = "${local.prefix}instance-pool-${var.cac_region_list[count.index]}"

  region           = var.cac_region_list[count.index]
  session_affinity = "CLIENT_IP"

  instances = module.cac.instance-self-link-list[count.index]

  # TODO: Google Network Load Balancer only support legacy HTTP health check
  #health_checks =
}

resource "google_compute_address" "nlb-ip" {
  count = length(var.cac_region_list)

  name         = "${local.prefix}nlb-ip-${var.cac_region_list[count.index]}"
  region       = var.cac_region_list[count.index]
  address_type = "EXTERNAL"
}

resource "google_compute_forwarding_rule" "cac-https" {
  count = length(var.cac_region_list)

  name                  = "${local.prefix}cac-https-fwdrule-${var.cac_region_list[count.index]}"
  region                = var.cac_region_list[count.index]
  load_balancing_scheme = "EXTERNAL"
  ip_address            = google_compute_address.nlb-ip[count.index].address
  ip_protocol           = "TCP"
  port_range            = "443"
  target                = google_compute_target_pool.cac[count.index].self_link
}

resource "google_compute_forwarding_rule" "cac-tcp4172" {
  count = length(var.cac_region_list)

  name                  = "${local.prefix}cac-tcp4172-fwdrule-${var.cac_region_list[count.index]}"
  ip_address            = google_compute_address.nlb-ip[count.index].address
  region                = var.cac_region_list[count.index]
  load_balancing_scheme = "EXTERNAL"

  ip_protocol = "TCP"
  port_range  = "4172"
  target      = google_compute_target_pool.cac[count.index].self_link
}

resource "google_compute_forwarding_rule" "cac-udp4172" {
  count = length(var.cac_region_list)

  name                  = "${local.prefix}cac-udp4172-fwdrule-${var.cac_region_list[count.index]}"
  ip_address            = google_compute_address.nlb-ip[count.index].address
  region                = var.cac_region_list[count.index]
  load_balancing_scheme = "EXTERNAL"

  ip_protocol = "UDP"
  port_range  = "4172"
  target      = google_compute_target_pool.cac[count.index].self_link
}

module "win-gfx" {
  source = "../../../modules/gcp/win-gfx"

  prefix = var.prefix

  gcp_service_account = local.gcp_service_account
  kms_cryptokey_id    = var.kms_cryptokey_id

  pcoip_registration_code = var.pcoip_registration_code
  teradici_download_token = var.teradici_download_token
  pcoip_agent_version     = var.win_gfx_pcoip_agent_version

  domain_name                 = var.domain_name
  admin_password              = var.dc_admin_password
  ad_service_account_username = var.ad_service_account_username
  ad_service_account_password = var.ad_service_account_password

  bucket_name      = google_storage_bucket.scripts.name
  zone_list        = var.ws_zone_list
  subnet_list      = google_compute_subnetwork.ws-subnets[*].self_link
  enable_public_ip = var.enable_workstation_public_ip

  idle_shutdown_cpu_utilization              = var.idle_shutdown_cpu_utilization
  idle_shutdown_enable                       = var.idle_shutdown_enable
  idle_shutdown_minutes_idle_before_shutdown = var.idle_shutdown_minutes_idle_before_shutdown
  idle_shutdown_polling_interval_minutes     = var.idle_shutdown_polling_interval_minutes

  network_tags = [
    google_compute_firewall.allow-icmp.name,
    google_compute_firewall.allow-rdp.name,
  ]

  instance_count_list = var.win_gfx_instance_count_list
  instance_name       = var.win_gfx_instance_name
  machine_type        = var.win_gfx_machine_type
  accelerator_type    = var.win_gfx_accelerator_type
  accelerator_count   = var.win_gfx_accelerator_count
  disk_size_gb        = var.win_gfx_disk_size_gb
  disk_image          = var.win_gfx_disk_image

  gcp_ops_agent_enable = var.gcp_ops_agent_enable
  ops_setup_script     = local.ops_win_setup_script

  depends_on = [google_compute_router_nat.nat]
}

module "win-std" {
  source = "../../../modules/gcp/win-std"

  prefix = var.prefix

  gcp_service_account = local.gcp_service_account
  kms_cryptokey_id    = var.kms_cryptokey_id

  pcoip_registration_code = var.pcoip_registration_code
  teradici_download_token = var.teradici_download_token
  pcoip_agent_version     = var.win_std_pcoip_agent_version

  domain_name                 = var.domain_name
  admin_password              = var.dc_admin_password
  ad_service_account_username = var.ad_service_account_username
  ad_service_account_password = var.ad_service_account_password

  bucket_name      = google_storage_bucket.scripts.name
  zone_list        = var.ws_zone_list
  subnet_list      = google_compute_subnetwork.ws-subnets[*].self_link
  enable_public_ip = var.enable_workstation_public_ip

  idle_shutdown_cpu_utilization              = var.idle_shutdown_cpu_utilization
  idle_shutdown_enable                       = var.idle_shutdown_enable
  idle_shutdown_minutes_idle_before_shutdown = var.idle_shutdown_minutes_idle_before_shutdown
  idle_shutdown_polling_interval_minutes     = var.idle_shutdown_polling_interval_minutes

  network_tags = [
    google_compute_firewall.allow-icmp.name,
    google_compute_firewall.allow-rdp.name,
  ]

  instance_count_list = var.win_std_instance_count_list
  instance_name       = var.win_std_instance_name
  machine_type        = var.win_std_machine_type
  disk_size_gb        = var.win_std_disk_size_gb
  disk_image          = var.win_std_disk_image

  gcp_ops_agent_enable = var.gcp_ops_agent_enable
  ops_setup_script     = local.ops_win_setup_script

  depends_on = [google_compute_router_nat.nat]
}

module "centos-gfx" {
  source = "../../../modules/gcp/centos-gfx"

  prefix = var.prefix

  gcp_service_account = local.gcp_service_account
  kms_cryptokey_id    = var.kms_cryptokey_id

  pcoip_registration_code = var.pcoip_registration_code
  teradici_download_token = var.teradici_download_token

  domain_name                 = var.domain_name
  domain_controller_ip        = module.dc.internal-ip
  ad_service_account_username = var.ad_service_account_username
  ad_service_account_password = var.ad_service_account_password

  bucket_name      = google_storage_bucket.scripts.name
  zone_list        = var.ws_zone_list
  subnet_list      = google_compute_subnetwork.ws-subnets[*].self_link
  enable_public_ip = var.enable_workstation_public_ip

  auto_logoff_cpu_utilization            = var.auto_logoff_cpu_utilization
  auto_logoff_enable                     = var.auto_logoff_enable
  auto_logoff_minutes_idle_before_logoff = var.auto_logoff_minutes_idle_before_logoff
  auto_logoff_polling_interval_minutes   = var.auto_logoff_polling_interval_minutes

  idle_shutdown_cpu_utilization              = var.idle_shutdown_cpu_utilization
  idle_shutdown_enable                       = var.idle_shutdown_enable
  idle_shutdown_minutes_idle_before_shutdown = var.idle_shutdown_minutes_idle_before_shutdown
  idle_shutdown_polling_interval_minutes     = var.idle_shutdown_polling_interval_minutes

  network_tags = [
    google_compute_firewall.allow-icmp.name,
    google_compute_firewall.allow-ssh.name,
  ]

  instance_count_list = var.centos_gfx_instance_count_list
  instance_name       = var.centos_gfx_instance_name
  machine_type        = var.centos_gfx_machine_type
  accelerator_type    = var.centos_gfx_accelerator_type
  accelerator_count   = var.centos_gfx_accelerator_count
  disk_size_gb        = var.centos_gfx_disk_size_gb
  disk_image          = var.centos_gfx_disk_image

  ws_admin_user             = var.centos_admin_user
  ws_admin_ssh_pub_key_file = var.centos_admin_ssh_pub_key_file

  gcp_ops_agent_enable = var.gcp_ops_agent_enable
  ops_setup_script     = local.ops_linux_setup_script

  depends_on = [google_compute_router_nat.nat]
}

module "centos-std" {
  source = "../../../modules/gcp/centos-std"

  prefix = var.prefix

  gcp_service_account = local.gcp_service_account
  kms_cryptokey_id    = var.kms_cryptokey_id

  pcoip_registration_code = var.pcoip_registration_code
  teradici_download_token = var.teradici_download_token

  domain_name                 = var.domain_name
  domain_controller_ip        = module.dc.internal-ip
  ad_service_account_username = var.ad_service_account_username
  ad_service_account_password = var.ad_service_account_password

  bucket_name      = google_storage_bucket.scripts.name
  zone_list        = var.ws_zone_list
  subnet_list      = google_compute_subnetwork.ws-subnets[*].self_link
  enable_public_ip = var.enable_workstation_public_ip

  auto_logoff_cpu_utilization            = var.auto_logoff_cpu_utilization
  auto_logoff_enable                     = var.auto_logoff_enable
  auto_logoff_minutes_idle_before_logoff = var.auto_logoff_minutes_idle_before_logoff
  auto_logoff_polling_interval_minutes   = var.auto_logoff_polling_interval_minutes

  idle_shutdown_cpu_utilization              = var.idle_shutdown_cpu_utilization
  idle_shutdown_enable                       = var.idle_shutdown_enable
  idle_shutdown_minutes_idle_before_shutdown = var.idle_shutdown_minutes_idle_before_shutdown
  idle_shutdown_polling_interval_minutes     = var.idle_shutdown_polling_interval_minutes

  network_tags = [
    google_compute_firewall.allow-icmp.name,
    google_compute_firewall.allow-ssh.name,
  ]

  instance_count_list = var.centos_std_instance_count_list
  instance_name       = var.centos_std_instance_name
  machine_type        = var.centos_std_machine_type
  disk_size_gb        = var.centos_std_disk_size_gb
  disk_image          = var.centos_std_disk_image

  ws_admin_user             = var.centos_admin_user
  ws_admin_ssh_pub_key_file = var.centos_admin_ssh_pub_key_file

  gcp_ops_agent_enable = var.gcp_ops_agent_enable
  ops_setup_script     = local.ops_linux_setup_script

  depends_on = [google_compute_router_nat.nat]
}
