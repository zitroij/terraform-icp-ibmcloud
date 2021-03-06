provider "ibm" {
}

resource "random_id" "clusterid" {
  byte_length = "4"
}

resource "tls_private_key" "installkey" {
  algorithm   = "RSA"
}

resource "tls_private_key" "registry_key" {
  algorithm = "RSA"
  rsa_bits = "4096"
}

resource "tls_self_signed_cert" "registry_cert" {
  key_algorithm   = "RSA"
  private_key_pem = "${tls_private_key.registry_key.private_key_pem}"

  subject {
    common_name  = "${var.deployment}-boot-${random_id.clusterid.hex}.${var.domain}"
  }

  dns_names  = ["${var.deployment}-boot-${random_id.clusterid.hex}.${var.domain}"]
  validity_period_hours = "${24 * 365 * 10}"

  allowed_uses = [
    "server_auth"
  ]
}

data "ibm_network_vlan" "private_vlan" {
  count = "${var.private_vlan_router_hostname != "" ? 1 : 0}"
  router_hostname = "${var.private_vlan_router_hostname}.${var.datacenter}"
  number = "${var.private_vlan_number}"
}

data "ibm_network_vlan" "public_vlan" {
  count = "${var.private_network_only != true && var.public_vlan_router_hostname != "" ? 1 : 0}"
  router_hostname = "${var.public_vlan_router_hostname}.${var.datacenter}"
  number = "${var.public_vlan_number}"
}

data "ibm_compute_ssh_key" "public_key" {
  count = "${length(var.key_name)}"
  label = "${element(var.key_name, count.index)}"
}

locals {
  docker_package_uri = "${var.docker_package_location != "" ? "/tmp/${basename(var.docker_package_location)}" : "" }"
  master_fs_ids = "${compact(
      concat(
        ibm_storage_file.fs_audit.*.id,
        ibm_storage_file.fs_registry.*.id,
        list(""))
    )}"

  # use a local private registry we stand up on the boot node if image location is specified
  inception_parts = "${split("/", var.icp_inception_image)}"
  inception_image = "${var.image_location == "" || length(local.inception_parts) == 3 ?
      "${var.icp_inception_image}" :
      "${var.deployment}-boot-${random_id.clusterid.hex}.${var.domain}/${var.icp_inception_image}" }"

  private_vlan_id = "${element(concat(data.ibm_network_vlan.private_vlan.*.id, list("-1")), 0) }"
  public_vlan_id = "${element(concat(data.ibm_network_vlan.public_vlan.*.id, list("-1")), 0)}"
}

# Generate a random string in case user wants us to generate admin password
resource "random_id" "adminpassword" {
  byte_length = "16"
}

resource "ibm_compute_vm_instance" "icp-boot" {
  hostname = "${var.deployment}-boot-${random_id.clusterid.hex}"
  domain = "${var.domain}"

  os_reference_code = "${var.os_reference_code}"

  datacenter = "${var.datacenter}"

  cores = "${var.boot["cpu_cores"]}"
  memory = "${var.boot["memory"]}"

  network_speed = "${var.boot["network_speed"]}"

  local_disk = "${var.boot["local_disk"]}"
  disks = [
    "${var.boot["disk_size"]}",
    "${var.boot["docker_vol_size"]}"
  ]

  tags = [
    "${var.deployment}",
    "icp-boot",
    "${random_id.clusterid.hex}"
  ]

  hourly_billing = "${var.boot["hourly_billing"]}"
  private_network_only = "${var.private_network_only}"
  public_vlan_id = "${local.public_vlan_id}"
  private_vlan_id = "${local.private_vlan_id}"

  public_security_group_ids = ["${compact(concat(
    ibm_security_group.cluster_public.*.id,
    list("${var.private_network_only != true ? ibm_security_group.boot_node_public.id : "" }")
  ))}"]

  private_security_group_ids = ["${compact(concat(
    list("${ibm_security_group.cluster_private.id}"),
    ibm_security_group.boot_node_public.*.id
  ))}"]

  # Permit an ssh loging for the key owner.
  # You an have multiple keys defined.
  ssh_key_ids = ["${data.ibm_compute_ssh_key.public_key.*.id}"]

  user_metadata = <<EOF
