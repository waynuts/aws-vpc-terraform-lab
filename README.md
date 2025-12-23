# AWS VPC Terraform – Production-Like Infrastructure (Beginner Cloud Engineer)

## Overview
This project provisions a production-like AWS VPC using Terraform.  
It demonstrates core AWS networking fundamentals and secure access patterns commonly used in real-world environments.

The infrastructure is designed to be reusable as a base layer for EC2, RDS, and application workloads.

---

## Architecture
- VPC (10.0.0.0/16)
- 2 Public Subnets (Multi-AZ)
- 2 Private Subnets (Multi-AZ)
- Internet Gateway for public subnets
- NAT Gateway for outbound access from private subnets
- Bastion Host for controlled administrative access
- Key Pair managed locally (excluded from version control)

> Private subnets have **no direct inbound internet access**.

---

## Network Design Rationale
- **Public Subnets**
  - Used for internet-facing resources (e.g. Bastion Host)
  - Routes traffic through an Internet Gateway

- **Private Subnets**
  - Intended for application servers and databases
  - No inbound internet traffic allowed

- **NAT Gateway**
  - Enables private instances to access external services (updates, APIs)
  - Prevents exposing private instances to the internet

- **Bastion Host**
  - Acts as a single, controlled entry point
  - SSH access restricted to a trusted IP only

---

## Security Highlights
- SSH access limited to a single trusted IP
- Private EC2 instances are not publicly accessible
- Key pair stored locally and excluded via `.gitignore`
- Network isolation enforced via route tables and security groups

## Secure Access Design (SSM)
This setup does not rely on SSH access to private instances.

- Private EC2 instances have **no public IP**
- No inbound SSH (port 22) exposed
- Access is handled via **AWS Systems Manager Session Manager**
- IAM Role attached to EC2 using Instance Profile
- Follows AWS Well-Architected security best practices

---

## Terraform Structure
```text
.
├── main.tf
├── variables.tf
├── outputs.tf
├── provider.tf
├── versions.tf
├── terraform.tfvars
└── .gitignore
