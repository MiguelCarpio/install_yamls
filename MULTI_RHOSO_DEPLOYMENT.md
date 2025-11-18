# Multi-RHOSO Deployment Guide

This guide explains how to deploy multiple Red Hat OpenStack Services on OpenShift (RHOSO) instances on the same OpenShift cluster using **Approach 1: Shared VLANs with Different IP Subnets**.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                      OpenShift Cluster                          │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌─────────────────────┐      ┌─────────────────────┐         │
│  │  RHOSO Instance 1   │      │  RHOSO Instance 2   │         │
│  │  (openstack ns)     │      │  (openstack2 ns)    │         │
│  ├─────────────────────┤      ├─────────────────────┤         │
│  │ Subnet: 172.17.0/24 │      │ Subnet: 172.27.0/24 │         │
│  │ MetalLB: .80-.90    │      │ MetalLB: .100-.110  │         │
│  └─────────┬───────────┘      └─────────┬───────────┘         │
│            │                            │                       │
│            └────────────┬───────────────┘                       │
│                         │                                       │
├─────────────────────────┼───────────────────────────────────────┤
│    Shared Network Infrastructure (VLANs on enp6s0)             │
│  ┌──────────────────────┴───────────────────────┐              │
│  │ VLAN 20 (InternalAPI) │ VLAN 21 (Storage)    │              │
│  │ VLAN 22 (Tenant)      │ VLAN 23 (StorageMgmt)│              │
│  └──────────────────────────────────────────────┘              │
└─────────────────────────────────────────────────────────────────┘
```

## Key Concepts

### What is Shared
✅ **Physical Network Infrastructure**
- NMState Operator (cluster-wide)
- MetalLB Operator (cluster-wide)
- Physical interface (`enp6s0`)
- Bridge (`ospbr`)
- VLANs (20-26) on worker nodes

### What is Unique Per Instance
❌ **Logical Separation**
- OpenStack namespace
- IP address subnets on each VLAN
- MetalLB IP pool ranges (different IPs, but same pool names)
- MetalLB pools are **namespace-scoped** using `serviceAllocation.namespaces`
- L2Advertisement names (include namespace suffix, e.g., `ctlplane-openstack`)
- OpenStack control plane and data plane resources

---

## Prerequisites

1. **OpenShift cluster** with worker nodes
2. **Worker nodes** with a dedicated network interface (e.g., `enp6s0`)
3. **Network connectivity** for VLANs 20-26 (or your chosen range)
4. **IP address planning** - ensure non-overlapping subnets
5. **oc CLI** installed and configured

---

## Configuration Files

Two example configuration files are provided:

- [config/multi-rhoso/rhoso1-config.env](config/multi-rhoso/rhoso1-config.env) - RHOSO Instance 1
- [config/multi-rhoso/rhoso2-config.env](config/multi-rhoso/rhoso2-config.env) - RHOSO Instance 2

### Network Allocation Summary

| Resource | RHOSO Instance 1 | RHOSO Instance 2 |
|----------|------------------|------------------|
| **Namespace** | `openstack` | `openstack2` |
| **Instance Name** | `rhoso1` | `rhoso2` |
| **MetalLB Pool** | 192.168.122.80-90 | 192.168.122.100-110 |
| **InternalAPI** | 172.17.0.0/24 | 172.27.0.0/24 |
| **Storage** | 172.18.0.0/24 | 172.29.0.0/24 |
| **Tenant** | 172.19.0.0/24 | 172.31.0.0/24 |
| **StorageMgmt** | 172.20.0.0/24 | 172.32.0.0/24 |
| **Designate** | 172.28.0.0/24 | 172.38.0.0/24 |
| **Designate Ext** | 172.50.0.0/24 | 172.51.0.0/24 |
| **Compute Node IP** | 192.168.122.100 | 192.168.122.150 |

---

## Deployment Steps

### Phase 1: Shared Infrastructure (Deploy Once for All RHOSO Instances)

These steps are performed **once** and shared by all RHOSO instances.

#### Step 1.1: Validate OpenShift Marketplace

```bash
make validate_marketplace
```

#### Step 1.2: Create Operator Namespace

```bash
make operator_namespace
```

**Result**: Creates `openstack-operators` namespace for operators.

#### Step 1.3: Install NMState Operator

```bash
make nmstate
```

**What it does**:
- Installs NMState operator in `openshift-nmstate` namespace
- Enables declarative node network configuration
- Required for NNCP resources

**Verification**:
```bash
oc get pods -n openshift-nmstate
# Expected: nmstate-handler pods running on each worker
#           nmstate-operator pod running
```

#### Step 1.4: Install MetalLB Operator

```bash
make metallb
```

**What it does**:
- Installs MetalLB operator in `metallb-system` namespace
- Deploys MetalLB speaker daemonset
- Provides LoadBalancer service support

**Verification**:
```bash
oc get pods -n metallb-system
# Expected: controller, speaker, webhook pods running
```

#### Step 1.5: Configure Worker Node Networking (NNCP)

**⚠️ Important**: This step only needs to be run **ONCE** because VLANs are shared.

```bash
# Load RHOSO1 config (we use it for VLAN configuration)
source config/multi-rhoso/rhoso1-config.env