#cloud-config
packages:
  - unzip
  - python
  - pv
rh_subscription:
  enable-repo: rhel-7-server-extras-rpms
users:
  - default
  - name: icpdeploy
    groups: [ wheel ]
    sudo: [ "ALL=(ALL) NOPASSWD:ALL" ]
    shell: /bin/bash
    ssh-authorized-keys:
      - ${tls_private_key.installkey.public_key_openssh}
write_files:
  - path: /opt/ibm/scripts/bootstrap.sh
    permissions: '0755'
    encoding: b64
    content: ${base64encode(file("${path.module}/scripts/bootstrap.sh"))}
  - path: /opt/ibm/scripts/load_image.sh
    permissions: '0755'
    encoding: b64
    content: ${base64encode(file("${path.module}/scripts/load_image.sh"))}
  - path: /etc/registry/registry-cert.pem
    permissions: '600'
    encoding: b64
    content: ${base64encode("${tls_self_signed_cert.registry_cert.cert_pem}")}
  - path: /etc/registry/registry-key.pem
    permissions: '600'
    encoding: b64
    content: ${base64encode("${tls_private_key.registry_key.private_key_pem}")}
runcmd:
  - /opt/ibm/scripts/bootstrap.sh -u icpdeploy ${local.docker_package_uri != "" ? "-p ${local.docker_package_uri}" : "" } -d /dev/xvdc
EOF

  provisioner "file" {
    # copy the local docker installation package if it's set
    connection {
      host          = "${self.ipv4_address_private}"
      user          = "icpdeploy"
      private_key   = "${tls_private_key.installkey.private_key_pem}"
      bastion_host  = "${var.private_network_only ? ibm_compute_vm_instance.icp-boot.ipv4_address_private : ibm_compute_vm_instance.icp-boot.ipv4_address}"
    }

    source = "${var.docker_package_location != "" ? "${var.docker_package_location}" : "${path.module}/icp-install/README.md"}"
    destination = "${local.docker_package_uri != "" ? "${local.docker_package_uri}" : "/dev/null" }"
  }

  notes = "Boot machine for ICP deployment"

  lifecycle {
    ignore_changes = [
      "private_vlan_id",
      "public_vlan_id"
    ]
  }
}

resource "null_resource" "image_load" {
  count = "${var.image_location != "" ? 1 : 0}"

  provisioner "file" {
    connection {
      host          = "${ibm_compute_vm_instance.icp-boot.ipv4_address_private}"
      user          = "icpdeploy"
      private_key   = "${tls_private_key.installkey.private_key_pem}"
      bastion_host  = "${var.private_network_only ? ibm_compute_vm_instance.icp-boot.ipv4_address_private : ibm_compute_vm_instance.icp-boot.ipv4_address}"
    }

    source = "${var.image_location}"
    destination = "/tmp/${basename(var.image_location)}"
  }

  # wait until cloud-init finishes, then load images into a local registry
  provisioner "remote-exec" {
    connection {
      host          = "${ibm_compute_vm_instance.icp-boot.ipv4_address_private}"
      user          = "icpdeploy"
      private_key   = "${tls_private_key.installkey.private_key_pem}"
      bastion_host  = "${var.private_network_only ? ibm_compute_vm_instance.icp-boot.ipv4_address_private : ibm_compute_vm_instance.icp-boot.ipv4_address}"
    }

    inline = [
      "while [ ! -f /var/lib/cloud/instance/boot-finished ]; do sleep 1; done",
      "/opt/ibm/scripts/load_image.sh -p /tmp/${basename(var.image_location)} -r ${var.deployment}-boot-${random_id.clusterid.hex}.${var.domain}"
    ]
  }
}

