variable "yourname" { 
  type = string 
} 
  
variable "location" {
  description = "Azure region for target resources. Choose a region close to your AWS region."
  type        = string
  default     = "West US 2"
}
  
variable "tags" { 
  type = map(string) 
  default = { 
    project    = "azure-migrate-lab" 
    managed_by = "terraform" 
  } 
}
variable "replication_admin_password" { 
  description = "Admin password for the replication appliance VM." 
  type        = string 
  sensitive   = true 
}
variable "replication_location" {
  description = "Region for the replication appliance (separate from the target region)."
  type        = string
  default     = "Central US"
}

variable "source_public_ip" {
  description = "Public IP of the AWS source EC2 instance (allowed to reach the appliance)."
  type        = string
  default     = "52.15.160.194"
}