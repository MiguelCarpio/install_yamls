# NNCP Overwrite Fix - Multi-RHOSO Deployment

## Problem Discovered (2025-11-20)

When deploying multiple RHOSO instances following the documented workflow, **instance 1's network configuration was deleted** when deploying instance 2.

### Symptoms

After running the deployment sequence for both openstack and openstack2:

```bash
# Deployment sequence
make nmstate metallb openstack openstack_init

source config/multi-rhoso/rhoso1-config.env
make nncp namespace netattach metallb_config openstack_deploy edpm_deploy

source config/multi-rhoso/rhoso2-config.env
make nncp namespace netattach metallb_config openstack_deploy edpm_deploy
```

**Observed issues:**

1. Only openstack2 IPs present on CRC node:
   ```
   enp6s0.20: 172.27.0.5/24  (openstack2 InternalAPI)
   enp6s0.21: 172.29.0.5/24  (openstack2 Storage)
   enp6s0.22: 172.31.0.5/24  (openstack2 Tenant)
   enp6s0.23: 172.32.0.5/24  (openstack2 StorageMgmt)
   ```

2. Missing openstack1 primary IPs:
   ```
   enp6s0.20: 172.17.0.5/24  ❌ MISSING
   enp6s0.21: 172.18.0.5/24  ❌ MISSING
   enp6s0.22: 172.19.0.5/24  ❌ MISSING
   enp6s0.23: 172.20.0.5/24  ❌ MISSING
   ```

3. RabbitMQ connection timeouts on edpm-compute-0:
   ```
   nova_compute[205886]: Connection failed: timed out (retrying in 31.0 seconds): socket.timeout: timed out
   ```

## Root Cause

### The NNCP Generation Process

The `make nncp` target in the Makefile calls `scripts/gen-nncp.sh`, which:

1. **Line 81**: `rm --force ${DEPLOY_DIR}/*_nncp.yaml` - **DELETES existing NNCP files**
2. **Lines 160-468**: Generates NEW NNCP with **only the current environment's IPs**
3. **Makefile line 2438**: `oc apply -f ${DEPLOY_DIR}/` - **REPLACES existing NNCP**

### What Was Happening

**Step 1: Deploy openstack (instance 1)**
```bash
source config/multi-rhoso/rhoso1-config.env
make nncp
```
- Generates NNCP with IPs: 172.17.0.5, 172.18.0.5, 172.19.0.5, 172.20.0.5
- Applies NNCP ✅

**Step 2: Deploy openstack2 (instance 2)**
```bash
source config/multi-rhoso/rhoso2-config.env
make nncp
```
- **DELETES** NNCP YAML files from step 1 ❌
- **REGENERATES** NNCP with ONLY openstack2 IPs: 172.27.0.5, 172.29.0.5, 172.31.0.5, 172.32.0.5 ❌
- **REPLACES** existing NNCP, removing openstack1's IPs ❌
- Runs add-nncp-secondary-ips.sh to add secondary IPs (but primary IPs already lost) ❌

### Why This Breaks openstack1

- MetalLB speaker on CRC node can no longer advertise openstack1 service IPs (172.17.0.x range)
- edpm-compute-0 cannot reach RabbitMQ at 172.17.0.80
- Nova compute loses connectivity to control plane
- Instance 1 becomes non-functional

## The Fix

### Modified Makefile Target

**File**: [Makefile](Makefile) lines 2432-2452

Changed the `nncp` target to conditionally skip NNCP generation for multi-RHOSO instances:

```makefile
nncp:
	$(eval $(call vars,$@,nncp))
	@if test -n "${RHOSO_INSTANCE_NAME}" && test "${RHOSO_INSTANCE_NAME}" != "rhoso1" && test "${RHOSO_INSTANCE_NAME}" != "openstack"; then \
		echo "Multi-RHOSO Instance Detected: ${RHOSO_INSTANCE_NAME}"; \
		echo "Skipping NNCP generation (already exists from first instance)"; \
		echo "Adding secondary IPs to CRC node..."; \
		bash scripts/add-nncp-secondary-ips.sh; \
	else \
		echo "First RHOSO instance - generating and applying NNCP configuration"; \
		# ... original NNCP generation logic ...
		oc apply -f ${DEPLOY_DIR}/; \
		# ... wait for NNCP to be configured ...
	fi
```

### How the Fix Works

**For first instance (openstack/rhoso1):**
- `RHOSO_INSTANCE_NAME` is NOT set, or equals "rhoso1" or "openstack"
- Generates NNCP with primary IPs
- Applies NNCP to cluster
- Waits for configuration

**For additional instances (openstack2, openstack3, etc.):**
- `RHOSO_INSTANCE_NAME` is set to something other than "rhoso1" or "openstack"
- **SKIPS** NNCP generation entirely
- **ONLY** runs `scripts/add-nncp-secondary-ips.sh`
- Patches existing NNCP to add secondary IPs
- **Preserves** primary IPs from instance 1

## Immediate Recovery