resource "ibm_compute_vm_instance" "icp-master" {
  depends_on = ["null_resource.image_load"]
  count = "${var.master["nodes"]}"

  hostname = "${format("${lower(var.deployment)}-master%02d-${random_id.clusterid.hex}", count.index + 1) }"
  domain = "${var.domain}"

  os_reference_code = "${var.os_reference_code}"

  datacenter = "${var.datacenter}"
  cores = "${var.master["cpu_cores"]}"
  memory = "${var.master["memory"]}"
  hourly_billing = "${var.master["hourly_billing"]}"

  local_disk = "${var.master["local_disk"]}"
  disks = [
    "${var.master["disk_size"]}",
    "${var.master["docker_vol_size"]}"
  ]

  # Virtual IP uses a secondary IP on public interface
  file_storage_ids = ["${local.master_fs_ids}"]

  network_speed = "${var.master["network_speed"]}"
  private_network_only = "${var.private_network_only}"
  public_vlan_id = "${local.public_vlan_id}"
  private_vlan_id = "${local.private_vlan_id}"


  public_security_group_ids = ["${compact(concat(
    ibm_security_group.cluster_public.*.id
  ))}"]

  private_security_group_ids = [
    "${ibm_security_group.cluster_private.id}",
    "${ibm_security_group.master_group.id}"
  ]

  tags = [
    "${var.deployment}",
    "icp-master",
    "${random_id.clusterid.hex}"
  ]

  user_metadata = <<EOF
#cloud-config
packages:
  - unzip
  - python
rh_subscription:
  enable-repo: rhel-7-server-extras-rpms
users:
  - default
  - name: icpdeploy
    groups: [ wheel ]
    sudo: [ "ALL=(ALL) NOPASSWD:ALL" ]
    shell: /bin/bash
    ssh-authorized-keys:
      - ${tls_private_key.installkey.public_key_openssh}
write_files:
  - path: /opt/ibm/scripts/bootstrap.sh
    permissions: '0755'
    encoding: b64
    content: ${base64encode(file("${path.module}/scripts/bootstrap.sh"))}
  - path: /etc/docker/certs.d/${var.deployment}-boot-${random_id.clusterid.hex}.${var.domain}/ca.crt
    permissions: '600'
    encoding: b64
    content: ${base64encode("${tls_self_signed_cert.registry_cert.cert_pem}")}
mounts:
${var.master["nodes"] > 1 ? "
  - ['${ibm_storage_file.fs_registry.mountpoint}', /var/lib/registry, nfs, defaults, 0, 0]
  - ['${ibm_storage_file.fs_audit.mountpoint}', /var/lib/icp/audit, nfs, defaults, 0, 0]
"
:
"" }
runcmd:
  - /opt/ibm/scripts/bootstrap.sh -u icpdeploy ${local.docker_package_uri != "" ? "-p ${local.docker_package_uri}" : "" } -d /dev/xvdc
  - mkdir -p /var/lib/registry
  - mkdir -p /var/lib/icp/audit
  - echo '${ibm_storage_file.fs_registry.mountpoint} /var/lib/registry nfs defaults 0 0' | tee -a /etc/fstab
  - echo '${ibm_storage_file.fs_audit.mountpoint} /var/lib/icp/audit nfs defaults 0 0' | tee -a /etc/fstab
  - sudo mount -a
  - echo '${ibm_compute_vm_instance.icp-boot.ipv4_address_private} ${var.deployment}-boot-${random_id.clusterid.hex}.${var.domain}' >> /etc/hosts
EOF

  # Permit an ssh loging for the key owner.
  # You an have multiple keys defined.
  ssh_key_ids = ["${data.ibm_compute_ssh_key.public_key.*.id}"]

  notes = "Master node for ICP deployment"

  lifecycle {
    ignore_changes = [
      "private_vlan_id",
      "public_vlan_id"
    ]
  }

  provisioner "file" {
    # copy the local docker installation package if it's set
    connection {
      host          = "${self.ipv4_address_private}"
      user          = "icpdeploy"
      private_key   = "${tls_private_key.installkey.private_key_pem}"
      bastion_host  = "${var.private_network_only ? ibm_compute_vm_instance.icp-boot.ipv4_address_private : ibm_compute_vm_instance.icp-boot.ipv4_address}"
    }

    source = "${var.docker_package_location != "" ? "${var.docker_package_location}" : "${path.module}/icp-install/README.md"}"
    destination = "${local.docker_package_uri != "" ? "${local.docker_package_uri}" : "/dev/null" }"
  }

  # wait until cloud-init finishes
  provisioner "remote-exec" {
    connection {
      user          = "icpdeploy"
      private_key   = "${tls_private_key.installkey.private_key_pem}"
      bastion_host  = "${var.private_network_only ? ibm_compute_vm_instance.icp-boot.ipv4_address_private : ibm_compute_vm_instance.icp-boot.ipv4_address}"
    }

    inline = [
      "while [ ! -f /var/lib/cloud/instance/boot-finished ]; do sleep 1; done"
    ]
  }
}

