# AWS EC2 → Azure Migration Lab (Azure Migrate + Terraform)

End-to-end migration of a Windows Server 2022 instance from **AWS EC2** to an **Azure VM** using **Azure Migrate** (discovery, assessment, agent-based replication, test migration, cutover), with infrastructure on both clouds provisioned by **Terraform**.

> **Interview summary:** "I performed an end-to-end AWS-to-Azure server migration with Azure Migrate and Terraform — discovery, assessment, agent-based replication, test migration, and cutover — and resolved cross-cloud networking, quota, capacity, identity, and policy constraints that the original runbook didn't cover."

This README is a complete SOP. It reflects the **current (2026) Azure Migrate portal layout** (*Decide and plan* / *Execute → Migrations*) and documents every issue hit during the build, with fixes.

---

## Table of contents

1. [Architecture](#architecture)
2. [How this differs from the original lab guide](#how-this-differs-from-the-original-lab-guide)
3. [Cost and cost controls](#cost-and-cost-controls)
4. [Prerequisites](#prerequisites)
5. [Repository layout](#repository-layout)
6. [Part 0 — Quota and capacity checks](#part-0--quota-and-capacity-checks)
7. [Part 1 — AWS source environment](#part-1--aws-source-environment)
8. [Part 2 — Azure environment](#part-2--azure-environment)
9. [Part 3 — Migrate project and discovery appliance](#part-3--migrate-project-and-discovery-appliance)
10. [Part 4 — Assessment](#part-4--assessment)
11. [Part 5 — Replication appliance](#part-5--replication-appliance)
12. [Part 6 — Mobility agent and physical server registration](#part-6--mobility-agent-and-physical-server-registration)
13. [Part 7 — Enable replication](#part-7--enable-replication)
14. [Part 8 — Test migration, cutover, and verification](#part-8--test-migration-cutover-and-verification)
15. [Pausing and resuming](#pausing-and-resuming)
16. [Teardown](#teardown)
17. [Troubleshooting reference](#troubleshooting-reference)
18. [Security notes](#security-notes)

---

## Architecture

```
AWS (us-east-2, default VPC 172.31.0.0/16)            Azure (pay-as-you-go subscription)
──────────────────────────────────────────           ─────────────────────────────────────────────────────
                                                      Central US
 ec2-migrate-source-henry                              └─ vnet-migrate-repl-henry (10.2.0.0/16)
   Windows Server 2022, m7i-flex.large                     └─ snet-migrate-repl (10.2.1.0/24)
   Private 172.31.44.145                                       └─ vm-mig-repl-henry  ← REPLICATION APPLIANCE
   Elastic IP (fixed public IP)  ──── 443 / 9443 ────────────►    Standard_B16as_v2 (8 physical cores)
   Mobility agent installed                                       700 GB OS disk, static public IP (NAT IP)
        ▲                                ◄──── WinRM 5985 ────
        │ WinRM 5985 (private)                         East US 2  (TARGET REGION)
        │                                              ├─ rg-migrate-source-henry
 ec2-migrate-appliance-henry  ← DISCOVERY APPLIANCE    │   ├─ vnet-migrate-henry (10.1.0.0/16) / snet-migrate
   Windows Server 2022, m7i-flex.large                 │   ├─ stmigrateXXXX (storage)
   Private 172.31.46.21                                │   ├─ law-migrate-henry (Log Analytics)
   (stopped after assessment)                          │   ├─ migrate-project-henry  (created in portal)
                                                       │   └─ migrate-project-henry-MigrateVault-NNNN (auto-created)
                                                       └─ rg-migrate-target-henry
                                                           ├─ nsg-migrate-target-henry
                                                           └─ EC2AMAZ-XXXXXXX  ← MIGRATED VM (created at cutover)
```

### Traffic flows

| From | To | Port | Purpose |
|---|---|---|---|
| Discovery appliance (AWS) | Source **private** IP | TCP 5985 (WinRM HTTP) | Discovery and inventory |
| Replication appliance (Azure) | Source **Elastic IP** | TCP 5985 (WinRM HTTP) | Physical server registration |
| Source (Mobility agent) | Replication appliance **public IP** | TCP 443, 9443 | Replication control and data |
| Both appliances | Azure service endpoints | TCP 443 outbound | Registration, telemetry, data upload |

### Why the components live where they do

- **Discovery appliance in AWS:** it sits in the same subnet as the source, so it discovers over the private network with no public WinRM exposure. Free-plan eligible.
- **Replication appliance in Azure (Central US):** Microsoft requires 8 cores / 16 GB, which exceeds the AWS free plan. Placing it in a different region from the target keeps its vCPUs out of the target region's quota.
- **Target in East US 2:** cheap, large region, and geographically close to AWS us-east-2 (Ohio).

---

## How this differs from the original lab guide

| Original guide | Reality / this repo |
|---|---|
| "Agentless" migration | AWS and physical servers use **agent-based** replication. The **Mobility agent** must be installed on the source. |
| AWS region us-east-1 | Use whatever region your AWS account allows (here **us-east-2**). |
| Creates a custom VPC | Uses the **default VPC** (custom VPC creation may be blocked by account guardrails). |
| Security group name `sg-migrate-...` | AWS forbids names starting with `sg-`. Renamed to `migrate-source-sg-...`. |
| Appliance VMs in Azure as `Standard_A4_v2` | A4_v2 is often unavailable to new subscriptions. The replication appliance needs **8 physical cores** and **600 GB free on C:**. |
| Appliance OS disk 80 GB | Windows Server 2022 image is **127 GB** minimum; replication appliance needs **700 GB**. |
| Recovery Services vault `soft_delete_enabled = false` | No longer allowed by Azure. Must be `true`. |
| Vault created by Terraform is used for replication | Azure Migrate **creates its own vault** (`<project>-MigrateVault-NNNN`) and uses that one. |
| Expect 10 AWS resources | The guide's own code creates 14. This repo's AWS side creates 12 (with the discovery appliance and Elastic IP). |
| Classic Azure Migrate UI | Current UI: **Decide and plan** (assessments) and **Execute → Migrations** (replication). |
| Credential 1 = AWS access keys | Not used. Appliances connect to the OS over WinRM; they never call the AWS API. |
| Discovery source = EC2 public IP | Use the **private** IP when the appliance is in the same VPC. |

---

## Cost and cost controls

Approximate, for a lab completed in two or three focused sessions:

| Item | Cost driver | Notes |
|---|---|---|
| 2× Windows EC2 (m7i-flex.large) | AWS free-plan credit | Stop when idle |
| Elastic IP | ~$0.005/hr while instance stopped | Free while attached to a running instance |
| Replication appliance (B16as_v2 + 700 GB disk) | Largest cost, roughly $1/hr while running | **Deallocate** when idle; disk ~$1–2/day |
| Migrated VM (E2bs_v5 or similar) | Cents per hour | Run only long enough to verify |
| Storage, vaults, VNets, Log Analytics | Pennies per day | |
| Data transfer AWS → Azure | Covered by AWS monthly free egress for one 30 GB disk | |

**Controls:**
- Create a **budget alert** in both clouds before starting (Azure: Cost Management → Budgets; AWS: Billing → Budgets), e.g. $10–15 with email alerts at 50% and 100%.
- Use `az vm deallocate` (not an in-guest shutdown) to stop Azure compute billing.
- Tear everything down as soon as cutover is verified.

---

## Prerequisites

### Accounts

- **AWS account** with programmatic access for Terraform. An account in an AWS Organization may have **SCP guardrails** (region locks, service blocks). Check before starting (see troubleshooting).
- **Azure subscription in a directory you control** (personal pay-as-you-go or free account).
  > ⚠️ **Azure for Students / school tenants will likely not work.** School Entra ID policies typically block the appliance registration sign-in (`AADSTS530035`), and student subscriptions have restricted regions and VM capacity.

### Tools

- Terraform ≥ 1.5
- AWS CLI v2
- Azure CLI
- Git
- Remote Desktop client (`mstsc` on Windows)

### Register Azure resource providers (new subscriptions)

```powershell
foreach ($ns in "Microsoft.Migrate","Microsoft.OffAzure","Microsoft.RecoveryServices","Microsoft.Storage","Microsoft.Network","Microsoft.Compute","Microsoft.KeyVault","Microsoft.OperationalInsights") {
  az provider register --namespace $ns
}
```

---

## Repository layout

```
aws-to-azure-migrate/
├── .gitignore
├── README.md
├── aws-side/
│   ├── main.tf                    # default VPC lookup, source SG + EC2, discovery appliance, Elastic IP, IAM
│   ├── variables.tf
│   ├── outputs.tf
│   ├── region.auto.tfvars         # region, AMI, instance type overrides (no secrets)
│   └── terraform.tfvars.example   # copy to terraform.tfvars and fill in
└── azure-side/
    ├── main.tf                    # RGs, target VNet, storage, vault, LAW, target NSG, replication appliance
    ├── variables.tf
    ├── outputs.tf
    └── terraform.tfvars.example
```

**Never commit** `terraform.tfvars`, `*.tfstate*`, or `.terraform/`. See `.gitignore`.

---

## Part 0 — Quota and capacity checks

Do this **before** deploying. New subscriptions have low quotas and are often blocked from specific VM sizes ("capacity restrictions").

### Azure

```powershell
# Quota per family in a region
az vm list-usage --location centralus -o table
az vm list-usage --location eastus2 -o table

# Is a size restricted for your subscription?
$s = "Standard_B16as_v2"
az vm list-skus --location centralus --size $s --resource-type virtualMachines --query "[].{name:name, restricted:restrictions[].reasonCode}" -o table

# Which quota family does a size belong to?
az vm list-skus --location eastus2 --size Standard_E2bs_v5 --resource-type virtualMachines --query "[0].family" -o tsv
```

What you need:

| Purpose | Region | Example size | Family quota needed |
|---|---|---|---|
| Replication appliance | Central US | `Standard_B16as_v2` (16 vCPU = **8 physical cores**) | Basv2 ≥ 16 |
| Migrated VM (+ test VM, one at a time) | East US 2 | A 2-vCPU size the migration wizard offers (here `Standard_E2bs_v5`) | That family ≥ 2 |

If a family limit is 0, request an increase: **Quotas → Compute** or **Help + support → Service and subscription limits (quotas)**. Small requests on new subscriptions may be routed to a support engineer and approved by email.

> `list-skus` showing "available" does **not** guarantee capacity. A deploy can still fail with `SkuNotAvailable`. The size list in the Azure Migrate replication wizard reflects what Site Recovery will actually accept.

### AWS

- Confirm allowed regions (SCPs) and that your instance types are allowed (free-plan accounts only allow free-tier-eligible types):

```powershell
aws ec2 describe-instance-types --region us-east-2 --filters Name=free-tier-eligible,Values=true --query "InstanceTypes[].[InstanceType,MemoryInfo.SizeInMiB]" --output table
```

Pick an **x86** type (not `*g.*` ARM types; Windows requires x86).

---

## Part 1 — AWS source environment

### 1.1 Configure

```powershell
cd aws-side
copy terraform.tfvars.example terraform.tfvars   # then edit passwords and name
```

`region.auto.tfvars` sets the region, AMI, and instance type. Get the current Windows Server 2022 AMI for your region:

```powershell
aws ssm get-parameter --region us-east-2 --name /aws/service/ami-windows-latest/Windows_Server-2022-English-Full-Base --query Parameter.Value --output text
```

### 1.2 Deploy

```powershell
terraform init
terraform plan
terraform apply
terraform output
```

Outputs include the source private IP, the source Elastic IP, and the discovery appliance IPs.

### 1.3 Prepare the source for remote management

Wait ~10 minutes after apply, then RDP to the source Elastic IP as `Administrator`. In PowerShell (Administrator):

```powershell
Enable-PSRemoting -Force
# Allow WinRM from the replication appliance's public IP (set after Part 5) or the discovery appliance subnet
Set-NetFirewallRule -Name "WINRM-HTTP-In-TCP-PUBLIC" -RemoteAddress Any
```

> Windows restricts WinRM on the **Public** profile to the local subnet by default. After the replication appliance exists, tighten this to its IP:
> `Set-NetFirewallRule -Name "WINRM-HTTP-In-TCP-PUBLIC" -RemoteAddress <replication-appliance-public-ip>`

### 1.4 Why an Elastic IP

Every stop/start gives an EC2 instance a new public IP. The source's public IP is referenced by the replication NSG, the appliance's TrustedHosts, and the appliance's physical-server entry. The Elastic IP keeps it fixed for the whole lab.

---

## Part 2 — Azure environment

```powershell
az account show   # confirm the right subscription
cd ..\azure-side
copy terraform.tfvars.example terraform.tfvars
terraform init
terraform plan
terraform apply
```

Set `source_public_ip` in `variables.tf` (or tfvars) to the source **Elastic IP** so the replication NSG allows it.

Key settings already in the code:

- `soft_delete_enabled = true` on the vault (Azure rejects `false`).
- Provider feature flag so `terraform destroy` can remove resource groups containing resources Azure Migrate created:

```hcl
provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}
```

> Lab-only setting. In production, leave it at the default.

---

## Part 3 — Migrate project and discovery appliance

### 3.1 Create the project (portal)

**Azure Migrate → Create project**

- Resource group: `rg-migrate-source-henry`
- Name: `migrate-project-henry`
- Geography: **United States**

> Create the project **in the portal**, not via REST/`az rest`. An API-created project has no registered tools, and key generation later fails with *"Appliance name not found."*

### 3.2 Generate the discovery appliance key

Project → **Start discovery → Using appliance → For Azure**

- Servers virtualized? **Physical or other (AWS, GCP, Xen, etc.)**
- Appliance name: alphanumeric, **≤ 14 characters**, no hyphens (e.g. `applhenry`)
- **Generate key** → save it
- **Download** the appliance zip

### 3.3 Install on the AWS discovery appliance

RDP to the discovery appliance's public IP as `Administrator`.

1. If the browser won't load the portal: Server Manager → Local Server → **IE Enhanced Security Configuration → Off**.
2. Download and extract the zip, then in PowerShell (Administrator):
   ```powershell
   Set-ExecutionPolicy -Scope Process Bypass -Force
   .\AzureMigrateInstaller.ps1
   ```
   Answers: scenario **3** (Physical or other), cloud **1** (Azure Public), connectivity **1** (Public endpoint). The script removes Internet Explorer and restarts; reconnect afterward.
3. In the **configuration manager**:
   - Run prerequisites.
   - Paste the project key → **Verify**.
   - **Login** using the device code (sign in at `https://microsoft.com/devicelogin`).

### 3.4 Add credentials and discovery source

- **Credential:** type Windows Server, friendly name `ec2winadmin`, username `Administrator`, password = source `admin_password`.
- **HTTPS slider:** off (WinRM HTTP 5985).
- **Discovery source:** the source **private IP** (`terraform output ec2_private_ip`), mapped to `ec2winadmin`.
- **Revalidate**, then **Start discovery**. The server appears in the project in ~15 minutes.

> The discovery source is the **server being migrated**, not the appliance's own IP.

---

## Part 4 — Assessment

Project → **Decide and plan → Assessments → Create** (Azure VM)

- Target location: **East US 2**
- Sizing: *Performance-based* (low confidence with little data) or *As on-premises* (instant result)
- Reserved instances: None
- Group: `aws-ec2-group`, add the server

Review readiness (**Ready for Azure**), recommended size, and monthly cost. Skip wave planning.

After the assessment, **stop the discovery appliance** to save credit:

```powershell
aws ec2 stop-instances --region us-east-2 --instance-ids <discovery-appliance-instance-id>
```

---

## Part 5 — Replication appliance

### 5.1 Requirements (enforced by the installer)

- **8 physical cores** (hyperthreaded vCPUs count as half; `B8as_v2` = 4 cores and fails, `B16as_v2` = 8 cores and passes)
- 16 GB+ RAM
- **≥ 600 GB free on C:** (use a 700 GB OS disk)
- Windows Server 2022
- Must not be the source machine or the discovery appliance

### 5.2 Deploy the VM (Terraform, azure-side)

The replication appliance resources use `var.replication_location` (Central US) with their own VNet/subnet. If you change `replication_location` after deploying, apply in two passes to avoid NIC/subnet region ordering errors:

```powershell
terraform apply -target="azurerm_subnet.replication"
terraform apply
```

If the OS disk was created smaller, increase `disk_size_gb` to 700, apply, then extend C: inside Windows:

```powershell
$max = (Get-PartitionSupportedSize -DriveLetter C).SizeMax
Resize-Partition -DriveLetter C -Size $max
```

> **v6 sizes (e.g. `F8as_v6`) require Gen 2 images.** The default `2022-Datacenter` image is Gen 1. Use `2022-datacenter-g2` if you need v6, or stay with a Gen 1–compatible size like `B16as_v2`.

### 5.3 Set up in the portal (new layout)

Project → **Execute → Migrations → Start execution**

1. **Specify intent:** Servers or virtual machines (VMs) → **Azure VM**.
2. **How will you select workloads?** → **From replication appliance (Physical or others: AWS, GCP, etc.)**.
3. Click **"Click here to set up"** (shown when no appliance is registered).
4. Set the **target region to East US 2** → **Create resources**.
   > ⚠️ The target region is **locked** for the project once you click this.
5. The panel's **documentation link** leads to the installer download (~3.8 GB). There is no direct download button in this panel.
6. Keep the panel; the **registration key** is shown under Step 2 after resources deploy.

### 5.4 Install on the replication VM

RDP in as `replicationadmin`.

```powershell
# The script is inside a nested folder after extraction
cd C:\Users\replicationadmin\Downloads\DRAppliance\DRAppliance
Get-ChildItem -Recurse | Unblock-File
Set-ExecutionPolicy -Scope Process Bypass -Force
.\DRInstaller.ps1
```

> Don't use right-click → *Run with PowerShell*. The window closes on error before you can read it.

### 5.5 Configuration manager

1. **Prerequisites:** must pass (cores, disk, connectivity, time sync).
2. **Appliance components:** choose **Update the components**. If the update fails, retry once, then **Continue**; a freshly downloaded installer is already current.
3. **Replication appliance connectivity:** choose **NAT IP** and enter the VM's **public IP**. The source in AWS cannot reach the Azure private IP.
4. **Register with Recovery Services vault:** friendly name (e.g. `replhenry`) + **ASR replication appliance key** from the portal panel.
5. Leave **vCenter details** empty (VMware only). Ignore the `disk.EnableUUID` note (VMware re-protection only).

Verify in the portal: the appliance appears under the **auto-created vault** (`migrate-project-henry-MigrateVault-NNNN`) → **Site Recovery infrastructure → ASR replication appliances**, status **Healthy**. Find the vault via the portal search bar (search `MigrateVault`); it isn't linked from the Migrate screens.

---

## Part 6 — Mobility agent and physical server registration

This step is **not in the original guide** and is required for AWS/physical migrations.

### 6.1 Verify connectivity from the source

On the source:

```powershell
Test-NetConnection <replication-appliance-public-ip> -Port 443
Test-NetConnection <replication-appliance-public-ip> -Port 9443
```

Both must return `TcpTestSucceeded : True`. If not, check that the NSG's `source_public_ip` matches the source's actual public IP (`curl https://checkip.amazonaws.com` on the source).

### 6.2 Copy the agent installer to the source

The agents are on the replication appliance in **`C:\Software\Agents`**. Use `Microsoft-ASR_UA_<version>_Windows_GA_<date>_release.exe`.

Reliable transfer through your PC using RDP drive redirection (Remote Desktop → Show Options → Local Resources → More → **Drives**) on **both** sessions:

```powershell
# On the replication appliance
Copy-Item "C:\Software\Agents\Microsoft-ASR_UA_*_Windows_*_release.exe" "\\tsclient\C\Users\<you>\Downloads\"

# On the source (robocopy survives RDP drops; plain copy/paste often fails silently)
mkdir C:\Temp
robocopy \\tsclient\C\Users\<you>\Downloads C:\Temp "Microsoft-ASR_UA_*_Windows_*_release.exe" /Z /R:5 /W:5
```

### 6.3 Install the agent (source, PowerShell as Administrator)

```powershell
cd C:\Temp
.\Microsoft-ASR_UA_9.66.7567.1_Windows_GA_20Sep2025_release.exe /q /x:C:\Temp\Extracted
cd C:\Temp\Extracted
.\UnifiedAgentInstaller.exe /Role "MS" /Platform "VmWare" /Silent /CSType CSPrime
```

- `VmWare` is correct for physical servers too.
- Do **not** pass `/InstallationType` (fails with *"Invalid value was specified for command line parameter InstallationType"*).
- The output ends with an **`Agent Config Input: <base64 string>`** line. That string is the machine details.

### 6.4 Register the agent

1. On the replication appliance: configuration manager → **Manage this appliance → Mobility service configuration details** → paste the string → **Download configuration file**.
2. Copy the `.json` to the source `C:\Temp`.
3. On the source:
   ```powershell
   & "C:\Program Files (x86)\Microsoft Azure Site Recovery\agent\UnifiedAgentConfigurator.exe" /SourceConfigFilePath "C:\Temp\<id>_config.json" /CSType CSPrime
   ```
4. Verify:
   ```powershell
   Select-String -Path C:\ProgramData\ASRSetupLogs\ASRUnifiedAgentConfigurator.log -Pattern "ExitCode" | Select-Object -Last 2
   Get-Service svagents, InMage* | Select-Object Name, Status
   ```
   Expect `ExitCode = 0` and both services **Running**. On the appliance, `netstat -ano | findstr ":9443" | findstr ESTABLISHED` should show the source's public IP.

> `CSIP ... 0.0.0.0` in the logs and `drscout.conf` is normal for CSPrime (simplified appliance).

### 6.5 Add the source under Physical server details (required for it to appear in the wizard)

On the **replication appliance** (PowerShell as Administrator):

```powershell
Set-Item WSMan:\localhost\Client\TrustedHosts -Value "<source-elastic-ip>" -Force
Test-WSMan <source-elastic-ip>      # must return protocol info
```

On the **source**, allow WinRM from the appliance:

```powershell
Set-NetFirewallRule -Name "WINRM-HTTP-In-TCP-PUBLIC" -RemoteAddress <replication-appliance-public-ip>
```

Then in the configuration manager → **Manage this appliance → Physical server details**:

1. **Add credentials** first: friendly name `sourceadmin`, `Administrator`, source password.
2. Add the server: IP = source **Elastic IP**, credential = `sourceadmin` → **Add**.
3. If it says Azure needs re-login, sign in again (device code) and retry.

Wait ~15 minutes for the server to sync.

---

## Part 7 — Enable replication

Project → **Execute → Migrations → Start execution** (open fresh)

1. Specify intent: Servers or VMs → Azure VM.
2. **From replication appliance (Physical or others…)** → select your appliance.
3. **Guest credentials:** `sourceadmin`.
4. Workloads: select the server (Windows hostname, e.g. `EC2AMAZ-XXXXXXX`).
5. Target settings: RG `rg-migrate-target-henry`, VNet `vnet-migrate-henry`, subnet `snet-migrate`, cache storage default.
6. **Compute: choose the VM size explicitly.**
   > ⚠️ The wizard may auto-select a large size (here `Standard_M8-2ms`, M-series), which fails later on quota and would be expensive. Pick a **2-vCPU size from the dropdown** whose family you have quota for. The dropdown only lists sizes Site Recovery accepts for your subscription; `list-skus` "available" sizes may still be rejected.
7. Disks: defaults. Tags: `project = azure-migrate-lab`. **Review → start replication**.

Initial replication of a 30 GB disk: ~30–60 minutes. The server moves from **Preparation** to **Testing** when done.

### Reading Site Recovery job errors (when the portal is slow)

```powershell
$sub   = az account show --query id -o tsv
$vault = "migrate-project-henry-MigrateVault-NNNN"
$jurl  = "https://management.azure.com/subscriptions/$sub/resourceGroups/rg-migrate-source-henry/providers/Microsoft.RecoveryServices/vaults/$vault/replicationJobs?api-version=2023-08-01"
$jobs  = (az rest --method get --url $jurl | ConvertFrom-Json).value
$failed = $jobs | Where-Object { $_.properties.state -eq "Failed" } | Sort-Object { $_.properties.startTime } -Descending | Select-Object -First 1
$d = az rest --method get --url ("https://management.azure.com" + $failed.id + "?api-version=2023-08-01") | ConvertFrom-Json
$d.properties.errors | ConvertTo-Json -Depth 8
```

---

## Part 8 — Test migration, cutover, and verification

### 8.1 Test migration

Execute → Migrations → server → **Test migration** → network `vnet-migrate-henry`.

Attach a public IP and NSG to the test VM's NIC:

```powershell
az network nic list -g rg-migrate-target-henry --query "[].{nic:name, ipconfig:ipConfigurations[0].name}" -o table
$nic = "<test nic>"; $ipc = "<test ipconfig>"
az network public-ip create -g rg-migrate-target-henry -n pip-migrate-test --sku Standard --location eastus2
az network nic ip-config update -g rg-migrate-target-henry --nic-name $nic -n $ipc --public-ip-address pip-migrate-test
az network nic update -g rg-migrate-target-henry -n $nic --network-security-group nsg-migrate-target-henry
az network public-ip show -g rg-migrate-target-henry -n pip-migrate-test --query ipAddress -o tsv
```

RDP as `Administrator` (source password). Check `hostname` and `winver`.

Clean up: detach and delete `pip-migrate-test`, then **Clean up test migration** in the portal.

### 8.2 Cutover

Server → **Migrate**. Shut down source first? **No** for a lab (Yes in production to avoid data divergence). ~5–15 minutes.

### 8.3 Verify

Repeat the NIC/public IP/NSG commands with name `pip-migrated-vm` on the migrated VM's NIC, RDP in, and confirm the desktop, hostname, and OS version.

### Verification checklist

- [ ] Source EC2 running in AWS
- [ ] Migrate project created in portal; discovery appliance registered
- [ ] Server discovered and assessed (Ready for Azure)
- [ ] Replication appliance Healthy in the MigrateVault
- [ ] Mobility agent registered (ExitCode 0); physical server added
- [ ] Initial replication complete (Testing stage)
- [ ] Test migration boots; RDP works; cleaned up
- [ ] Cutover complete; migrated VM verified
- [ ] Everything torn down

---

## Pausing and resuming

Nothing replicates while paused, but nothing breaks either.

**Pause:**

```powershell
az vm deallocate -g rg-migrate-source-henry -n vm-mig-repl-henry
aws ec2 stop-instances --region us-east-2 --instance-ids <source-id> <discovery-appliance-id>
az vm show -g rg-migrate-source-henry -n vm-mig-repl-henry -d --query powerState -o tsv   # "VM deallocated"
```

**Resume:** start both, wait 2–3 minutes, re-test 443/9443 from the source. With the Elastic IP, no IP updates are needed. Re-login in the appliance configuration manager if prompted.

> Deallocated VMs still count toward vCPU quota.

---

## Teardown

Order matters.

1. **Portal:** if offered, complete migration / stop replication on the server.
2. **Delete the target RG directly** (the migrated VM's NIC holds the target NSG and source subnet, which Terraform doesn't know about):
   ```powershell
   az group delete -n rg-migrate-target-henry --yes
   ```
3. **Azure side:**
   ```powershell
   cd azure-side
   terraform destroy
   ```
4. **AWS side:**
   ```powershell
   cd ..\aws-side
   terraform destroy
   ```
5. **Verify nothing remains:**
   ```powershell
   az group list --query "[].name" -o tsv | Select-String "migrate"
   aws ec2 describe-instances --region us-east-2 --filters "Name=instance-state-name,Values=pending,running,stopping,stopped" --query "Reservations[].Instances[].InstanceId" --output text
   aws ec2 describe-addresses --region us-east-2 --query "Addresses[].PublicIp" --output text
   ```
   All should be empty. (Unattached Elastic IPs are billed.)
6. **Housekeeping:** deactivate/delete the Terraform IAM user's access keys and remove any broad policies attached during troubleshooting. Delete local `terraform.tfstate*` files.

---

## Troubleshooting reference

### Terraform and file issues

| Error | Cause | Fix |
|---|---|---|
| `Invalid multi-line string` / `Unterminated template string` | Code copied from a PDF wrapped long strings onto two lines | Rejoin each string onto one line |
| `Invalid expression` at `user_data = <<-EOF` | Invisible characters (non-breaking space, CRLF) after the heredoc marker | Retype the line by hand; `sed -i 's/[[:space:]]*$//' *.tf` |
| `Invalid single-argument block definition` | PDF page break merged `variable "x" {` with the next line | Put each argument on its own line |
| `Duplicate resource ... configuration` | Block pasted twice | Delete the partial/duplicate copy |
| `Error acquiring the state lock: open terraform.tfstate: Access is denied` / "No outputs found" | Admin PowerShell opened in `C:\Windows\System32` | `cd` to `aws-side` or `azure-side` first |
| `Provider produced inconsistent result after apply ... Root object was present, but now absent` | Azure API eventual consistency after delete/recreate with same names | Re-run `terraform apply`; import if it then says "already exists" |
| `A resource with the ID ... already exists - needs to be imported` | Resource created outside state (portal attempt or failed apply) | `terraform import <address> <id>`, or delete it and re-apply |
| Import alternates between "exists" and "not found" (Recovery Services vault) | Backend still settling after a recent delete of the same name | Rename (e.g. `rsv-migrate-henry2`) instead of waiting |
| `StorageAccountAlreadyTaken` | Storage names are global; a deleted account's name isn't released immediately | Use a new name (e.g. append digits) |
| `InvalidResourceReference ... both resources are in the same region` | Changed a VNet's region; Terraform created the NIC before the new subnet | `terraform apply -target="azurerm_subnet.<name>"`, then full apply |
| `deleting Resource Group ... still contains Resources` | Azure Migrate created resources Terraform doesn't track | Set `prevent_deletion_if_contains_resources = false`, or `az group delete` |
| `InUseNetworkSecurityGroupCannotBeDeleted` / `InUseSubnetCannotBeDeleted` | Migrated VM's NIC still attached | `az group delete -n rg-migrate-target-henry --yes`, then `terraform destroy` |
| Plan shows "N to add" for resources that already exist | `terraform.tfstate` not in the working folder (e.g. left in CloudShell or a nested unzip folder) | Move the state file into the folder; plan should say "No changes" |

### AWS

| Error | Cause | Fix |
|---|---|---|
| `invalid value for name (cannot begin with sg-)` | AWS reserves `sg-` for security group IDs | Rename (e.g. `migrate-source-sg-...`) |
| `UnauthorizedOperation ... explicit deny in a service control policy` | Account is in an AWS Organization whose SCP blocks the action or region | Check which region works (compare CloudShell's region); switch region; or change the SCP from the management account |
| `AccessDenied ... no identity-based policy allows iam:CreateRole` | Terraform IAM user lacks IAM permissions | Attach required permissions (lab: `AdministratorAccess`; remove afterward) |
| `The specified instance type is not eligible for Free Tier` | Free-plan account | List eligible types; use an x86 one (e.g. `m7i-flex.large`) |
| AMI not valid / `empty result` | AMI IDs are region-specific | Use the SSM parameter command in Part 1 |
| Discovery fails with WinRM error | Windows Firewall Public-profile WinRM limited to local subnet | `Enable-PSRemoting -Force`; adjust `WINRM-HTTP-In-TCP-PUBLIC` remote address |
| Source public IP changed after restart | No Elastic IP | Add `aws_eip`; update NSG, TrustedHosts, physical server entry once |

### Azure subscription, identity, and policy

| Error | Cause | Fix |
|---|---|---|
| `RequestDisallowedByAzure` / policy violation creating resources or Migrate project | Student subscription "Allowed resource deployment regions" policy | `az policy assignment list` to see allowed regions; use them, or switch subscriptions |
| Migrate project creation blocked for United States geography | Geography maps to regions picked by Azure (e.g. Central US or West US 2); one is blocked | Use a geography whose regions are all allowed, or use an unrestricted subscription |
| `Appliance name not found` when generating key | Project created via REST API has no registered tools | Delete and recreate the project in the portal |
| Appliance name rejected | Must be alphanumeric, ≤ 14 characters | e.g. `applhenry` |
| `AADSTS900561: The endpoint only accepts POST requests` | Broken sign-in flow (refresh/back, blocked pop-up, IE ESC) | Fresh device code; sign in at microsoft.com/devicelogin in a private window |
| `AADSTS530035` (blocked by security defaults) on appliance login | School tenant security policy blocks Azure PowerShell / device-code sign-in | Ask IT, or use an Azure subscription in a directory you control |
| `No subscriptions found` / `Tenant ... not found` on `az login` | New subscription still activating; subscription ID passed as tenant ID | Wait; `az account clear`; get tenant ID from Entra ID → Overview |
| `Additional quota is not available` | New subscription; auto-approval declined | Submit to support (approved by email), or choose a family that has quota |

### VM sizing and deployment

| Error | Cause | Fix |
|---|---|---|
| `SkuNotAvailable ... Capacity Restrictions` | Size unavailable to this subscription/region (common on new and student subs) | Try zones `1`/`2`/`3`, other families, or another region; request access |
| `QuotaExceeded` / `core count limit was reached` | Family quota too low | Request quota or choose a family with quota |
| `computer_name` too long | Windows limit is 15 characters | Set `computer_name` explicitly |
| `disk size 80 GB is smaller than ... image: 127 GB` | Windows Server 2022 image disk is 127 GB | `disk_size_gb = 127` or larger |
| `VM size ... cannot boot Hypervisor Generation '1'` | v6 sizes are Gen 2 only | Use `2022-datacenter-g2` image (rebuild) or a Gen 1–compatible size |
| `Provided VM size Standard_D8s_v32 not valid` | Typo | Check the size name |

### Azure Migrate appliances and replication

| Symptom / error | Cause | Fix |
|---|---|---|
| Installer opened and closed immediately | "Run with PowerShell" hides errors | Run from an Administrator PowerShell window |
| `.\DRInstaller.ps1 is not recognized` | Script is in a nested folder | `Get-ChildItem -Recurse -Filter *.ps1` and `cd` there |
| `atleast 600 GB free space is required` | OS disk too small | Resize disk to 700 GB, extend C: |
| `The server has only 4 CPU cores. We recommend 8 cores` (blocks) | Check counts physical cores; 8 vCPUs with SMT = 4 cores | Use a size with 8 physical cores (e.g. `B16as_v2`) |
| `Failed to update appliance components` | Transient download/update failure | Retry once, then Continue |
| No installer download link in the setup panel | New portal layout | Use the panel's documentation link |
| Can't find the vault / replication appliance health | Azure Migrate auto-creates `<project>-MigrateVault-NNNN`, not linked in Migrate UI | Portal search `MigrateVault` → Site Recovery infrastructure → ASR replication appliances |
| Mobility agent install returns immediately, `ExitCode 2 (InvalidCommandLine)` | `/InstallationType CSPrime` not accepted | Omit `/InstallationType` |
| RDP file copy canceled / file never arrives | RDP clipboard/drive transfer dropped | `robocopy ... /Z /R:5 /W:5` over `\\tsclient` |
| `Invoke-RestMethod is not recognized` / `.Trim() was unexpected` | Running in Command Prompt, not PowerShell | Type `powershell` first, or use `curl` |
| PowerShell stuck at `>>` | Unclosed quote or brace | Ctrl+C and re-run line by line |
| Source TCP 443/9443 to appliance fails | NSG allows the wrong source IP, or appliance not finished setting up | Match `source_public_ip` to the source's real public IP; wait for appliance setup; check `netstat` on appliance |
| Agent registered but server never appears in the wizard | Source not added under **Physical server details** | Add it (with credential) per Part 6.5 |
| `Add server failed` — invalid input | No credential selected | Add credentials first |
| `WinRM cannot complete the operation ... public profiles limit access ... same local subnet` | Source firewall + appliance TrustedHosts | Set firewall remote address to appliance IP; set TrustedHosts on appliance; `Test-WSMan` |
| `Azure needs to be relogged into` | Configuration manager session expired | Sign in again (device code), retry |
| Test failover failed: `28075 core count limit ... standardMSFamily ... Attempted: 8` | Wizard auto-selected an M-series target size | Change target size to a quota-backed 2-vCPU size |
| `UpdateVmProperties` failed: size not available / NVMe-only | Size restricted for subscription (even though `list-skus` said available) | Pick a size from the portal dropdown whose family has quota (here `Standard_E2bs_v5`, EBSv5) |
| `az` JMESPath query error in PowerShell (`].name was unexpected`) | PowerShell/`az.cmd` quoting of `[?contains(...)]` | Use simple queries and filter with `Select-String` |

---

## Security notes

- Never commit `terraform.tfvars` or state files. State contains IAM secret keys and passwords in plain text.
- RDP (3389) is open to `0.0.0.0/0` for lab convenience. In real environments, restrict to your IP or use a bastion.
- Replication NSG rules (443/9443) are restricted to the source's Elastic IP.
- WinRM on the source is scoped to the replication appliance's IP.
- The Terraform IAM user had broad permissions during troubleshooting. Remove them and delete its access keys after the lab.
- The lab's IAM service user and access key (from the original guide) are not used by Azure Migrate for physical-server discovery; consider removing them from the code.
