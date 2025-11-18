# Multi-RHOSO Changes Summary

## Changes Compared to Upstream install_yamls

### 1. Modified Files

#### `Makefile` (Line 848-853)
**Change**: Added automatic MetalLB pool annotation patching to `openstack_deploy` target

```makefile
openstack_deploy: input openstack_deploy_prep netconfig_deploy
	$(eval $(call vars,$@,openstack))
	make wait
	bash scripts/operator-deploy-resources.sh
	@echo "Patching MetalLB pool annotations for namespace ${NAMESPACE}..."
	NAMESPACE=${NAMESPACE} bash scripts/patch-openstack-metallb-pools.sh  # ← ADDED
```

**Why**: Automatically patches OpenStack service annotations to use namespace-prefixed MetalLB pools (`openstack-internalapi` instead of `internalapi`) for multi-RHOSO deployments.

---

#### `scripts/gen-metallb-config.sh` (Lines 64-79)
**Change**: Modified to create namespace-prefixed MetalLB pool names

```bash
# BEFORE (upstream):
POOL_PREFIX=""

# AFTER (our change):
if [ -n "${OPENSTACK_NAMESPACE}" ]; then
    echo "Multi-RHOSO mode: Creating prefixed pools for namespace '${OPENSTACK_NAMESPACE}'"
    USE_NAMESPACE_SCOPING=true
    NAMESPACE="${OPENSTACK_NAMESPACE}"
    POOL_PREFIX="${OPENSTACK_NAMESPACE}-"  # ← Creates openstack-internalapi
    L2ADV_SUFFIX="-${OPENSTACK_NAMESPACE}"
else
    echo "Single RHOSO mode: No namespace prefix"
    USE_NAMESPACE_SCOPING=false
    POOL_PREFIX=""
    L2ADV_SUFFIX=""
fi
```

**Why**:
- Creates unique pool names per RHOSO instance (`openstack-internalapi`, `openstack2-internalapi`)
- Prevents pool name conflicts when deploying multiple instances
- Enables proper IP range isolation per instance

---

#### `scripts/gen-metallb-config.sh` (Lines 218-274)
**Change**: L2Advertisement resources now reference prefixed pool names

```bash
# BEFORE:
name: internalapi
spec:
  ipAddressPools:
  - internalapi

# AFTER:
name: ${POOL_PREFIX}internalapi  # ← openstack-internalapi
spec:
  ipAddressPools:
  - ${POOL_PREFIX}internalapi
```

**Why**: L2Advertisements must reference the correct pool names (with prefixes) to announce IPs properly.

---

### 2. New Files Created

#### `scripts/patch-openstack-metallb-pools.sh`
**Purpose**: Patches OpenStackControlPlane CRs to use namespace-prefixed MetalLB pool annotations

**What it does**:
```bash
# Patches paths like:
/spec/keystone/template/override/service/internal
/spec/nova/template/apiServiceTemplate/override/service/internal
/spec/rabbitmq/templates/rabbitmq/override/service

# To add annotations:
metallb.universe.tf/address-pool: openstack-internalapi
metallb.universe.tf/allow-shared-ip: openstack-internalapi
```

**Why needed**:
- OpenStack operators create services with generic pool names (`internalapi`)
- We need them to use instance-specific names (`openstack-internalapi`)
- Patching the OpenStackControlPlane CR causes operators to recreate services with correct annotations

---

#### `config/multi-rhoso/rhoso1-config.env`
**Purpose**: Configuration for RHOSO instance 1

**Key variables**:
```bash
export RHOSO_INSTANCE_NAME=rhoso1
export NAMESPACE=openstack
export METALLB_POOL=192.168.122.80-192.168.122.90
export NETWORK_INTERNALAPI_ADDRESS_PREFIX=172.17.0
export NETWORK_STORAGE_ADDRESS_PREFIX=172.18.0
export NETWORK_TENANT_ADDRESS_PREFIX=172.19.0
# ... more network configs
```