resource "ibm_compute_vm_instance" "icp-mgmt" {
  depends_on = ["null_resource.image_load"]
  count = "${var.mgmt["nodes"]}"

  hostname = "${format("${lower(var.deployment)}-mgmt%02d-${random_id.clusterid.hex}", count.index + 1) }"
  domain = "${var.domain}"

  os_reference_code = "${var.os_reference_code}"
  datacenter = "${var.datacenter}"

  cores = "${var.mgmt["cpu_cores"]}"
  memory = "${var.mgmt["memory"]}"

  local_disk = "${var.mgmt["local_disk"]}"
  disks = [
    "${var.mgmt["disk_size"]}",
    "${var.mgmt["docker_vol_size"]}"
  ]

  network_speed = "${var.mgmt["network_speed"]}"
  private_network_only = "${var.private_network_only}"
  public_vlan_id = "${local.public_vlan_id}"
  private_vlan_id = "${local.private_vlan_id}"

  public_security_group_ids = ["${compact(concat(
    ibm_security_group.cluster_public.*.id
  ))}"]

  private_security_group_ids = [
    "${ibm_security_group.cluster_private.id}"
  ]

  tags = [
    "${var.deployment}",
    "icp-management",
    "${random_id.clusterid.hex}"
  ]

  # Permit an ssh loging for the key owner.
  # You an have multiple keys defined.
  ssh_key_ids = ["${data.ibm_compute_ssh_key.public_key.*.id}"]

  user_metadata = <<EOF
#cloud-config
packages:
  - unzip
  - python
rh_subscription:
  enable-repo: rhel-7-server-extras-rpms
users:
  - default
  - name: icpdeploy
    groups: [ wheel ]
    sudo: [ "ALL=(ALL) NOPASSWD:ALL" ]
    shell: /bin/bash
    ssh-authorized-keys:
      - ${tls_private_key.installkey.public_key_openssh}
write_files:
  - path: /opt/ibm/scripts/bootstrap.sh
    permissions: '0755'
    encoding: b64
    content: ${base64encode(file("${path.module}/scripts/bootstrap.sh"))}
  - path: /etc/docker/certs.d/${var.deployment}-boot-${random_id.clusterid.hex}.${var.domain}/ca.crt
    permissions: '600'
    encoding: b64
    content: ${base64encode("${tls_self_signed_cert.registry_cert.cert_pem}")}
runcmd:
  - /opt/ibm/scripts/bootstrap.sh -u icpdeploy ${local.docker_package_uri != "" ? "-p ${local.docker_package_uri}" : "" } -d /dev/xvdc
  - echo '${ibm_compute_vm_instance.icp-boot.ipv4_address_private} ${var.deployment}-boot-${random_id.clusterid.hex}.${var.domain}' >> /etc/hosts
EOF

  hourly_billing = "${var.mgmt["hourly_billing"]}"

  notes = "Management node for ICP deployment"

  lifecycle {
    ignore_changes = [
      "private_vlan_id",
      "public_vlan_id"
    ]
  }

  provisioner "file" {
    # copy the local docker installation package if it's set
    connection {
      host          = "${self.ipv4_address_private}"
      user          = "icpdeploy"
      private_key   = "${tls_private_key.installkey.private_key_pem}"
      bastion_host  = "${var.private_network_only ? ibm_compute_vm_instance.icp-boot.ipv4_address_private : ibm_compute_vm_instance.icp-boot.ipv4_address}"
    }

    source = "${var.docker_package_location != "" ? "${var.docker_package_location}" : "${path.module}/icp-install/README.md"}"
    destination = "${local.docker_package_uri != "" ? "${local.docker_package_uri}" : "/dev/null" }"
  }

  # wait until cloud-init finishes
  provisioner "remote-exec" {
    connection {
      user          = "icpdeploy"
      private_key   = "${tls_private_key.installkey.private_key_pem}"
      bastion_host  = "${var.private_network_only ? ibm_compute_vm_instance.icp-boot.ipv4_address_private : ibm_compute_vm_instance.icp-boot.ipv4_address}"
    }

    inline = [
      "while [ ! -f /var/lib/cloud/instance/boot-finished ]; do sleep 1; done"
    ]
  }
}