After identifying the problem, the following script was used to restore openstack1's primary IPs:

```bash
#!/bin/bash
# Restore openstack1 primary IPs

kubectl patch nncp enp6s0-crc --type=json -p='[
  {"op": "add", "path": "/spec/desiredState/interfaces/0/ipv4/address/0",
   "value": {"ip": "172.17.0.5", "prefix-length": 24}},
  {"op": "add", "path": "/spec/desiredState/interfaces/1/ipv4/address/0",
   "value": {"ip": "172.18.0.5", "prefix-length": 24}},
  {"op": "add", "path": "/spec/desiredState/interfaces/2/ipv4/address/0",
   "value": {"ip": "172.19.0.5", "prefix-length": 24}},
  {"op": "add", "path": "/spec/desiredState/interfaces/3/ipv4/address/0",
   "value": {"ip": "172.20.0.5", "prefix-length": 24}}
]'
```

**Result:**
```
enp6s0.20: 172.17.0.5/24 + 172.27.0.5/24 ✅
enp6s0.21: 172.18.0.5/24 + 172.29.0.5/24 ✅
enp6s0.22: 172.19.0.5/24 + 172.31.0.5/24 ✅
enp6s0.23: 172.20.0.5/24 + 172.32.0.5/24 ✅
```

## Correct Deployment Workflow (After Fix)

```bash
# Shared infrastructure (once)
make nmstate metallb openstack openstack_init

# Instance 1 (generates NNCP)
source config/multi-rhoso/rhoso1-config.env
make nncp                # ✅ Generates and applies NNCP with primary IPs
make namespace netattach metallb_config openstack_deploy edpm_deploy

# Instance 2 (patches existing NNCP)
source config/multi-rhoso/rhoso2-config.env
make nncp                # ✅ SKIPS generation, ONLY adds secondary IPs
make namespace netattach metallb_config openstack_deploy edpm_deploy
```

## Prevention Measures

1. **Makefile Logic**: Automatically detects multi-RHOSO via `RHOSO_INSTANCE_NAME` variable
2. **Documentation Updates**:
   - [MULTI_RHOSO_DEPLOYMENT_GUIDE.md](MULTI_RHOSO_DEPLOYMENT_GUIDE.md) - Updated Step 2 with critical warning
   - [MULTI_RHOSO_IMPLEMENTATION_SUMMARY.md](MULTI_RHOSO_IMPLEMENTATION_SUMMARY.md) - Updated deployment workflow
   - [MAKEFILE_INTEGRATION.md](MAKEFILE_INTEGRATION.md) - Added detailed explanation of the fix
3. **Idempotent Scripts**: `add-nncp-secondary-ips.sh` checks if IPs already exist before adding

## Key Lessons

1. **NNCP is a shared resource**: There's only ONE NNCP per node, shared by all RHOSO instances
2. **Regeneration destroys state**: Running `gen-nncp.sh` deletes and recreates the NNCP
3. **Patch, don't replace**: For multi-tenant scenarios, use `kubectl patch` to add IPs, not regenerate
4. **Test thoroughly**: Multi-instance deployments need end-to-end testing to catch cross-instance issues

## Testing Verification

After applying the fix, verify both instances have connectivity:

```bash
# Check all IPs are present on CRC node
oc debug node/crc -- chroot /host ip addr show | grep -E '172\.(17|18|19|20|27|29|31|32)\.0\.5'

# Should show 8 IPs total (4 from openstack1, 4 from openstack2)

# Test openstack1 RabbitMQ connectivity
ssh cloud-admin@192.168.122.100 "nc -zv 172.17.0.80 5671"

# Test openstack2 RabbitMQ connectivity
ssh cloud-admin@192.168.122.101 "nc -zv 172.27.0.80 5671"

# Check both instances' Nova compute services
kubectl exec -n openstack openstackclient -- openstack compute service list
kubectl exec -n openstack2 openstackclient -- openstack compute service list
```

## Related Files

- [Makefile](Makefile) - Lines 2432-2452 (nncp target fix)
- [scripts/add-nncp-secondary-ips.sh](scripts/add-nncp-secondary-ips.sh) - Patches NNCP to add secondary IPs
- [scripts/gen-nncp.sh](scripts/gen-nncp.sh) - Generates NNCP (only for first instance now)
- [MULTI_RHOSO_DEPLOYMENT_GUIDE.md](MULTI_RHOSO_DEPLOYMENT_GUIDE.md) - User-facing deployment guide
- [MULTI_RHOSO_IMPLEMENTATION_SUMMARY.md](MULTI_RHOSO_IMPLEMENTATION_SUMMARY.md) - Technical implementation details
- [MAKEFILE_INTEGRATION.md](MAKEFILE_INTEGRATION.md) - Makefile integration documentation

## Status

**Issue**: RESOLVED ✅
**Date Fixed**: 2025-11-20
**Impact**: Critical - prevented multi-RHOSO deployments from working
**Solution**: Conditional NNCP generation in Makefile + comprehensive documentation updates
