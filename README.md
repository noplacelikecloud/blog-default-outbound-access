# No Place Like Cloud – Default vNet Outbound Traffic

This project provides tooling and guidance to detect and validate **Azure Virtual Networks (vNets) using Default Outbound Internet Access**.  

In 2023 Microsoft introduced the `defaultOutboundAccess` property for Azure subnets. Starting **March 31, 2026**, new vNets will **not** have default outbound connectivity unless an explicit outbound method is configured.  
This project helps you audit existing environments, plan migrations, and test detection logic.

👉 Visit the blog for more details: [https://noplacelike.cloud/](https://noplacelike.cloud/)

---

## 📦 Repository Contents

```
.
├── _tests
│   ├── README.md                # Test infrastructure readme
│   ├── terraform.tfstate        # Terraform state (local, not for version control)
│   ├── terraform.tfstate.backup # Terraform backup
│   ├── test.terraform.tf        # Terraform config to deploy sample subnets/VMs
│   └── test.tfvars              # Example variable file for tests
├── DefaultOutboundVNets.csv      # Example CSV report (script output)
├── Get-vNetsWithDefaultOutbound.ps1 # PowerShell detection script
└── README.md                     # Project documentation (this file)
```

---

## 🔍 Features

- **PowerShell detection script**  
  - Finds vNets/subnets using legacy default outbound access  
  - Flags risky UDR routes (`0.0.0.0/0 → Internet`) without explicit egress  
  - Detects explicit egress via:
    - NAT Gateway  
    - Standard Load Balancer outbound rules  
    - VM NIC Public IPs  
    - UDRs to Virtual Appliances / VPN Gateways  

- **Terraform test infrastructure**  
  - Deploys a lab environment with six subnets covering all outbound scenarios  
  - Lets you validate the detection script against known-good and known-bad cases  

---

## 🛠 Usage

### 1. Run the detection script
```powershell
# Scan current subscription
.\Get-vNetsWithDefaultOutbound.ps1

# Scan tenant-wide, export to CSV
.\Get-vNetsWithDefaultOutbound.ps1 -TenantWide -OutputPath "C:\Reports\DefaultOutboundVNets.csv"

# Get help
.\Get-vNetsWithDefaultOutbound.ps1 -Help

```

The script requires:
- Azure PowerShell `Az` module  
- `Connect-AzAccount` login  
- Reader or Network Contributor permissions  

---

### 2. Deploy test infrastructure
For validation, you can deploy the `_tests` Terraform config. It creates six subnets with different outbound setups:

- **subnet-a** → Default outbound (flagged)  
- **subnet-b** → VM with Public IP (not flagged)  
- **subnet-c** → Subnet with NAT Gateway (not flagged)  
- **subnet-d** → Subnet behind Standard LB outbound rule (not flagged)  
- **subnet-e** → UDR default → VirtualAppliance (not flagged)  
- **subnet-f** → UDR default → Internet (flagged)

Fill the `test.tfvars` file with desired variables and run:

```bash
cd _tests
terraform init
terraform apply
```

After deployment, rerun the detection script — the results should match the expected outcomes above.

Infrastructure can be destroyed with the well-known command:

```bash
terraform destroy
```

---

## 📄 License

```
Copyright (C) 2025 Ing. Bernhard Flür

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <https://www.gnu.org/licenses/>.
```

---

## 🙋 Support

- Blog: [https://noplacelike.cloud/](https://noplacelike.cloud/)  
- Author: **Ing. Bernhard Flür** – Cloud Solutions Architect  

---

✅ With this setup you can **detect**, **validate**, and **prepare** for Azure’s retirement of default vNet outbound Internet access.