# Create NNCP resources
make nncp
```

**What it does**:
- Creates VLANs on worker nodes:
  - `enp6s0.20` (InternalAPI)
  - `enp6s0.21` (Storage)
  - `enp6s0.22` (Tenant)
  - `enp6s0.23` (StorageMgmt)
  - `enp6s0.24` (Octavia)
  - `enp6s0.25` (Designate)
  - `enp6s0.26` (Designate External)
- Creates bridge `ospbr` on workers
- Assigns IP addresses to worker nodes (from RHOSO1 config)

**Verification**:
```bash
oc get nncp
# Expected: One NNCP per worker node

oc get nncp <worker-name>-nncp -o yaml
# Check status.conditions for SuccessfullyConfigured
```

---

### Phase 2: Deploy RHOSO Instance 1

#### Step 2.1: Load RHOSO Instance 1 Configuration

```bash
source config/multi-rhoso/rhoso1-config.env
```

**Verify configuration**:
```bash
echo "Instance: $RHOSO_INSTANCE_NAME"
echo "Namespace: $NAMESPACE"
echo "MetalLB Pool: $METALLB_POOL"
```

#### Step 2.2: Create Namespace for RHOSO Instance 1

```bash
make namespace
```

**Result**: Creates `openstack` namespace.

#### Step 2.3: Create Network Attachments for Instance 1

```bash
make netattach
```

**What it does**:
- Creates NetworkAttachmentDefinitions in `openstack` namespace:
  - `ctlplane` - Control plane network (macvlan on `ospbr`)
  - `internalapi` - Internal API (macvlan on `enp6s0.20`)
  - `storage` - Storage traffic (macvlan on `enp6s0.21`)
  - `tenant` - Tenant networks (macvlan on `enp6s0.22`)
  - `storagemgmt` - Storage management (macvlan on `enp6s0.23`)
  - `octavia` - Octavia LB (bridge on `octbr`)
  - `designate` - DNS (macvlan on `enp6s0.25`)
  - `designateext` - External DNS (macvlan on `enp6s0.26`)
  - `datacentre` - Provider network (bridge on `ospbr`)

**Verification**:
```bash
oc get network-attachment-definitions -n openstack
```

#### Step 2.4: Configure MetalLB for Instance 1

```bash
make metallb_config
```

**What it does**:
- Creates IPAddressPools with standard names BUT scoped to `openstack` namespace:
  - `ctlplane`: 192.168.122.80-90 (scoped to `openstack` namespace)
  - `internalapi`: 172.17.0.80-90 (scoped to `openstack` namespace)
  - `storage`: 172.18.0.80-90 (scoped to `openstack` namespace)
  - `tenant`: 172.19.0.80-90 (scoped to `openstack` namespace)
  - `designateext`: 172.50.0.80-90 (scoped to `openstack` namespace)
- Creates L2Advertisements with namespace suffix: `ctlplane-openstack`, `internalapi-openstack`, etc.
- Uses `serviceAllocation.namespaces` to restrict pools to specific OpenStack namespace

**Example IPAddressPool**:
```yaml
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
    - openstack  # Only services in 'openstack' namespace can use this pool