resource "ibm_compute_vm_instance" "icp-va" {
  count = "${var.va["nodes"]}"
  depends_on = ["null_resource.image_load"]

  hostname = "${format("${lower(var.deployment)}-va%02d-${random_id.clusterid.hex}", count.index + 1) }"
  domain = "${var.domain}"

  os_reference_code = "${var.os_reference_code}"

  datacenter = "${var.datacenter}"
  cores = "${var.va["cpu_cores"]}"
  memory = "${var.va["memory"]}"

  network_speed = "${var.va["network_speed"]}"
  private_network_only = "${var.private_network_only}"
  public_vlan_id = "${local.public_vlan_id}"
  private_vlan_id = "${local.private_vlan_id}"

  public_security_group_ids = ["${compact(concat(
    ibm_security_group.cluster_public.*.id
  ))}"]

  private_security_group_ids = [
    "${ibm_security_group.cluster_private.id}"
  ]

  local_disk = "${var.va["local_disk"]}"
  disks = [
    "${var.va["disk_size"]}",
    "${var.va["docker_vol_size"]}"
  ]

  tags = [
    "${var.deployment}",
    "icp-management",
    "${random_id.clusterid.hex}"
  ]

  hourly_billing = "${var.va["hourly_billing"]}"
  user_metadata = <<EOF
#cloud-config
packages:
  - unzip
  - python
rh_subscription:
  enable-repo: rhel-7-server-extras-rpms
users:
  - default
  - name: icpdeploy
    groups: [ wheel ]
    sudo: [ "ALL=(ALL) NOPASSWD:ALL" ]
    shell: /bin/bash
    ssh-authorized-keys:
      - ${tls_private_key.installkey.public_key_openssh}
write_files:
  - path: /opt/ibm/scripts/bootstrap.sh
    permissions: '0755'
    encoding: b64
    content: ${base64encode(file("${path.module}/scripts/bootstrap.sh"))}
  - path: /etc/docker/certs.d/${var.deployment}-boot-${random_id.clusterid.hex}.${var.domain}/ca.crt
    permissions: '600'
    encoding: b64
    content: ${base64encode("${tls_self_signed_cert.registry_cert.cert_pem}")}
runcmd:
  - /opt/ibm/scripts/bootstrap.sh -u icpdeploy ${local.docker_package_uri != "" ? "-p ${local.docker_package_uri}" : "" } -d /dev/xvdc
  - echo '${ibm_compute_vm_instance.icp-boot.ipv4_address_private} ${var.deployment}-boot-${random_id.clusterid.hex}.${var.domain}' >> /etc/hosts
EOF

  # Permit an ssh loging for the key owner.
  # You an have multiple keys defined.
  ssh_key_ids = ["${data.ibm_compute_ssh_key.public_key.*.id}"]

  notes = "Vulnerability Advisor node for ICP deployment"
  lifecycle {
    ignore_changes = [
      "private_vlan_id",
      "public_vlan_id"
    ]
  }

  provisioner "file" {
    # copy the local docker installation package if it's set
    connection {
      host          = "${self.ipv4_address_private}"
      user          = "icpdeploy"
      private_key   = "${tls_private_key.installkey.private_key_pem}"
      bastion_host  = "${var.private_network_only ? ibm_compute_vm_instance.icp-boot.ipv4_address_private : ibm_compute_vm_instance.icp-boot.ipv4_address}"
    }

    source = "${var.docker_package_location != "" ? "${var.docker_package_location}" : "${path.module}/icp-install/README.md"}"
    destination = "${local.docker_package_uri != "" ? "${local.docker_package_uri}" : "/dev/null" }"
  }

  # wait until cloud-init finishes
  provisioner "remote-exec" {
    connection {
      user          = "icpdeploy"
      private_key   = "${tls_private_key.installkey.private_key_pem}"
      bastion_host  = "${var.private_network_only ? ibm_compute_vm_instance.icp-boot.ipv4_address_private : ibm_compute_vm_instance.icp-boot.ipv4_address}"
    }

    inline = [
      "while [ ! -f /var/lib/cloud/instance/boot-finished ]; do sleep 1; done"
    ]
  }
}

