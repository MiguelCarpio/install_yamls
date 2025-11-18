# MetalLB Multi-RHOSO Architecture

## Overview

This document explains how MetalLB is configured to support multiple RHOSO instances on the same OpenShift cluster using **namespace-scoped IP address pools**.

## The Problem

When deploying multiple RHOSO instances, each instance's OpenStack services request LoadBalancer IPs with annotations like:

```yaml
metallb.universe.tf/address-pool: internalapi
```

If we simply created different pool names for each instance (e.g., `rhoso1-internalapi`, `rhoso2-internalapi`), the OpenStack services wouldn't know which pool to use.

## The Solution: Namespace Scoping

MetalLB supports **namespace-scoped IPAddressPools** using the `serviceAllocation.namespaces` field. This allows us to:

1. **Keep pool names consistent** across RHOSO instances (`internalapi`, `storage`, etc.)
2. **Use different IP ranges** for each instance
3. **Automatically isolate** pools to specific namespaces

### Example Configuration

#### RHOSO Instance 1 (namespace: `openstack`)

```yaml
---
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: internalapi
  namespace: metallb-system
spec:
  addresses:
  - 172.17.0.80-172.17.0.90
  serviceAllocation:
    namespaces:
    - openstack  # ← Only 'openstack' namespace can use this pool
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: internalapi-openstack  # ← Unique name per instance
  namespace: metallb-system
spec:
  ipAddressPools:
  - internalapi
  interfaces:
  - enp6s0.20
```

#### RHOSO Instance 2 (namespace: `openstack2`)

```yaml
---
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: internalapi  # ← Same name!
  namespace: metallb-system
spec:
  addresses:
  - 172.27.0.80-172.27.0.90  # ← Different IP range
  serviceAllocation:
    namespaces:
    - openstack2  # ← Only 'openstack2' namespace can use this pool
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: internalapi-openstack2  # ← Unique name per instance
  namespace: metallb-system
spec:
  ipAddressPools:
  - internalapi
  interfaces:
  - enp6s0.20
```

## How It Works

### Pool Selection

When a service in the `openstack` namespace requests an IP from pool `internalapi`:

1. MetalLB finds **all** IPAddressPools named `internalapi`
2. It filters them by `serviceAllocation.namespaces`
3. Only the pool scoped to `openstack` matches
4. IP is allocated from range `172.17.0.80-90`

When a service in the `openstack2` namespace requests an IP from pool `internalapi`:

1. MetalLB finds **all** IPAddressPools named `internalapi`
2. It filters them by `serviceAllocation.namespaces`
3. Only the pool scoped to `openstack2` matches
4. IP is allocated from range `172.27.0.80-90`

### Resource Names

| Resource Type | Name Pattern | Example |
|---------------|--------------|---------|
| IPAddressPool | Same across instances | `internalapi`, `storage`, `tenant` |
| L2Advertisement | Includes namespace suffix | `internalapi-openstack`, `internalapi-openstack2` |
| BGPPeer | Includes namespace suffix | `bgp-peer-openstack`, `bgp-peer-openstack2` |
| BGPAdvertisement | Includes namespace suffix | `bgpadvertisement-openstack` |

## Implementation in gen-metallb-config.sh

The script automatically detects multi-RHOSO mode by checking if `OPENSTACK_NAMESPACE` is set:

```bash
if [ -n "${OPENSTACK_NAMESPACE}" ]; then
    echo "Multi-RHOSO mode: Creating namespace-scoped pools for '${OPENSTACK_NAMESPACE}'"
    USE_NAMESPACE_SCOPING=true
    NAMESPACE="${OPENSTACK_NAMESPACE}"
    POOL_PREFIX=""  # No prefix - use standard pool names
    L2ADV_SUFFIX="-${OPENSTACK_NAMESPACE}"  # L2Advertisements need unique names
else
    echo "Single RHOSO mode: No namespace scoping"
    USE_NAMESPACE_SCOPING=false
    POOL_PREFIX=""
    L2ADV_SUFFIX=""
fi
```

