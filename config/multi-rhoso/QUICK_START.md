# Multi-RHOSO Quick Start Guide

## TL;DR - Deploy Two RHOSO Instances

### Prerequisites
- OpenShift cluster with worker nodes
- Network interface `enp6s0` available on workers
- VLANs 20-26 configured on network switches

---

## Deploy Shared Infrastructure (Once)

```bash
# Navigate to install_yamls directory
cd /home/mcarpio/CLAUDE/install_yamls

# Install cluster-wide operators
make validate_marketplace
make operator_namespace
make nmstate
make metallb

# Configure worker node networking (VLANs)
source config/multi-rhoso/rhoso1-config.env
make nncp
```

**Wait for NNCP to complete** (~2-5 minutes):
```bash
oc get nncp
```

---

## Deploy RHOSO Instance 1

```bash
# Load Instance 1 configuration
source config/multi-rhoso/rhoso1-config.env

# Deploy networking and operators
make namespace
make netattach
make metallb_config
make openstack
make openstack_init

# Deploy control plane (15-30 minutes)
make openstack_deploy

# Wait for control plane
oc wait openstackcontrolplane/openstack-ctrl \
  --for condition=Ready \
  --timeout=30m \
  -n openstack

# Deploy data plane (10-20 minutes)
make edpm_deploy
make edpm_wait_deploy
```

**Verify Instance 1**:
```bash
oc get svc -n openstack | grep LoadBalancer
```

---

## Deploy RHOSO Instance 2

```bash
# Load Instance 2 configuration
source config/multi-rhoso/rhoso2-config.env

# Deploy networking (operators already installed!)
make namespace
make netattach
make metallb_config

# Deploy control plane (15-30 minutes)
make openstack_deploy

# Wait for control plane
oc wait openstackcontrolplane/openstack-ctrl \
  --for condition=Ready \
  --timeout=30m \
  -n openstack2

# Deploy data plane (10-20 minutes)
make edpm_deploy
make edpm_wait_deploy
```

**Verify Instance 2**:
```bash
oc get svc -n openstack2 | grep LoadBalancer
```

---

## Verify Both Instances

```bash
# Check control planes
oc get openstackcontrolplane -A

# Check MetalLB pools
oc get ipaddresspool -n metallb-system

# Check services
oc get svc -n openstack | grep LoadBalancer
oc get svc -n openstack2 | grep LoadBalancer
```

---

## Configuration Summary

| Item | RHOSO Instance 1 | RHOSO Instance 2 |
|------|------------------|------------------|
| Config File | `rhoso1-config.env` | `rhoso2-config.env` |
| Namespace | `openstack` | `openstack2` |
| MetalLB Pool | 192.168.122.80-90 | 192.168.122.100-110 |
| InternalAPI | 172.17.0.0/24 | 172.27.0.0/24 |
| Storage | 172.18.0.0/24 | 172.29.0.0/24 |
| Tenant | 172.19.0.0/24 | 172.31.0.0/24 |

---

## Customizing for Your Environment

Edit the config files before deployment:

```bash
vi config/multi-rhoso/rhoso1-config.env
vi config/multi-rhoso/rhoso2-config.env
```

**Key variables to adjust**:
- `NNCP_INTERFACE` - Your physical interface (default: enp6s0)
- `METALLB_POOL` - Available IP ranges
- `NETWORK_*_ADDRESS_PREFIX` - Your subnet ranges
- `DATAPLANE_COMPUTE_IP` - Your compute node IPs

---

## Common Commands

### Switch Between Instances

```bash
# Work with Instance 1
source config/multi-rhoso/rhoso1-config.env

# Work with Instance 2
source config/multi-rhoso/rhoso2-config.env
```

### Check Deployment Status

```bash
# Control plane
oc get openstackcontrolplane -A

# Data plane
oc get openstackdataplanenodeset -A

# Pods
oc get pods -n openstack
oc get pods -n openstack2
```

### View Logs

```bash
# Control plane logs
oc logs -n openstack <pod-name>

# Operator logs
oc logs -n openstack-operators deployment/openstack-operator-controller-manager
```

---

## Cleanup

### Remove Instance 2
```bash
source config/multi-rhoso/rhoso2-config.env
make edpm_deploy_cleanup
make openstack_deploy_cleanup
make netattach_cleanup
make metallb_config_cleanup
make namespace_cleanup
```

### Remove Instance 1
```bash
source config/multi-rhoso/rhoso1-config.env
make edpm_deploy_cleanup
make openstack_deploy_cleanup
make netattach_cleanup
make metallb_config_cleanup
make namespace_cleanup
```

### Remove Infrastructure
```bash
make openstack_cleanup
make nncp_cleanup
make metallb_cleanup
```

---

## Troubleshooting

### Issue: Service stuck in Pending (no LoadBalancer IP)

**Check**:
```bash
oc get ipaddresspool -n metallb-system
oc describe svc <service-name> -n <namespace>
```

**Fix**: Ensure MetalLB pools are created and don't overlap.

### Issue: Pod fails to attach to network

**Check**:
```bash
oc get network-attachment-definitions -n <namespace>
oc describe pod <pod-name> -n <namespace>
```

**Fix**: Verify NADs exist in the correct namespace.

### Issue: NNCP failed

**Check**:
```bash
oc get nncp
oc describe nncp <nncp-name>
```

**Fix**: Verify interface name and VLAN configuration on switches.

---

## Getting Help

- Full documentation: [MULTI_RHOSO_DEPLOYMENT.md](../../MULTI_RHOSO_DEPLOYMENT.md)
- RHOSO documentation: https://docs.redhat.com/
- OpenStack K8s operators: https://github.com/openstack-k8s-operators
