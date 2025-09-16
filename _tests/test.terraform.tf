terraform {
  required_version = ">= 1.5.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 3.116.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.5.1"
    }
  }
}

variable "location" { default = "westeurope" }
variable "prefix" { default = "dodev" }
variable "admin_username" { default = "azureuser" }
variable "ssh_public_key" { description = "Your SSH public key" }
variable "subscription_id" { description = "Your subscription context" }

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

resource "random_integer" "rnd" {
  min = 10000
  max = 99999
}

locals {
  name = "${var.prefix}-${random_integer.rnd.result}"
}

resource "azurerm_resource_group" "rg" {
  name     = "${local.name}-rg"
  location = var.location
}

# ---------- Networking (VNet + Subnets) ----------
resource "azurerm_virtual_network" "vnet" {
  name                = "${local.name}-vnet"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  address_space       = ["10.42.0.0/16"]
}

# A: default outbound (flag)
resource "azurerm_subnet" "subnet_a" {
  name                 = "subnet-a-default-outbound"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.42.1.0/24"]
  # default_outbound_access_enabled left as provider default (true for older API)
}

# B: NIC with PIP (explicit)
resource "azurerm_subnet" "subnet_b" {
  name                 = "subnet-b-pip"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.42.2.0/24"]
}

# C: NAT GW (explicit)
resource "azurerm_subnet" "subnet_c" {
  name                 = "subnet-c-natgw"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.42.3.0/24"]
  # Simulate "private" behavior explicitly (helpful to test):
  default_outbound_access_enabled = false
}

# D: LB outbound rules (explicit)
resource "azurerm_subnet" "subnet_d" {
  name                 = "subnet-d-lb-outbound"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.42.4.0/24"]
}

# E: UDR default route -> VirtualAppliance (explicit)
resource "azurerm_subnet" "subnet_e" {
  name                 = "subnet-e-udr-appliance"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.42.5.0/24"]
}

# F: UDR default route -> Internet (at risk)
resource "azurerm_subnet" "subnet_f" {
  name                 = "subnet-f-udr-internet"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.42.6.0/24"]
}

# ---------- NAT Gateway for subnet C ----------
resource "azurerm_public_ip" "natgw_pip" {
  name                = "${local.name}-natgw-pip"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_nat_gateway" "natgw" {
  name                = "${local.name}-natgw"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  sku_name            = "Standard"
}

resource "azurerm_nat_gateway_public_ip_association" "natgw_assoc" {
  nat_gateway_id       = azurerm_nat_gateway.natgw.id
  public_ip_address_id = azurerm_public_ip.natgw_pip.id
}

resource "azurerm_subnet_nat_gateway_association" "subnet_c_nat" {
  subnet_id      = azurerm_subnet.subnet_c.id
  nat_gateway_id = azurerm_nat_gateway.natgw.id
}

# ---------- Standard LB with outbound rule for subnet D ----------
resource "azurerm_public_ip" "lb_pip" {
  name                = "${local.name}-lb-pip"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_lb" "lb" {
  name                = "${local.name}-slb"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  sku                 = "Standard"

  frontend_ip_configuration {
    name                 = "fe"
    public_ip_address_id = azurerm_public_ip.lb_pip.id
  }
}

resource "azurerm_lb_backend_address_pool" "bepool" {
  name            = "be-pool"
  loadbalancer_id = azurerm_lb.lb.id
}

# Outbound rule targets the backend pool where VM-D NIC will be registered
resource "azurerm_lb_outbound_rule" "ob" {
  name                    = "egress"
  loadbalancer_id         = azurerm_lb.lb.id
  protocol                = "All"
  backend_address_pool_id = azurerm_lb_backend_address_pool.bepool.id
  frontend_ip_configuration {
    name = azurerm_lb.lb.frontend_ip_configuration[0].name
  }
  idle_timeout_in_minutes = 4
  tcp_reset_enabled       = true
}

# ---------- Route tables ----------
# E: default route to VirtualAppliance (explicit egress via appliance/fw @ 10.42.100.4)
resource "azurerm_route_table" "rt_appliance" {
  name                = "${local.name}-rt-appliance"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location

  route {
    name                   = "default-to-appliance"
    address_prefix         = "0.0.0.0/0"
    next_hop_type          = "VirtualAppliance"
    next_hop_in_ip_address = "10.42.100.4"
  }
}

resource "azurerm_subnet_route_table_association" "e_assoc" {
  subnet_id      = azurerm_subnet.subnet_e.id
  route_table_id = azurerm_route_table.rt_appliance.id
}

# F: default route to Internet (at risk)
resource "azurerm_route_table" "rt_internet" {
  name                = "${local.name}-rt-internet"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location

  route {
    name           = "default-to-internet"
    address_prefix = "0.0.0.0/0"
    next_hop_type  = "Internet"
  }
}

resource "azurerm_subnet_route_table_association" "f_assoc" {
  subnet_id      = azurerm_subnet.subnet_f.id
  route_table_id = azurerm_route_table.rt_internet.id
}

# ---------- Shared compute bits ----------
data "azurerm_platform_image" "ubuntults" {
  location  = azurerm_resource_group.rg.location
  publisher = "Canonical"
  offer     = "0001-com-ubuntu-server-jammy"
  sku       = "22_04-lts-gen2"
}

locals {
  vm_size = "Standard_B1s"
}