---

#### `config/multi-rhoso/rhoso2-config.env`
**Purpose**: Configuration for RHOSO instance 2

**Key differences**:
```bash
export RHOSO_INSTANCE_NAME=rhoso2
export NAMESPACE=openstack2
export METALLB_POOL=192.168.122.100-192.168.122.110  # Different range
export NETWORK_INTERNALAPI_ADDRESS_PREFIX=172.27.0   # Different subnet
export NETWORK_STORAGE_ADDRESS_PREFIX=172.29.0       # Different subnet
export NETWORK_TENANT_ADDRESS_PREFIX=172.31.0        # Different subnet
```

---

#### `config/multi-rhoso/METALLB_MULTI_RHOSO.md`
Technical documentation explaining MetalLB namespace-scoping architecture.

#### `config/multi-rhoso/KUSTOMIZE_APPROACH.md`
Documentation on why kustomize/patch approach is needed.

#### `MULTI_RHOSO_DEPLOYMENT.md`
Complete deployment guide for multi-RHOSO.

---

## Deployment Steps Explained

### Phase 1: Shared Infrastructure (Run Once)

#### `make nmstate`
**What it does**:
- Installs **NMState Operator** in `openshift-nmstate` namespace
- Deploys nmstate-handler DaemonSet on all worker nodes
- Creates API for declarative network configuration

**Why needed**:
- Required to configure VLANs, bridges, and interfaces on worker nodes
- Provides the foundation for NodeNetworkConfigurationPolicy (NNCP) resources
- Manages network state across the cluster

**Components installed**:
```
openshift-nmstate/
├── nmstate-operator (deployment)
├── nmstate-handler (daemonset - runs on each worker)
└── nmstate-webhook (validates NNCP resources)
```

---

#### `make metallb`
**What it does**:
- Installs **MetalLB Operator** in `metallb-system` namespace
- Deploys MetalLB controller (manages IP allocation)
- Deploys MetalLB speaker DaemonSet (announces IPs via L2/BGP)
- Creates MetalLB CRDs (IPAddressPool, L2Advertisement, etc.)

**Why needed**:
- Provides LoadBalancer service support on bare metal
- Allocates external IPs to Kubernetes LoadBalancer services
- Announces IPs via ARP (L2 mode) or BGP

**Components installed**:
```
metallb-system/
├── metallb-operator-controller-manager (deployment)
├── speaker (daemonset - runs on each worker)
└── webhook-server (validates MetalLB resources)
```

---

#### `make nncp`
**What it does**:
- Creates **NodeNetworkConfigurationPolicy** resources
- Configures VLANs on worker nodes:
  - `enp6s0.20` (InternalAPI)
  - `enp6s0.21` (Storage)
  - `enp6s0.22` (Tenant)
  - `enp6s0.23` (StorageMgmt)
  - `enp6s0.25` (Designate)
  - `enp6s0.26` (Designate External)
- Creates bridge `ospbr` for control plane network
- Assigns IP addresses to worker interfaces

**Why needed**:
- OpenStack services need isolated network segments (VLANs)
- Each network serves different traffic (API, storage, tenant, etc.)
- Physical network separation for security and performance

**Example NNCP**:
```yaml
apiVersion: nmstate.io/v1
kind: NodeNetworkConfigurationPolicy
spec:
  desiredState:
    interfaces:
    - name: enp6s0.20        # VLAN 20 for InternalAPI
      type: vlan
      state: up
      vlan:
        base-iface: enp6s0
        id: 20
      ipv4:
        enabled: true
        address:
        - ip: 172.17.0.10      # Worker IP on this network
          prefix-length: 24
```

---

