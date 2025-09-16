# Azure Default Outbound Detection – Test Infrastructure

This Terraform configuration deploys a **test environment** with multiple subnets and VMs to validate detection of **default outbound Internet access**.  
It’s designed to exercise all the outbound scenarios your PowerShell detection script checks.

---

## 🚀 What gets deployed

A single VNet with **six subnets**, each simulating a different outbound case:

| Subnet      | Setup | Expected detection result |
|-------------|-------|----------------------------|
| **subnet-a** | VM only, no NAT/LB/PIP/UDR | ⚠️ Flagged (legacy default outbound) |
| **subnet-b** | VM with Public IP on NIC | ✅ Not flagged |
| **subnet-c** | VM in subnet with NAT Gateway | ✅ Not flagged |
| **subnet-d** | VM in backend pool of Standard LB **with outbound rule** | ✅ Not flagged |
| **subnet-e** | VM in subnet with UDR default route → **VirtualAppliance** | ✅ Not flagged |
| **subnet-f** | VM in subnet with UDR default route → **Internet** (no NAT/LB/PIP) | ⚠️ Flagged (at risk) |

All VMs are tiny Ubuntu servers (`Standard_B1s`) for low cost.  
You can log in via SSH if needed (see below).

---

## 📋 Prerequisites

- [Terraform ≥ 1.5](https://developer.hashicorp.com/terraform/downloads)
- Azure CLI logged in (`az login`)
- An SSH public key (RSA or Ed25519) available on your Mac/Linux machine

👉 To generate a new SSH key on macOS:
```bash
ssh-keygen -t rsa -b 4096 -C "you@example.com"
pbcopy < ~/.ssh/id_rsa.pub
```

## ⚙️ Usage

1. Clone/download this repo and change into the Terraform directory.
2. Create a `terraform.tfvars` file with your own values:
   ```hcl
   ssh_public_key = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQ...yourkey..."
   location       = "westeurope"
   prefix         = "dodev"
   ```
3. Initialize and apply:
   ```bash
   terraform init
   terraform apply
   ```
4. When finished testing, destroy everything:
   ```bash
   terraform destroy
   ```

## ⚠️ Notes

This is lab-only code, not production-grade.

Always review Azure costs (VMs, NAT GW, LB, Public IPs) and destroy resources after testing.

If you want to simulate hub/spoke routing, extend this config with a hub VNet and firewall NVA.