# Helper to avoid repeating
resource "azurerm_network_interface" "nic_a" {
  name                = "${local.name}-nic-a"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "ipcfg"
    subnet_id                     = azurerm_subnet.subnet_a.id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_network_interface" "nic_b" {
  name                = "${local.name}-nic-b"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "ipcfg"
    subnet_id                     = azurerm_subnet.subnet_b.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.vm_b_pip.id
  }
}

resource "azurerm_network_interface" "nic_c" {
  name                = "${local.name}-nic-c"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "ipcfg"
    subnet_id                     = azurerm_subnet.subnet_c.id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_network_interface" "nic_d" {
  name                = "${local.name}-nic-d"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "ipcfg"
    subnet_id                     = azurerm_subnet.subnet_d.id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_network_interface" "nic_e" {
  name                = "${local.name}-nic-e"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "ipcfg"
    subnet_id                     = azurerm_subnet.subnet_e.id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_network_interface" "nic_f" {
  name                = "${local.name}-nic-f"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "ipcfg"
    subnet_id                     = azurerm_subnet.subnet_f.id
    private_ip_address_allocation = "Dynamic"
  }
}

# PIP for VM in subnet B
resource "azurerm_public_ip" "vm_b_pip" {
  name                = "${local.name}-vm-b-pip"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  allocation_method   = "Static"
  sku                 = "Standard"
}

# Register NIC-D in LB backend pool (so outbound rule applies)
resource "azurerm_network_interface_backend_address_pool_association" "nic_d_bepool" {
  network_interface_id    = azurerm_network_interface.nic_d.id
  ip_configuration_name   = "ipcfg"
  backend_address_pool_id = azurerm_lb_backend_address_pool.bepool.id
}

# ---------- VMs ----------
resource "azurerm_linux_virtual_machine" "vm_a" {
  name                  = "${local.name}-vm-a"
  resource_group_name   = azurerm_resource_group.rg.name
  location              = azurerm_resource_group.rg.location
  size                  = local.vm_size
  admin_username        = var.admin_username
  network_interface_ids = [azurerm_network_interface.nic_a.id]

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.ssh_public_key
  }

  source_image_reference {
    publisher = data.azurerm_platform_image.ubuntults.publisher
    offer     = data.azurerm_platform_image.ubuntults.offer
    sku       = data.azurerm_platform_image.ubuntults.sku
    version   = "latest"
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }
}

resource "azurerm_linux_virtual_machine" "vm_b" {
  name                  = "${local.name}-vm-b"
  resource_group_name   = azurerm_resource_group.rg.name
  location              = azurerm_resource_group.rg.location
  size                  = local.vm_size
  admin_username        = var.admin_username
  network_interface_ids = [azurerm_network_interface.nic_b.id]

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.ssh_public_key
  }

  source_image_reference {
    publisher = data.azurerm_platform_image.ubuntults.publisher
    offer     = data.azurerm_platform_image.ubuntults.offer
    sku       = data.azurerm_platform_image.ubuntults.sku
    version   = "latest"
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }
}

resource "azurerm_linux_virtual_machine" "vm_c" {
  name                  = "${local.name}-vm-c"
  resource_group_name   = azurerm_resource_group.rg.name
  location              = azurerm_resource_group.rg.location
  size                  = local.vm_size
  admin_username        = var.admin_username
  network_interface_ids = [azurerm_network_interface.nic_c.id]

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.ssh_public_key
  }

  source_image_reference {
    publisher = data.azurerm_platform_image.ubuntults.publisher
    offer     = data.azurerm_platform_image.ubuntults.offer
    sku       = data.azurerm_platform_image.ubuntults.sku
    version   = "latest"
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }
}

resource "azurerm_linux_virtual_machine" "vm_d" {
  name                  = "${local.name}-vm-d"
  resource_group_name   = azurerm_resource_group.rg.name
  location              = azurerm_resource_group.rg.location
  size                  = local.vm_size
  admin_username        = var.admin_username
  network_interface_ids = [azurerm_network_interface.nic_d.id]

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.ssh_public_key
  }

  source_image_reference {
    publisher = data.azurerm_platform_image.ubuntults.publisher
    offer     = data.azurerm_platform_image.ubuntults.offer
    sku       = data.azurerm_platform_image.ubuntults.sku
    version   = "latest"
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }
}

resource "azurerm_linux_virtual_machine" "vm_e" {
  name                  = "${local.name}-vm-e"
  resource_group_name   = azurerm_resource_group.rg.name
  location              = azurerm_resource_group.rg.location
  size                  = local.vm_size
  admin_username        = var.admin_username
  network_interface_ids = [azurerm_network_interface.nic_e.id]

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.ssh_public_key
  }

  source_image_reference {
    publisher = data.azurerm_platform_image.ubuntults.publisher
    offer     = data.azurerm_platform_image.ubuntults.offer
    sku       = data.azurerm_platform_image.ubuntults.sku
    version   = "latest"
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }
}

resource "azurerm_linux_virtual_machine" "vm_f" {
  name                  = "${local.name}-vm-f"
  resource_group_name   = azurerm_resource_group.rg.name
  location              = azurerm_resource_group.rg.location
  size                  = local.vm_size
  admin_username        = var.admin_username
  network_interface_ids = [azurerm_network_interface.nic_f.id]

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.ssh_public_key
  }

  source_image_reference {
    publisher = data.azurerm_platform_image.ubuntults.publisher
    offer     = data.azurerm_platform_image.ubuntults.offer
    sku       = data.azurerm_platform_image.ubuntults.sku
    version   = "latest"
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }
}
