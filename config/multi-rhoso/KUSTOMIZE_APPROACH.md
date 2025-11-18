# Multi-RHOSO with Kustomize Approach

## Overview

This document explains the kustomize-based approach for multi-RHOSO deployment with namespace-prefixed MetalLB pools.

## Why Kustomize?

MetalLB's `serviceAllocation.namespaces` field **only controls access**, not IP range assignment. When multiple namespaces share a pool with multiple IP ranges, MetalLB allocates IPs sequentially from the first available range, regardless of which namespace requests it.

**Problem:**
- Pool `internalapi` has ranges: `172.17.0.80-90` (openstack) and `172.27.0.80-90` (openstack2)
- Services in `openstack2` get IPs from `172.17.0.x` instead of `172.27.0.x`
- This makes IP management confusing and breaks isolation

**Solution:**
- Use separate pool names: `openstack-internalapi`, `openstack2-internalapi`
- Patch OpenStack service annotations to use correct pool names
- Each instance gets IPs from its dedicated range

## How It Works

### 1. MetalLB Pools

The `gen-metallb-config.sh` script creates namespace-prefixed pools:

```yaml
---
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: openstack-internalapi  # ← Prefixed with namespace
  namespace: metallb-system
spec:
  addresses:
  - 172.17.0.80-172.17.0.90
  serviceAllocation:
    namespaces:
    - openstack
---
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: openstack2-internalapi  # ← Different pool
  namespace: metallb-system
spec:
  addresses:
  - 172.27.0.80-172.27.0.90
  serviceAllocation:
    namespaces:
    - openstack2
```

### 2. OpenStack Service Annotations

After deploying the OpenStackControlPlane, patch it to use the correct pool names:

```bash
source config/multi-rhoso/rhoso2-config.env
bash scripts/patch-openstack-metallb-pools.sh
```

This patches the control plane to add annotations like:

```yaml
spec:
  keystone:
    template:
      override:
        service:
          internal:
            metadata:
              annotations:
                metallb.universe.tf/address-pool: openstack2-internalapi
```

### 3. Service Recreation

When the OpenStackControlPlane is patched, the OpenStack operators detect the change and recreate the services with the new annotations. MetalLB then assigns IPs from the correct pool.

## Deployment Workflow

### Deploy Instance 1 (openstack)

```bash
source config/multi-rhoso/rhoso1-config.env

# Create infrastructure
make namespace
make netattach

# Create MetalLB pools (openstack-ctlplane, openstack-internalapi, etc.)
make metallb_config

# Deploy OpenStack
make openstack_deploy

# Patch services to use openstack-prefixed pools
bash scripts/patch-openstack-metallb-pools.sh

# Wait for services to be recreated
watch oc get svc -n openstack
```

### Deploy Instance 2 (openstack2)

```bash
source config/multi-rhoso/rhoso2-config.env

# Create infrastructure
make namespace
make netattach

# Create MetalLB pools (openstack2-ctlplane, openstack2-internalapi, etc.)
make metallb_config

# Deploy OpenStack
make openstack_deploy

# Patch services to use openstack2-prefixed pools
bash scripts/patch-openstack-metallb-pools.sh

# Wait for services to be recreated
watch oc get svc -n openstack2
```

## Verification

### Check MetalLB Pools

```bash
oc get ipaddresspool -n metallb-system
```

Expected output:
```
NAME                        AUTO ASSIGN   ADDRESSES
openstack-ctlplane          true          ["192.168.122.80-192.168.122.90"]
openstack-internalapi       true          ["172.17.0.80-172.17.0.90"]
openstack-storage           true          ["172.18.0.80-172.18.0.90"]
openstack-tenant            true          ["172.19.0.80-172.19.0.90"]
openstack2-ctlplane         true          ["192.168.122.100-192.168.122.110"]
openstack2-internalapi      true          ["172.27.0.80-172.27.0.90"]
openstack2-storage          true          ["172.29.0.80-172.29.0.90"]
openstack2-tenant           true          ["172.31.0.80-172.31.0.90"]
```

### Check Service IPs

```bash
# Instance 1 should use 172.17.0.x range
oc get svc -n openstack | grep LoadBalancer

# Instance 2 should use 172.27.0.x range
oc get svc -n openstack2 | grep LoadBalancer
```

### Check Service Annotations

```bash
oc get svc keystone-internal -n openstack2 -o yaml | grep address-pool
```

Expected:
```yaml
metallb.universe.tf/address-pool: openstack2-internalapi
```

## Pros and Cons

### Advantages
✅ **Clear IP isolation** - Each instance uses dedicated IP ranges
✅ **Scalable** - Easy to add more instances
✅ **Predictable** - You know which IPs belong to which instance
✅ **Works with MetalLB limitations** - Doesn't rely on unsupported features

### Disadvantages
❌ **Requires patching** - Extra step after deployment
❌ **Services recreated** - Brief downtime when patches are applied
❌ **Not upstream** - Modifies OpenStack CRs in non-standard way

## Troubleshooting

### Services still pending after patching

Check if the pool exists and has available IPs:
```bash
oc get ipaddresspool openstack2-internalapi -n metallb-system -o yaml
```

### Services using wrong IP range

Check service annotations:
```bash
oc get svc <service-name> -n <namespace> -o yaml | grep -A 2 annotations
```

If the annotation is missing or wrong, re-run the patch script.

### Patch script fails

The patch script may fail if:
1. OpenStackControlPlane doesn't exist yet (run after `make openstack_deploy`)
2. Service paths don't exist (normal for disabled services)
3. Annotations already set (harmless, can be ignored)

## Future Improvements

Ideally, this would be handled by:
1. **Kustomize overlays** in the deployment pipeline
2. **OpenStack operator enhancement** to support pool name prefixes
3. **MetalLB enhancement** to support namespace-to-IP-range binding

For now, the patch script provides a working solution.