**Key points:**
- **Pool names**: Always standard (`internalapi`, `storage`, etc.) - no prefix
- **L2Advertisement names**: Get namespace suffix (`internalapi-openstack`, `internalapi-openstack2`)
- **Namespace scoping**: Added via `serviceAllocation.namespaces` field

When `USE_NAMESPACE_SCOPING=true`, the script adds:

```yaml
  serviceAllocation:
    namespaces:
    - ${NAMESPACE}
```

to each IPAddressPool.

## Benefits

✅ **No OpenStack operator changes needed** - Services use standard pool names
✅ **Automatic isolation** - MetalLB handles namespace filtering
✅ **Clear separation** - Different IP ranges prevent conflicts
✅ **Scalable** - Add more RHOSO instances easily
✅ **Clean naming** - Pool names stay consistent (`internalapi`, not `rhoso1-internalapi`)

## Verification

### Check All IPAddressPools

```bash
oc get ipaddresspool -n metallb-system
```

Expected output for 2 RHOSO instances:
```
NAME          AUTO ASSIGN   AVOID BUGGY IPS   ADDRESSES
ctlplane      true          false             ["192.168.122.80-192.168.122.90"]
ctlplane      true          false             ["192.168.122.100-192.168.122.110"]
internalapi   true          false             ["172.17.0.80-172.17.0.90"]
internalapi   true          false             ["172.27.0.80-172.27.0.90"]
storage       true          false             ["172.18.0.80-172.18.0.90"]
storage       true          false             ["172.29.0.80-172.29.0.90"]
...
```

**Note**: You'll see duplicate names - this is expected! They're differentiated by namespace scoping.

### Check Namespace Scoping

```bash
oc get ipaddresspool -n metallb-system -o yaml | grep -A 3 "serviceAllocation"
```

Expected:
```yaml
  serviceAllocation:
    namespaces:
    - openstack
--
  serviceAllocation:
    namespaces:
    - openstack2
```

### Check L2Advertisements

```bash
oc get l2advertisements.metallb.io -n metallb-system
```

Expected:
```
NAME                        IPADDRESSPOOLS    IPADDRESSPOOL SELECTORS   INTERFACES
ctlplane-openstack          ["ctlplane"]                                 ["ospbr"]
ctlplane-openstack2         ["ctlplane"]                                 ["ospbr"]
internalapi-openstack       ["internalapi"]                              ["enp6s0.20"]
internalapi-openstack2      ["internalapi"]                              ["enp6s0.20"]
...
```

### Verify Service IP Allocation

```bash
# Instance 1 services should get IPs from 172.17.0.x range
oc get svc -n openstack | grep LoadBalancer

# Instance 2 services should get IPs from 172.27.0.x range
oc get svc -n openstack2 | grep LoadBalancer
```

## Troubleshooting

### Issue: Service stuck in Pending

**Check**:
```bash
oc describe svc <service-name> -n <namespace>
```

Look for events like:
```
Failed to allocate IP for "default/myservice": no available IPs in pool "internalapi"
```

**Solution**: Verify the IPAddressPool exists and is scoped to the correct namespace:
```bash
oc get ipaddresspool internalapi -n metallb-system -o yaml
```

### Issue: Wrong IP range assigned

**Symptom**: Service in `openstack` namespace gets IP from `openstack2` range

**Cause**: Missing or incorrect `serviceAllocation.namespaces`

**Fix**: Re-run `make metallb_config` with correct `NAMESPACE` set

### Issue: Duplicate pool names

This is **expected behavior**! Multiple pools with the same name but different namespace scoping is how multi-RHOSO works.

## References

- [MetalLB IPAddressPool Documentation](https://metallb.universe.tf/apis/#metallb.io/v1beta1.IPAddressPool)
- [MetalLB Namespace Scoping](https://metallb.universe.tf/configuration/#controlling-automatic-address-allocation)