#### `make openstack`
**What it does**:
- Installs **OpenStack Operator bundle** via OLM (Operator Lifecycle Manager)
- Deploys multiple operators in `openstack-operators` namespace:
  - infra-operator (manages NetConfig, DNS, RabbitMQ, etc.)
  - keystone-operator
  - glance-operator
  - placement-operator
  - nova-operator
  - neutron-operator
  - ovn-operator
  - cinder-operator
  - swift-operator
  - And more...

**Why needed**:
- Operators manage OpenStack components as Kubernetes Custom Resources
- Operators handle lifecycle (creation, updates, scaling, deletion)
- Provides Kubernetes-native management of OpenStack

**CSV (ClusterServiceVersion) installed**:
```
openstack-operators/
├── openstack-operator.vX.Y.Z (CSV)
└── Subscriptions to all sub-operators
```

---

#### `make openstack_init`
**What it does**:
- Creates initial `OpenStackVersion` CR
- Initializes webhook services for validation
- Sets up operator configuration

**Why needed**:
- Prepares operators to accept OpenStackControlPlane CRs
- Validates CRs before they're created
- Initializes version tracking for updates

---

### Phase 2: Per-Instance Deployment

#### `source config/multi-rhoso/rhoso1-config.env`
**What it does**:
- Loads environment variables for instance 1:
  - `NAMESPACE=openstack`
  - `RHOSO_INSTANCE_NAME=rhoso1`
  - Network IP ranges (172.17.0.x, 172.18.0.x, etc.)
  - MetalLB pool ranges

**Why needed**:
- Configures instance-specific settings
- Ensures each instance uses unique namespaces and IP ranges
- Variables are used by subsequent `make` targets

---

#### `make namespace`
**What it does**:
- Creates Kubernetes namespace (e.g., `openstack`)
- Sets namespace labels and annotations
- Makes namespace the default context

**Why needed**:
- Provides isolation for RHOSO instance resources
- All instance resources (CRs, services, pods) go in this namespace
- Namespace scoping enables multi-tenancy

**Creates**:
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: openstack
  labels:
    pod-security.kubernetes.io/enforce: privileged
```

---

#### `make netattach`
**What it does**:
- Creates **NetworkAttachmentDefinition** (NAD) resources in the namespace
- Defines networks for Multus CNI:
  - `ctlplane` (macvlan on ospbr)
  - `internalapi` (macvlan on enp6s0.20)
  - `storage` (macvlan on enp6s0.21)
  - `tenant` (macvlan on enp6s0.22)
  - `storagemgmt` (macvlan on enp6s0.23)
  - `designate` (macvlan on enp6s0.25)
  - `designateext` (macvlan on enp6s0.26)
  - `datacentre` (bridge on ospbr)

**Why needed**:
- OpenStack pods need multiple network interfaces
- Each network serves different traffic types
- NADs tell Multus how to attach pods to VLANs

**Example NAD**:
```yaml
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: internalapi
  namespace: openstack
spec:
  config: |
    {
      "cniVersion": "0.3.1",
      "name": "internalapi",
      "type": "macvlan",
      "master": "enp6s0.20",
      "ipam": {
        "type": "whereabouts",
        "range": "172.17.0.0/24"
      }
    }
```

---

#### `make metallb_config`
**What it does** (with our changes):
- Runs `scripts/gen-metallb-config.sh`
- Creates **IPAddressPool** resources with namespace prefix:
  - `openstack-ctlplane` (192.168.122.80-90)
  - `openstack-internalapi` (172.17.0.80-90)
  - `openstack-storage` (172.18.0.80-90)
  - `openstack-tenant` (172.19.0.80-90)
  - `openstack-designateext` (172.50.0.80-90)
- Creates **L2Advertisement** resources
- Scopes pools to namespace via `serviceAllocation.namespaces`

**Why needed**:
- Provides IP pools for LoadBalancer services
- Namespace prefixes prevent conflicts between instances
- Each instance gets dedicated IP ranges

**Example IPAddressPool**:
```yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: openstack-internalapi  # ← Prefixed!
  namespace: metallb-system
