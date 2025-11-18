# Multi-RHOSO Configuration Files

This directory contains configuration files for deploying multiple Red Hat OpenStack Services on OpenShift (RHOSO) instances on the same OpenShift cluster.

## Files in this Directory

- **[rhoso1-config.env](rhoso1-config.env)** - Configuration for RHOSO Instance 1 (openstack namespace)
- **[rhoso2-config.env](rhoso2-config.env)** - Configuration for RHOSO Instance 2 (openstack2 namespace)
- **[QUICK_START.md](QUICK_START.md)** - Quick deployment guide
- **[README.md](README.md)** - This file

## Documentation

- **Quick Start**: [QUICK_START.md](QUICK_START.md)
- **Full Guide**: [../../MULTI_RHOSO_DEPLOYMENT.md](../../MULTI_RHOSO_DEPLOYMENT.md)

## How to Use

### 1. Review and Customize Configuration

Before deployment, review and customize the configuration files to match your environment:

```bash
vi rhoso1-config.env
vi rhoso2-config.env
```

**Important settings to verify**:
- Physical network interface name (`NNCP_INTERFACE`)
- IP address ranges (ensure no overlap with existing networks)
- MetalLB pool ranges (must be available IPs)
- Compute node IP addresses

### 2. Deploy Shared Infrastructure

```bash
cd /home/mcarpio/CLAUDE/install_yamls

# Install cluster-wide components (once for all instances)
make validate_marketplace
make operator_namespace
make nmstate
make metallb

# Configure worker nodes (once for all instances)
source config/multi-rhoso/rhoso1-config.env
make nncp
```

### 3. Deploy RHOSO Instance 1

```bash
source config/multi-rhoso/rhoso1-config.env
make namespace
make netattach
make metallb_config
make openstack
make openstack_init
make openstack_deploy
make edpm_deploy
```

### 4. Deploy RHOSO Instance 2

```bash
source config/multi-rhoso/rhoso2-config.env
make namespace
make netattach
make metallb_config
make openstack_deploy
make edpm_deploy
```

## Network Architecture

### Shared Components
- NMState Operator
- MetalLB Operator
- Physical interface: `enp6s0`
- Bridge: `ospbr`
- VLANs: 20-26

### Per-Instance Components
Each RHOSO instance has its own:
- Namespace
- IP subnets
- MetalLB IP pools
- OpenStack control plane
- Data plane (compute nodes)

## Network Allocation

| Network | VLAN | RHOSO Instance 1 | RHOSO Instance 2 |
|---------|------|------------------|------------------|
| Control Plane | Untagged | 192.168.122.0/24 | 192.168.122.0/24 (different IPs) |
| InternalAPI | 20 | 172.17.0.0/24 | 172.27.0.0/24 |
| Storage | 21 | 172.18.0.0/24 | 172.29.0.0/24 |
| Tenant | 22 | 172.19.0.0/24 | 172.31.0.0/24 |
| StorageMgmt | 23 | 172.20.0.0/24 | 172.32.0.0/24 |
| Octavia | 24 | 172.23.0.0/24 | 172.23.0.0/24 (isolated L2) |
| Designate | 25 | 172.28.0.0/24 | 172.38.0.0/24 |
| Designate Ext | 26 | 172.50.0.0/24 | 172.51.0.0/24 |

### MetalLB Pools

| Pool | RHOSO Instance 1 | RHOSO Instance 2 |
|------|------------------|------------------|
| Control Plane | 192.168.122.80-90 | 192.168.122.100-110 |
| InternalAPI | 172.17.0.80-90 | 172.27.0.80-90 |
| Storage | 172.18.0.80-90 | 172.29.0.80-90 |
| Tenant | 172.19.0.80-90 | 172.31.0.80-90 |

## Key Features

✅ **Resource Sharing**: Single set of operators for multiple RHOSO instances
✅ **Network Isolation**: Each instance uses different IP subnets
✅ **VLAN Reuse**: Same VLANs shared across instances (Approach 1)
✅ **Independent Lifecycle**: Deploy, update, delete instances independently
✅ **Cost Effective**: Minimal resource overhead

## What's New in This Multi-RHOSO Support

The `install_yamls` Makefile has been updated with:

1. **New variable**: `RHOSO_INSTANCE_NAME` - Uniquely identifies each RHOSO instance
2. **Updated script**: `scripts/gen-metallb-config.sh` - Generates unique MetalLB resource names
3. **Configuration files**: Pre-configured for 2 instances with non-overlapping networks

### Example Usage

```bash
# Deploy with instance name
RHOSO_INSTANCE_NAME=rhoso1 make metallb_config

# MetalLB resources created:
# - rhoso1-ctlplane (IPAddressPool)
# - rhoso1-internalapi (IPAddressPool)
# - rhoso1-ctlplane (L2Advertisement)
# - etc.
```

## Adding More Instances

To add a third instance:

1. Copy a config file:
   ```bash
   cp rhoso2-config.env rhoso3-config.env
   ```

2. Edit the new file:
   - Change `RHOSO_INSTANCE_NAME=rhoso3`
   - Change `NAMESPACE=openstack3`
   - Choose new IP subnets (e.g., 172.47.0.0/24, etc.)
   - Choose new MetalLB pool (e.g., 192.168.122.120-130)

3. Deploy:
   ```bash
   source config/multi-rhoso/rhoso3-config.env
   make namespace
   make netattach
   make metallb_config
   make openstack_deploy
   make edpm_deploy
   ```

## Verification

### Check All RHOSO Instances

```bash
# Control planes
oc get openstackcontrolplane -A

# Data planes
oc get openstackdataplanenodeset -A

# MetalLB pools
oc get ipaddresspool -n metallb-system

# Services with IPs
oc get svc -A | grep LoadBalancer
```

### Test Each Instance

```bash
# Instance 1 Keystone
KEYSTONE_IP=$(oc get svc keystone-public -n openstack -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
curl http://${KEYSTONE_IP}:5000/v3

# Instance 2 Keystone
KEYSTONE_IP=$(oc get svc keystone-public -n openstack2 -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
curl http://${KEYSTONE_IP}:5000/v3
```

## Troubleshooting

See the [troubleshooting section](../../MULTI_RHOSO_DEPLOYMENT.md#troubleshooting) in the full deployment guide.

Common issues:
- **MetalLB IP pool conflicts** - Ensure pools don't overlap
- **NNCP failures** - Verify interface name and VLAN support
- **NAD not found** - Ensure NADs are created in the correct namespace
- **Service pending** - Check MetalLB pool availability

## Support

For detailed information, see:
- [MULTI_RHOSO_DEPLOYMENT.md](../../MULTI_RHOSO_DEPLOYMENT.md) - Complete deployment guide
- [QUICK_START.md](QUICK_START.md) - Quick deployment steps

## License

Same as install_yamls repository.
