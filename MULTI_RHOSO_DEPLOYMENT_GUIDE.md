# Multi-RHOSO Deployment Guide

This guide explains how to deploy multiple RHOSO (Red Hat OpenStack Services on OpenShift) instances on the same OpenShift cluster with separate EDPM compute nodes.

## Table of Contents
- [Overview](#overview)
- [Network Architecture](#network-architecture)
- [Prerequisites](#prerequisites)
- [Deployment Steps](#deployment-steps)
- [Troubleshooting](#troubleshooting)

## Overview

This setup allows you to run multiple isolated OpenStack control planes on the same OpenShift cluster, each with its own EDPM compute nodes. This is useful for:
- Multi-tenant environments
- Testing/development isolation
- Resource partitioning

### Key Architecture Points

1. **Shared VLANs, Separate Subnets**: Multiple RHOSO instances share the same VLAN IDs but use different IP subnets
2. **Namespace Isolation**: Each instance runs in its own Kubernetes namespace
3. **Separate MetalLB Pools**: Each instance has its own IP pools for LoadBalancer services
4. **Secondary IPs on CRC Node**: Required to support MetalLB L2 advertisement across multiple subnets on the same VLAN

## Network Architecture

### Example: Two RHOSO Instances

```
┌─────────────────────────────────────────────────────────────┐
│ VLAN 20 (InternalAPI)                                        │
│   ├─ openstack:  172.17.0.0/24 (CRC: 172.17.0.5)            │
│   └─ openstack2: 172.27.0.0/24 (CRC: 172.27.0.5) [secondary]│
├─────────────────────────────────────────────────────────────┤
│ VLAN 21 (Storage)                                            │
│   ├─ openstack:  172.18.0.0/24 (CRC: 172.18.0.5)            │
│   └─ openstack2: 172.29.0.0/24 (CRC: 172.29.0.5) [secondary]│
├─────────────────────────────────────────────────────────────┤
│ VLAN 22 (Tenant)                                             │
│   ├─ openstack:  172.19.0.0/24 (CRC: 172.19.0.5)            │
│   └─ openstack2: 172.31.0.0/24 (CRC: 172.31.0.5) [secondary]│
├─────────────────────────────────────────────────────────────┤
│ Ctlplane (No VLAN)                                           │
│   ├─ openstack:  192.168.122.80-90 (MetalLB pool)           │
│   └─ openstack2: 192.168.122.110-120 (MetalLB pool)         │
└─────────────────────────────────────────────────────────────┘
```

### IP Allocation Scheme

| Network       | VLAN | openstack Range | openstack2 Range | Notes |
|---------------|------|----------------|------------------|-------|
| Ctlplane      | -    | 192.168.122.80-90 | 192.168.122.110-120 | Separate pools |
| InternalAPI   | 20   | 172.17.0.0/24  | 172.27.0.0/24    | Shared VLAN |
| Storage       | 21   | 172.18.0.0/24  | 172.29.0.0/24    | Shared VLAN |
| Tenant        | 22   | 172.19.0.0/24  | 172.31.0.0/24    | Shared VLAN |
| StorageMgmt   | 23   | 172.20.0.0/24  | 172.32.0.0/24    | Shared VLAN |

## Prerequisites

1. **OpenShift Cluster**: CRC or full OpenShift cluster with RHOSO operators installed
2. **EDPM Compute Nodes**: Separate physical/virtual machines for each RHOSO instance
3. **Network Configuration**: VLANs configured on physical network
4. **Storage**: Local volume provisioner or other storage class
5. **First RHOSO Instance**: A working `openstack` instance already deployed

## Deployment Steps

### Step 1: Create Instance Configuration

Create a configuration file for your second instance (example: `config/multi-rhoso/rhoso2-config.env`):

```bash
#!/bin/bash
# RHOSO Instance 2 Configuration

#############################################
# Multi-RHOSO Instance Identifier
#############################################
export RHOSO_INSTANCE_NAME=rhoso2

#############################################
# Namespace Configuration (MUST be different)
#############################################
export NAMESPACE=openstack2
export OPERATOR_NAMESPACE=openstack-operators

#############################################
# Shared Network Infrastructure (Same as RHOSO1)
#############################################
export NNCP_INTERFACE=enp6s0
export NNCP_BRIDGE=ospbr
export NETWORK_VLAN_START=20        # Same VLANs as instance 1
export NETWORK_VLAN_STEP=1
export NETWORK_MTU=1500

#############################################
# Instance-Specific Network Addressing
# MUST be unique and non-overlapping with Instance 1
#############################################
export NNCP_CTLPLANE_IP_ADDRESS_PREFIX=192.168.122
export NNCP_CTLPLANE_IP_ADDRESS_SUFFIX=20
export NNCP_DNS_SERVER=192.168.122.1
export NNCP_GATEWAY=192.168.122.1

# Different subnets from instance 1
export NETWORK_INTERNALAPI_ADDRESS_PREFIX=172.27.0
export NETWORK_STORAGE_ADDRESS_PREFIX=172.29.0
export NETWORK_TENANT_ADDRESS_PREFIX=172.31.0
export NETWORK_STORAGEMGMT_ADDRESS_PREFIX=172.32.0

#############################################
# MetalLB IP Pools
# Note: Using separate range from openstack instance
# - openstack uses: 192.168.122.80-90
# - openstack2 uses: 192.168.122.110-120
#############################################
export METALLB_POOL=192.168.122.110-192.168.122.120

#############################################
# Data Plane Configuration
#############################################
export DATAPLANE_COMPUTE_IP=192.168.122.101
export DATAPLANE_COMPUTE_0_IP=192.168.122.101
export DATAPLANE_COMPUTE_0_NAME=edpm-compute-1
export DATAPLANE_TOTAL_NODES=1
```

### Step 2: Deploy Network Configuration (NNCP)

**CRITICAL**: For multi-RHOSO deployments, `make nncp` should ONLY be run for the **first instance** (openstack/rhoso1). For additional instances (openstack2, openstack3, etc.), the Makefile automatically **skips NNCP generation** and **adds secondary IPs only**.

**For instance 2+ (openstack2, openstack3, etc.):**
```bash
# Load the second instance configuration
source config/multi-rhoso/rhoso2-config.env

# This will NOT regenerate NNCP (which would delete previous IPs)
# Instead, it will ONLY add secondary IPs via patching
make nncp
```

**What happens automatically:**
- When `RHOSO_INSTANCE_NAME` is set to anything other than "rhoso1" or "openstack":
  - The Makefile **SKIPS** NNCP generation (preserves existing configuration)
  - Runs `scripts/add-nncp-secondary-ips.sh` to PATCH the existing NNCP
  - Adds secondary IPs to enp6s0.20, enp6s0.21, enp6s0.22, enp6s0.23
  - Script is idempotent (safe to run multiple times)

**Why this is important:**
- The NNCP resource is shared across all RHOSO instances
- Regenerating NNCP would DELETE existing IP addresses from previous instances
- We only generate NNCP once (for instance 1), then PATCH to add secondary IPs

**Manual execution (if needed):**
```bash
bash scripts/add-nncp-secondary-ips.sh
```

**Verification:**
```bash
# Check both primary and secondary IPs on CRC node
oc debug node/crc -- chroot /host ip addr show enp6s0.20 | grep "inet 172"
# Should show BOTH:
#   - 172.17.0.5/24 (openstack1 primary)
#   - 172.27.0.5/24 (openstack2 secondary)
```

### Step 3: Complete Deployment

```bash
# Load instance configuration (if not already sourced)
source config/multi-rhoso/rhoso2-config.env

# Create namespace
make namespace

# Create network attachments
make netattach

# Create MetalLB pools
make metallb_config

# Deploy control plane
make openstack_deploy
```

**Note**: The `make nncp` step from Step 2 already added the secondary IPs automatically. The `openstack_deploy` target automatically patches services to use LoadBalancer type.

### Step 4: Verify Control Plane Services

```bash
# Check all services have LoadBalancer IPs
oc get svc -n openstack2 | grep LoadBalancer

# Expected output should show IPs from the configured ranges:
# - dnsmasq-dns: 192.168.122.110-120
# - rabbitmq: 172.27.0.80-90 (InternalAPI range)
# - Other services: IPs from respective network ranges
```

### Step 5: Deploy EDPM Compute Node

```bash
# Still with rhoso2-config.env sourced
make edpm_deploy
```

### Step 6: Verify Compute Registration

```bash
# Check Nova compute service is registered and up
kubectl exec -n openstack2 openstackclient -- openstack compute service list

# Should show nova-compute with State=up
```

## Important Notes

### Why Secondary IPs Are Required

MetalLB in L2 mode requires the advertising node (CRC) to be on the same L2 subnet as the clients (EDPM nodes). Since:
- Instance 1 uses 172.17.0.0/24 on VLAN 20
- Instance 2 uses 172.27.0.0/24 on VLAN 20 (same VLAN, different subnet)

The CRC node needs IPs in both subnets to properly advertise services via ARP.

### ICMP (Ping) Limitations

**Important**: You cannot ping MetalLB LoadBalancer IPs, but actual services work fine.

```bash
# This will fail (expected):
ping 192.168.122.110

# This works (actual service connectivity):
dig +short keystone-internal.openstack2.svc @192.168.122.110
nc -zv 172.27.0.80 5671  # RabbitMQ
```

This is due to MetalLB L2 mode behavior and ICMP redirects. Always test actual service ports, not ping.

### Network Range Planning

When planning IP ranges for multiple instances:

1. **Ensure no overlap** between instances
2. **Use consistent /24 subnets** for easier management
3. **Reserve ranges** for future instances:
   - Instance 1: 172.17.x.x, 172.18.x.x, 172.19.x.x, 172.20.x.x
   - Instance 2: 172.27.x.x, 172.29.x.x, 172.31.x.x, 172.32.x.x
   - Instance 3: 172.37.x.x, 172.39.x.x, 172.41.x.x, 172.42.x.x (if needed)

4. **MetalLB ctlplane pools**: Use separate ranges from the same /24:
   - Instance 1: 192.168.122.80-90
   - Instance 2: 192.168.122.110-120
   - Instance 3: 192.168.122.130-140 (if needed)

## Troubleshooting

### Services Stuck in `<pending>` State

**Symptoms:**
```
dnsmasq-dns   LoadBalancer   10.217.5.78   <pending>   53:30808/UDP
```

**Causes:**
1. MetalLB pools not created
2. Missing secondary IPs on CRC node
3. Wrong pool annotation

**Solutions:**
```bash
# 1. Check MetalLB pools exist
kubectl get ipaddresspools.metallb.io -A | grep openstack2

# 2. Verify secondary IPs
oc debug node/crc -- chroot /host ip addr show enp6s0.20 | grep inet

# 3. Check service annotations
kubectl get svc rabbitmq -n openstack2 -o jsonpath='{.metadata.annotations}' | jq .

# 4. If needed, recreate pools
source config/multi-rhoso/rhoso2-config.env
make metallb_config
```

### RabbitMQ Connection Timeouts from EDPM

**Symptoms:**
```
nova_compute logs show:
Connection failed: timed out (retrying in 3.0 seconds): socket.timeout: timed out
```

**Cause**: Missing secondary IPs on CRC node prevent MetalLB from advertising InternalAPI IPs.

**Solution:**
```bash
# Add secondary IPs
source config/multi-rhoso/rhoso2-config.env
bash scripts/add-nncp-secondary-ips.sh

# Test connectivity
ssh cloud-admin@<EDPM_IP> "nc -zv 172.27.0.80 5671"
```

### NetConfig Created with Wrong Subnets

**Symptoms:**
NetConfig shows 172.17.0.0/24 instead of 172.27.0.0/24

**Cause**: Makefile sed replacements not applied

**Solution**: The fix is already in Makefile lines 1165-1168. If still occurring:
```bash
# Verify environment variables are set
source config/multi-rhoso/rhoso2-config.env
echo $NETWORK_INTERNALAPI_ADDRESS_PREFIX  # Should be 172.27.0

# Delete and recreate NetConfig
make netconfig_deploy_cleanup
make netconfig_deploy
```

### Adding More RHOSO Instances

To add a third instance (openstack3):

1. Create `config/multi-rhoso/rhoso3-config.env` with unique:
   - NAMESPACE=openstack3
   - Network ranges (e.g., 172.37.0.x, 172.39.0.x, etc.)
   - METALLB_POOL=192.168.122.130-140

2. Add secondary IPs:
   ```bash
   source config/multi-rhoso/rhoso3-config.env
   bash scripts/add-nncp-secondary-ips.sh
   ```

3. Deploy as normal:
   ```bash
   make namespace netattach metallb_config openstack_deploy edpm_deploy
   ```

## Production Recommendations

For production multi-RHOSO deployments, consider:

1. **Use BGP Mode** instead of L2 mode for MetalLB:
   - No need for secondary IPs
   - Better scalability
   - Proper L3 routing (ping works!)

2. **Use Separate VLANs** per instance:
   - Complete network isolation
   - Simpler troubleshooting
   - No shared VLAN complexity

3. **Automate NNCP Updates**: Integrate secondary IP addition into your deployment pipeline

4. **Document IP Allocations**: Maintain a spreadsheet/database of IP assignments per instance

## References

- [EDPM Deployment Guide](EDPM_DEPLOYMENT_GUIDE.md)
- [MetalLB Documentation](https://metallb.universe.tf/)
- [NMState Documentation](https://nmstate.io/)