resource "ibm_compute_vm_instance" "icp-proxy" {
  depends_on = ["null_resource.image_load"]
  count = "${var.proxy["nodes"]}"

  hostname = "${format("${lower(var.deployment)}-proxy%02d-${random_id.clusterid.hex}", count.index + 1) }"
  domain = "${var.domain}"

  os_reference_code = "${var.os_reference_code}"

  datacenter = "${var.datacenter}"
  cores = "${var.proxy["cpu_cores"]}"
  memory = "${var.proxy["memory"]}"
  hourly_billing = "${var.proxy["hourly_billing"]}"
  tags = [
    "${var.deployment}",
    "icp-proxy",
    "${random_id.clusterid.hex}"
  ]

  network_speed = "${var.proxy["network_speed"]}"
  private_network_only = "${var.private_network_only}"
  public_vlan_id = "${local.public_vlan_id}"
  private_vlan_id = "${local.private_vlan_id}"

  public_security_group_ids = ["${compact(concat(
    ibm_security_group.cluster_public.*.id
  ))}"]

  private_security_group_ids = [
    "${ibm_security_group.cluster_private.id}",
    "${ibm_security_group.proxy_group.id}"
  ]

  local_disk = "${var.proxy["local_disk"]}"
  disks = [
    "${var.proxy["disk_size"]}",
    "${var.proxy["docker_vol_size"]}"
  ]

  user_metadata = <<EOF
#cloud-config
packages:
  - unzip
  - python
rh_subscription:
  enable-repo: rhel-7-server-extras-rpms
users:
  - default
  - name: icpdeploy
    groups: [ wheel ]
    sudo: [ "ALL=(ALL) NOPASSWD:ALL" ]
    shell: /bin/bash
    ssh-authorized-keys:
      - ${tls_private_key.installkey.public_key_openssh}
write_files:
  - path: /opt/ibm/scripts/bootstrap.sh
    permissions: '0755'
    encoding: b64
    content: ${base64encode(file("${path.module}/scripts/bootstrap.sh"))}
  - path: /etc/docker/certs.d/${var.deployment}-boot-${random_id.clusterid.hex}.${var.domain}/ca.crt
    permissions: '600'
    encoding: b64
    content: ${base64encode("${tls_self_signed_cert.registry_cert.cert_pem}")}
runcmd:
  - /opt/ibm/scripts/bootstrap.sh -u icpdeploy ${local.docker_package_uri != "" ? "-p ${local.docker_package_uri}" : "" } -d /dev/xvdc
  - echo '${ibm_compute_vm_instance.icp-boot.ipv4_address_private} ${var.deployment}-boot-${random_id.clusterid.hex}.${var.domain}' >> /etc/hosts
EOF

  # Permit an ssh loging for the key owner.
  # You an have multiple keys defined.
  ssh_key_ids = ["${data.ibm_compute_ssh_key.public_key.*.id}"]

  notes = "Proxy node for ICP deployment"

  lifecycle {
    ignore_changes = [
      "private_vlan_id",
      "public_vlan_id"
    ]
  }

  provisioner "file" {
    # copy the local docker installation package if it's set
    connection {
      host          = "${self.ipv4_address_private}"
      user          = "icpdeploy"
      private_key   = "${tls_private_key.installkey.private_key_pem}"
      bastion_host  = "${var.private_network_only ? ibm_compute_vm_instance.icp-boot.ipv4_address_private : ibm_compute_vm_instance.icp-boot.ipv4_address}"
    }

    source = "${var.docker_package_location != "" ? "${var.docker_package_location}" : "${path.module}/icp-install/README.md"}"
    destination = "${local.docker_package_uri != "" ? "${local.docker_package_uri}" : "/dev/null" }"
  }

  # wait until cloud-init finishes
  provisioner "remote-exec" {
    connection {
      user          = "icpdeploy"
      private_key   = "${tls_private_key.installkey.private_key_pem}"
      bastion_host  = "${var.private_network_only ? ibm_compute_vm_instance.icp-boot.ipv4_address_private : ibm_compute_vm_instance.icp-boot.ipv4_address}"
    }

    inline = [
      "while [ ! -f /var/lib/cloud/instance/boot-finished ]; do sleep 1; done"
    ]
  }
}