spec:
  addresses:
  - 172.17.0.80-172.17.0.90
  serviceAllocation:
    namespaces:
    - openstack                # ← Scoped to this namespace
```

---

#### `make openstack_deploy`
**What it does**:
1. Creates `NetConfig` CR (network configuration)
2. Creates `OpenStackControlPlane` CR
3. **Automatically runs patch script** (our addition)
4. Waits for control plane to be ready

**What gets deployed**:
- **MariaDB/Galera**: Database cluster (3 replicas)
- **RabbitMQ**: Message queue (for oslo.messaging)
- **Memcached**: Caching service
- **Keystone**: Identity service
- **Placement**: Placement API
- **Glance**: Image service
- **OVN**: Open Virtual Network
  - OVNDBCluster (Northbound/Southbound databases)
  - OVNNorthd (flow translator)
- **Neutron API**: Networking API
- **Nova API**: Compute API
- **Swift**: Object storage (if enabled)
- **Cinder**: Block storage (if enabled)
- **Barbican**: Key management (if enabled)
- All services with LoadBalancer IPs

**The patch script**:
- Patches OpenStackControlPlane CR
- Adds MetalLB pool annotations to service overrides
- Ensures services use `openstack-internalapi` instead of `internalapi`
- Services get recreated with correct annotations
- IPs allocated from correct pools

**Why needed**:
- Deploys the complete OpenStack control plane
- Makes OpenStack APIs available
- Services get LoadBalancer IPs from MetalLB
- Patching ensures multi-RHOSO IP isolation

---

## Key Differences: Single vs Multi-RHOSO

### Single RHOSO (Upstream)
```bash
make nmstate metallb nncp
make openstack openstack_init
make namespace netattach metallb_config openstack_deploy
```

**MetalLB pools**:
- Pool names: `ctlplane`, `internalapi`, `storage`
- No namespace scoping
- All services use same pools

### Multi-RHOSO (Our Changes)
```bash
# Shared infrastructure (once)
make nmstate metallb nncp openstack openstack_init

# Instance 1
source config/multi-rhoso/rhoso1-config.env
make namespace netattach metallb_config openstack_deploy

# Instance 2
source config/multi-rhoso/rhoso2-config.env
make namespace netattach metallb_config openstack_deploy
```

**MetalLB pools**:
- Pool names: `openstack-internalapi`, `openstack2-internalapi`
- Namespace scoping via `serviceAllocation.namespaces`
- Each instance has dedicated IP ranges
- Patch script updates service annotations automatically

---

## Summary of Changes

| Component | Upstream | Our Changes | Why |
|-----------|----------|-------------|-----|
| **Makefile** | Standard deployment | Added auto-patching to `openstack_deploy` | Automates pool annotation updates |
| **gen-metallb-config.sh** | Generic pool names | Namespace-prefixed names | Prevents pool conflicts |
| **L2Advertisements** | Reference generic pools | Reference prefixed pools | Matches new pool names |
| **Service annotations** | Use `internalapi` | Use `openstack-internalapi` | Directs to correct pool |
| **Config files** | Single instance assumed | Multiple instance configs | Pre-configured IP ranges |
| **Documentation** | Single instance focus | Multi-instance guides | Deployment workflows |

---

## The Problem We Solved

**MetalLB Limitation**: When multiple namespaces share a pool with multiple IP ranges, MetalLB allocates IPs sequentially from the first range, regardless of which namespace requests it.

**Our Solution**:
1. Create separate pools with unique names per instance
2. Patch OpenStack CRs to use instance-specific pool names
3. Each instance gets IPs from its dedicated range

This ensures:
- ✅ Predictable IP allocation
- ✅ Clear IP range ownership per instance
- ✅ Easy troubleshooting (172.17.0.x = openstack, 172.27.0.x = openstack2)
- ✅ Scalable to N instances