```

**Verification**:
```bash
oc get ipaddresspool -n metallb-system
# Expected: ctlplane, internalapi, storage, tenant, designateext

oc describe ipaddresspool internalapi -n metallb-system
# Check for: serviceAllocation.namespaces: [openstack]

# Check L2Advertisements
oc get l2advertisements.metallb.io -n metallb-system
# Expected: ctlplane-openstack, internalapi-openstack, etc.
```

#### Step 2.5: Install OpenStack Operators

```bash
make openstack
```

**What it does**:
- Installs OpenStack operator bundle via OLM
- Deploys operators in `openstack-operators` namespace
- Operators include: infra, OVN, neutron, nova, etc.

**Verification**:
```bash
oc get csv -n openstack-operators
# Wait for STATUS=Succeeded
```

#### Step 2.6: Initialize OpenStack Operator

```bash
make openstack_init
```

**What it does**:
- Creates `OpenStack` CR
- Initializes webhook services
- Prepares for control plane deployment

**Verification**:
```bash
oc get openstack -n openstack-operators
# Check for Ready condition

oc get svc -n openstack-operators | grep webhook
```

#### Step 2.7: Deploy OpenStack Control Plane

```bash
make openstack_deploy
```

**What it does**:
- Deploys `OpenStackControlPlane` CR in `openstack` namespace
- Creates:
  - **NetConfig**: Network definitions
  - **MariaDB/Galera**: Database cluster
  - **RabbitMQ**: Message queue
  - **Memcached**: Caching service
  - **Keystone**: Identity service
  - **Placement**: Placement API
  - **Glance**: Image service
  - **OVNDBCluster**: OVN Northbound/Southbound databases
  - **OVNNorthd**: OVN flow translator
  - **NeutronAPI**: Networking API
  - **NovaAPI**: Compute API
  - **Cinder**: Block storage (if enabled)
  - **Swift**: Object storage (if enabled)

**This will take 15-30 minutes.**

**Monitor deployment**:
```bash
# Watch control plane status
oc get openstackcontrolplane -n openstack -w

# Check pod status
oc get pods -n openstack

# Check for LoadBalancer IPs
oc get svc -n openstack | grep LoadBalancer
```

**Verification**:
```bash
oc wait openstackcontrolplane/openstack-ctrl \
  --for condition=Ready \
  --timeout=30m \
  -n openstack
```

#### Step 2.8: Deploy Data Plane (Compute Nodes)

```bash
make edpm_deploy
```

**What it does**:
- Creates `OpenStackDataPlaneNodeSet` CR
- Configures compute node at `192.168.122.100`
- Deploys:
  - **OVNController**: OVN agent on compute
  - **Nova Compute**: Hypervisor service
  - **Libvirt**: Virtualization
  - **Neutron agents**: If needed

**Monitor deployment**:
```bash
oc get openstackdataplanenodeset -n openstack -w