resource "ibm_compute_vm_instance" "icp-worker" {
  depends_on = ["null_resource.image_load"]
  count = "${var.worker["nodes"]}"

  hostname = "${format("${lower(var.deployment)}-worker%02d-${random_id.clusterid.hex}", count.index + 1) }"
  domain = "${var.domain}"

  os_reference_code = "${var.os_reference_code}"

  datacenter = "${var.datacenter}"

  cores = "${var.worker["cpu_cores"]}"
  memory = "${var.worker["memory"]}"

  network_speed = "${var.worker["network_speed"]}"
  private_network_only = "${var.private_network_only}"
  public_vlan_id = "${local.public_vlan_id}"
  private_vlan_id = "${local.private_vlan_id}"

  public_security_group_ids = ["${compact(concat(
    ibm_security_group.cluster_public.*.id
  ))}"]

  private_security_group_ids = [
    "${ibm_security_group.cluster_private.id}"
  ]

  local_disk = "${var.worker["local_disk"]}"
  disks = [
    "${var.worker["disk_size"]}",
    "${var.worker["docker_vol_size"]}"
  ]

  hourly_billing = "${var.worker["hourly_billing"]}"
  tags = [
    "${var.deployment}",
    "icp-worker",
    "${random_id.clusterid.hex}"
  ]

  user_metadata = <<EOF
#cloud-config
packages:
  - unzip
  - python
rh_subscription:
  enable-repo: rhel-7-server-extras-rpms
users:
  - default
  - name: icpdeploy
    groups: [ wheel ]
    sudo: [ "ALL=(ALL) NOPASSWD:ALL" ]
    shell: /bin/bash
    ssh-authorized-keys:
      - ${tls_private_key.installkey.public_key_openssh}
write_files:
  - path: /opt/ibm/scripts/bootstrap.sh
    permissions: '0755'
    encoding: b64
    content: ${base64encode(file("${path.module}/scripts/bootstrap.sh"))}
  - path: /etc/docker/certs.d/${var.deployment}-boot-${random_id.clusterid.hex}.${var.domain}/ca.crt
    permissions: '600'
    encoding: b64
    content: ${base64encode("${tls_self_signed_cert.registry_cert.cert_pem}")}
runcmd:
  - /opt/ibm/scripts/bootstrap.sh -u icpdeploy ${local.docker_package_uri != "" ? "-p ${local.docker_package_uri}" : "" } -d /dev/xvdc
  - echo '${ibm_compute_vm_instance.icp-boot.ipv4_address_private} ${var.deployment}-boot-${random_id.clusterid.hex}.${var.domain}' >> /etc/hosts
EOF

  # Permit an ssh loging for the key owner.
  # You an have multiple keys defined.
  ssh_key_ids = ["${data.ibm_compute_ssh_key.public_key.*.id}"]

  notes = "Worker node for ICP deployment"

  lifecycle {
    ignore_changes = [
      "private_vlan_id",
      "public_vlan_id"
    ]
  }

  provisioner "file" {
    # copy the local docker installation package if it's set
    connection {
      host          = "${self.ipv4_address_private}"
      user          = "icpdeploy"
      private_key   = "${tls_private_key.installkey.private_key_pem}"
      bastion_host  = "${var.private_network_only ? ibm_compute_vm_instance.icp-boot.ipv4_address_private : ibm_compute_vm_instance.icp-boot.ipv4_address}"
    }

    source = "${var.docker_package_location != "" ? "${var.docker_package_location}" : "${path.module}/icp-install/README.md"}"
    destination = "${local.docker_package_uri != "" ? "${local.docker_package_uri}" : "/dev/null" }"
  }

  # wait until cloud-init finishes
  provisioner "remote-exec" {
    connection {
      user          = "icpdeploy"
      private_key   = "${tls_private_key.installkey.private_key_pem}"
      bastion_host  = "${var.private_network_only ? ibm_compute_vm_instance.icp-boot.ipv4_address_private : ibm_compute_vm_instance.icp-boot.ipv4_address}"
    }

    inline = [
      "while [ ! -f /var/lib/cloud/instance/boot-finished ]; do sleep 1; done"
    ]
  }
}