# Check deployment jobs
oc get jobs -n openstack
```

**Wait for completion**:
```bash
make edpm_wait_deploy
```

#### Step 2.9: Verify RHOSO Instance 1

```bash
# Get Keystone endpoint
KEYSTONE_IP=$(oc get svc keystone-public -n openstack \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "Keystone URL: http://${KEYSTONE_IP}:5000"

# Test authentication
openstack --os-auth-url http://${KEYSTONE_IP}:5000/v3 \
  --os-username admin \
  --os-password 12345678 \
  --os-project-name admin \
  --os-user-domain-name Default \
  --os-project-domain-name Default \
  token issue
```

---

### Phase 3: Deploy RHOSO Instance 2

Now deploy the second RHOSO instance using the same infrastructure but different namespaces and IP ranges.

#### Step 3.1: Load RHOSO Instance 2 Configuration

```bash
source config/multi-rhoso/rhoso2-config.env
```

**Verify configuration**:
```bash
echo "Instance: $RHOSO_INSTANCE_NAME"
echo "Namespace: $NAMESPACE"
echo "MetalLB Pool: $METALLB_POOL"
```

#### Step 3.2: Create Namespace for RHOSO Instance 2

```bash
make namespace
```

**Result**: Creates `openstack2` namespace.

#### Step 3.3: Create Network Attachments for Instance 2

```bash
make netattach
```

**What it does**:
- Creates NetworkAttachmentDefinitions in `openstack2` namespace
- Uses same VLANs as Instance 1 but in different namespace
- IPAM will allocate IPs from different subnets (172.27.0.x, etc.)

**Verification**:
```bash
oc get network-attachment-definitions -n openstack2
```

#### Step 3.4: Configure MetalLB for Instance 2

```bash
make metallb_config
```

**What it does**:
- Creates IPAddressPools with same names as Instance 1 BUT scoped to `openstack2` namespace:
  - `ctlplane`: 192.168.122.100-110 (scoped to `openstack2` namespace)
  - `internalapi`: 172.27.0.80-90 (scoped to `openstack2` namespace)
  - `storage`: 172.29.0.80-90 (scoped to `openstack2` namespace)
  - `tenant`: 172.31.0.80-90 (scoped to `openstack2` namespace)
  - `designateext`: 172.51.0.80-90 (scoped to `openstack2` namespace)
- Creates L2Advertisements with namespace suffix: `ctlplane-openstack2`, `internalapi-openstack2`, etc.

**How Multi-RHOSO Works**:
- Pool names are the same (`internalapi`, `storage`, etc.) for both instances
- Each pool is restricted to its namespace via `serviceAllocation.namespaces`
- Services in `openstack` namespace can only use pools scoped to `openstack`
- Services in `openstack2` namespace can only use pools scoped to `openstack2`
- Different IP ranges prevent conflicts

**Verification**:
```bash
# You'll see TWO sets of pools with the same names
oc get ipaddresspool -n metallb-system

# Check that they're scoped to different namespaces
oc describe ipaddresspool internalapi -n metallb-system | grep -A 2 serviceAllocation

# Check L2Advertisements
oc get l2advertisements.metallb.io -n metallb-system
# Expected: ctlplane-openstack, ctlplane-openstack2, internalapi-openstack, internalapi-openstack2, etc.
```

#### Step 3.5: OpenStack Operators (Shared)

**⚠️ Skip this step!** The OpenStack operators are already installed and shared across all RHOSO instances.

Verify operators are ready:
```bash
oc get csv -n openstack-operators
```

#### Step 3.6: Deploy OpenStack Control Plane for Instance 2

```bash
make openstack_deploy
```

**What it does**:
- Deploys `OpenStackControlPlane` CR in `openstack2` namespace
- Creates all control plane services (similar to Instance 1)
- Uses different IP subnets and MetalLB pools

**Monitor deployment**:
```bash
oc get openstackcontrolplane -n openstack2 -w
oc get pods -n openstack2
```

**Verification**:
```bash
oc wait openstackcontrolplane/openstack-ctrl \
  --for condition=Ready \
  --timeout=30m \
  -n openstack2
```

#### Step 3.7: Deploy Data Plane for Instance 2

```bash
make edpm_deploy
```

**Monitor and wait**:
```bash
make edpm_wait_deploy
```

#### Step 3.8: Verify RHOSO Instance 2

```bash
# Get Keystone endpoint
KEYSTONE_IP=$(oc get svc keystone-public -n openstack2 \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "Keystone URL: http://${KEYSTONE_IP}:5000"

# Test authentication
openstack --os-auth-url http://${KEYSTONE_IP}:5000/v3 \
  --os-username admin \
  --os-password 12345678 \
  --os-project-name admin \
  --os-user-domain-name Default \
  --os-project-domain-name Default \
  token issue
```

---

## Verification and Testing

### Verify Both Instances are Running

```bash
# Check control planes
oc get openstackcontrolplane -A

# Check data planes
oc get openstackdataplanenodeset -A

# Check MetalLB pools
oc get ipaddresspool -n metallb-system

# Check services with LoadBalancer IPs
oc get svc -A | grep LoadBalancer
```

### Verify Network Isolation

```bash
# Check that each instance uses different IP ranges
oc get svc -n openstack | grep LoadBalancer
oc get svc -n openstack2 | grep LoadBalancer

# IPs should come from different MetalLB pools
```

### Test OpenStack Functionality

For each instance, create a test VM:

```bash
# Instance 1
export OS_CLOUD=rhoso1  # Configure clouds.yaml
openstack server create --flavor m1.small --image cirros test-vm-rhoso1

# Instance 2
export OS_CLOUD=rhoso2  # Configure clouds.yaml
openstack server create --flavor m1.small --image cirros test-vm-rhoso2
```

---

## Troubleshooting

### MetalLB Pool Conflicts

**Symptom**: Services stuck in `Pending` state for LoadBalancer IP

**Check**:
```bash
oc get ipaddresspool -n metallb-system
oc describe svc <service-name> -n <namespace>
```

**Solution**: Ensure IP pools don't overlap and have unique names.

### NNCP Configuration Issues

**Symptom**: NNCP stuck in `Progressing` or `Failed`

**Check**:
```bash
oc get nncp
oc describe nncp <nncp-name>
```

**Solution**: Verify interface exists and VLANs are allowed on switches.

### Network Attachment Issues

**Symptom**: Pods fail to attach to networks

**Check**:
```bash
oc get network-attachment-definitions -n <namespace>
oc describe pod <pod-name> -n <namespace>
```

**Solution**: Ensure NADs exist in the correct namespace.

### IP Address Exhaustion

**Symptom**: Pods fail with "no IPs available"

**Check**:
```bash
oc get ippools -A
```

**Solution**: Increase IPAM range in NetworkAttachmentDefinitions or use larger subnets.

---

## Adding More RHOSO Instances

To add a third instance (rhoso3):

1. Create `config/multi-rhoso/rhoso3-config.env`
2. Choose unique:
   - `NAMESPACE=openstack3`
   - `RHOSO_INSTANCE_NAME=rhoso3`
   - IP subnets (e.g., 172.37.x, 172.39.x, etc.)
   - MetalLB pool (e.g., 192.168.122.120-130)
3. Follow Phase 3 deployment steps

---

## Cleanup

### Remove RHOSO Instance 2

```bash
source config/multi-rhoso/rhoso2-config.env
make edpm_deploy_cleanup
make openstack_deploy_cleanup
make netattach_cleanup
make metallb_config_cleanup
make namespace_cleanup
```

### Remove RHOSO Instance 1

```bash
source config/multi-rhoso/rhoso1-config.env
make edpm_deploy_cleanup
make openstack_deploy_cleanup
make netattach_cleanup
make metallb_config_cleanup
make namespace_cleanup
```

### Remove Shared Infrastructure

```bash
make openstack_cleanup
make nncp_cleanup
make metallb_cleanup
make nmstate_cleanup
```

---

## Summary

This multi-RHOSO deployment approach provides:

✅ **Shared infrastructure** (VLANs, operators)
✅ **Namespace isolation** per instance
✅ **Network isolation** via different IP subnets
✅ **Independent lifecycle** management
✅ **Resource efficiency** (shared operators and network infrastructure)

Each RHOSO instance operates independently with its own:
- OpenStack control plane
- Data plane (compute nodes)
- IP address ranges
- MetalLB LoadBalancer IPs
- Network configurations

While sharing:
- Physical network interfaces
- VLANs
- NMState and MetalLB operators
- OpenStack operators
