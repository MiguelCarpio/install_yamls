# EDPM Deployment Guide for Multi-RHOSO

This guide covers deploying External Data Plane Management (EDPM) compute nodes to RHOSO instances.

## Prerequisites

- OpenStack control plane deployed (`make openstack_deploy` completed)
- MetalLB services patched to LoadBalancer (automatically done by `openstack_deploy`)
- EDPM compute node accessible via SSH
- Compute node meets RHOSO requirements (CPU, memory, storage)

---

## EDPM Node Requirements

### Hardware
- CPU: 4+ cores (with hardware virtualization enabled)
- RAM: 8GB+
- Disk: 50GB+
- Network: Access to OpenShift network ranges

### Software
- RHEL 9.x installed
- SSH access configured
- SSH key added to cloud-admin user

### Network Configuration
The EDPM node needs connectivity to:
- **Control plane network** (192.168.122.x) - for DNS and general connectivity
- **InternalAPI network** (172.17.0.x for openstack, 172.27.0.x for openstack2) - for API services
- **Storage network** (172.18.0.x / 172.29.0.x) - for storage traffic
- **Tenant network** (172.19.0.x / 172.31.0.x) - for VM networking

---

## Deployment Steps

### Instance 1 (openstack namespace)

#### 1. Configure Environment
```bash
cd /home/mcarpio/CLAUDE/install_yamls
source config/multi-rhoso/rhoso1-config.env
```

This sets:
- `NAMESPACE=openstack`
- `DATAPLANE_COMPUTE_0_IP=192.168.122.100`
- `DATAPLANE_COMPUTE_0_NAME=edpm-compute-0`
- Network ranges for InternalAPI, Storage, Tenant networks

**IMPORTANT:** Before deploying EDPM, ensure you've completed the control plane deployment with these steps:
```bash
# With rhoso1-config.env sourced
make namespace          # Create namespace
make netattach          # Create network attachments
make metallb_config     # Create MetalLB IP pools (REQUIRED!)
make openstack_deploy   # Deploy control plane + auto-patch services
```

The `make metallb_config` step is **critical** - it creates the namespace-prefixed IP pools that LoadBalancer services need. If you skip this, services will be stuck in `<pending>` state.

#### 2. Verify Control Plane Services

Check that all services have LoadBalancer IPs:
```bash
oc get svc -n openstack | grep LoadBalancer
```

Expected services with LoadBalancer:
```
dnsmasq-dns                    LoadBalancer   192.168.122.80
keystone-internal              LoadBalancer   172.17.0.80
placement-internal             LoadBalancer   172.17.0.80
nova-internal                  LoadBalancer   172.17.0.80
glance-default-internal        LoadBalancer   172.17.0.80
neutron-internal               LoadBalancer   172.17.0.80
rabbitmq                       LoadBalancer   172.17.0.85
rabbitmq-cell1                 LoadBalancer   172.17.0.86
```

**Why LoadBalancer is required:**
- EDPM nodes are **external** to the Kubernetes cluster
- They cannot reach ClusterIP services (10.217.x.x)
- They need direct IP access via the InternalAPI network (172.17.0.x)
- DNS resolution via dnsmasq-dns converts `.svc` names to LoadBalancer IPs

**Note:** The patch script (`scripts/patch-openstack-metallb-pools.sh`) is automatically run by `make openstack_deploy` (line 852-853 in Makefile), so services should already be LoadBalancer type.

#### 3. Configure EDPM Node DNS

SSH to the compute node and update /etc/resolv.conf:
```bash
ssh cloud-admin@192.168.122.100

# Edit /etc/resolv.conf (as root)
sudo vi /etc/resolv.conf
```

Set the nameserver to the dnsmasq-dns LoadBalancer IP:
```
nameserver 192.168.122.80
search ctlplane.example.com internalapi.example.com storage.example.com tenant.example.com example.com
```

**Why this is needed:**
- EDPM services need to resolve Kubernetes service names like `keystone-internal.openstack.svc`
- DNSMasq (running in OpenShift) provides DNS forwarding from EDPM to Kubernetes services
- Without this, EDPM services get DNS resolution errors

#### 4. Deploy EDPM

```bash
# From install_yamls directory, with rhoso1-config.env sourced
make edpm_deploy
```

This creates:
- `OpenStackDataPlaneNodeSet` CR defining the compute node
- `OpenStackDataPlaneDeployment` CR triggering Ansible playbook execution

#### 5. Wait for Deployment

```bash
make edpm_wait_deploy
```

This waits for the deployment to complete (timeout: 30 minutes).

**What happens during deployment:**
1. Ansible playbooks run inside `openstackansibleee` pods
2. Services configured on EDPM node:
   - `validate-network` - Validates network connectivity
   - `repo-setup` - Configures package repositories
   - `configure-network` - Sets up VLANs and bridges
   - `run-os` - Installs base packages
   - `install-os` - Installs OpenStack packages
   - `configure-os` - Configures OpenStack services
   - `ovn` - Configures OVN controller
   - `nova` - Configures Nova compute
3. Services started:
   - `edpm_ovn_controller.service`
   - `edpm_nova_compute.service`
   - `edpm_ovn_metadata_agent.service`

#### 6. Monitor Deployment Progress

View Ansible logs:
```bash
# Find the OpenStackAnsibleEE execution pod
oc get pods -n openstack | grep openstack-edpm

# View logs
oc logs -f <ansible-pod-name> -n openstack
```

Or use the helper script:
```bash
NAMESPACE=openstack bash scripts/view-edpm-logs.sh configure-os
```

#### 7. Verify Deployment

Check compute service registration:
```bash
oc -n openstack rsh openstackclient openstack compute service list
```

Expected output:
```
+--------------------------------------+----------------+-------------------------------------+----------+---------+-------+----------------------------+
| ID                                   | Binary         | Host                                | Zone     | Status  | State | Updated At                 |
+--------------------------------------+----------------+-------------------------------------+----------+---------+-------+----------------------------+
| ...                                  | nova-compute   | edpm-compute-0.ctlplane.example.com | nova     | enabled | up    | 2025-11-18T22:44:30.000000 |
+--------------------------------------+----------------+-------------------------------------+----------+---------+-------+----------------------------+
```

Check services on EDPM node:
```bash
ssh cloud-admin@192.168.122.100

# Check Nova compute
sudo systemctl status edpm_nova_compute.service

# Check OVN controller
sudo systemctl status edpm_ovn_controller.service

# Check OVN metadata agent
sudo systemctl status edpm_ovn_metadata_agent.service
```

Check Nova compute logs:
```bash
ssh cloud-admin@192.168.122.100
sudo journalctl -u edpm_nova_compute.service -n 50
```

Look for successful registration messages:
```
Created resource provider record via placement API for resource provider with UUID ... and name edpm-compute-0.example.com
```

---

### Instance 2 (openstack2 namespace)

Repeat the same steps for the second RHOSO instance:

#### 1. Configure Environment
```bash
cd /home/mcarpio/CLAUDE/install_yamls
source config/multi-rhoso/rhoso2-config.env
```

This sets:
- `NAMESPACE=openstack2`
- `DATAPLANE_COMPUTE_0_IP=192.168.122.101`
- `DATAPLANE_COMPUTE_0_NAME=edpm-compute-1`
- Different network ranges (172.27.0.x, 172.29.0.x, 172.31.0.x)

#### 2. Verify Control Plane Services
```bash
oc get svc -n openstack2 | grep LoadBalancer
```

Expected: Services with LoadBalancer IPs in 172.27.0.x range (openstack2-internalapi pool)

#### 3. Configure EDPM Node DNS
```bash
ssh cloud-admin@192.168.122.101

# Update /etc/resolv.conf to use openstack2 DNS
sudo vi /etc/resolv.conf
```

Set nameserver to openstack2 dnsmasq-dns LoadBalancer IP:
```
nameserver 192.168.122.100  # (or whatever IP openstack2 dnsmasq gets)
search ctlplane.example.com internalapi.example.com storage.example.com tenant.example.com example.com
```

#### 4. Deploy EDPM
```bash
make edpm_deploy
make edpm_wait_deploy
```

#### 5. Verify Deployment
```bash
oc -n openstack2 rsh openstackclient openstack compute service list
ssh cloud-admin@192.168.122.101 "sudo systemctl status edpm_nova_compute"
```

---

## Troubleshooting

### Common Issues

#### 1. DNS Resolution Failures

**Symptoms:**
```
Failed to establish a new connection: [Errno -2] No address found
```

**Solution:**
- Verify /etc/resolv.conf on EDPM node points to dnsmasq-dns LoadBalancer IP
- Check dnsmasq-dns service has LoadBalancer IP: `oc get svc dnsmasq-dns -n <namespace>`
- Test DNS resolution: `dig +short keystone-internal.openstack.svc @<dnsmasq-ip>`

#### 2. Services Stuck in <pending> State

**Symptoms:**
LoadBalancer services show `<pending>` instead of an EXTERNAL-IP:
```
dnsmasq-dns      LoadBalancer   10.217.4.125   <pending>     53:32468/UDP
rabbitmq         LoadBalancer   10.217.4.51    <pending>     5671:31494/TCP
```

**Root Causes:**

**A) MetalLB pools not created:**
```bash
# Load the instance config
source config/multi-rhoso/rhoso2-config.env

# Create the MetalLB pools
make metallb_config

# Check if services get IPs (may take 1-2 minutes)
watch oc get svc -n openstack2 | grep LoadBalancer
```

**B) Services have wrong pool annotation or hardcoded IP from wrong subnet:**

Check service annotations:
```bash
oc get svc rabbitmq -n openstack2 -o jsonpath='{.metadata.annotations}' | jq .
```

If you see `"metallb.universe.tf/loadBalancerIPs"` with an IP from the wrong subnet (e.g., 172.17.0.x when it should be 172.27.0.x), the service was created before patching and has a stale IP.

**Solution:**
Delete the services so they get recreated with correct annotations:
```bash
# Delete problematic services
oc delete svc rabbitmq rabbitmq-cell1 dnsmasq-dns -n openstack2

# Wait for operators to recreate them (30-60 seconds)
sleep 45

# Verify they got correct IPs
oc get svc -n openstack2 | grep -E "(rabbitmq|dnsmasq)"
```

Expected results:
- dnsmasq-dns: IP from openstack2-ctlplane pool (192.168.122.100-110)
- rabbitmq: IP from openstack2-internalapi pool (172.27.0.80-90)
- rabbitmq-cell1: IP from openstack2-internalapi pool (172.27.0.80-90)

#### 3. Services Still ClusterIP

**Symptoms:**
Services don't have EXTERNAL-IP in LoadBalancer column (Type shows ClusterIP)

**Solution:**
```bash
# Manually run patch script
NAMESPACE=openstack bash scripts/patch-openstack-metallb-pools.sh

# Wait for services to be recreated (2-5 minutes)
watch oc get svc -n openstack | grep LoadBalancer
```

#### 4. Validate-Network Failure

**Symptoms:**
EDPM deployment times out at validate-network service

**Solution:**
- Check network connectivity from EDPM node to control plane
- Verify VLANs are configured: `ip addr show`
- Check if DNS is working: `dig +short keystone-internal.openstack.svc`

#### 5. Nova Compute Not Registering

**Symptoms:**
Nova compute service doesn't appear in `openstack compute service list`

**Solution:**
- Check nova_compute service logs: `journalctl -u edpm_nova_compute.service`
- Verify Keystone connectivity: Check for authentication errors
- Verify Placement connectivity: Check for placement API errors
- Ensure RabbitMQ services are LoadBalancer type and reachable

#### 6. RabbitMQ Authentication Failures After Service Deletion

**Symptoms:**
Control plane pods (nova-conductor, neutron-server, etc.) crash with RabbitMQ authentication errors:
```
amqp.exceptions.AccessRefused: (0, 0): (403) ACCESS_REFUSED - Login was refused using authentication mechanism AMQPLAIN
```

RabbitMQ logs show:
```
AMQPLAIN login refused: user 'default_user_YjQv7k7PD4Ic6odJ3TF' - invalid credentials
```

**Root Cause:**
When RabbitMQ services are deleted and recreated (e.g., during troubleshooting), RabbitMQ generates new credentials. OpenStack control plane pods still have the old credentials cached.

**Solution:**
Restart the affected control plane pods to pick up current RabbitMQ credentials:

```bash
# Restart Nova pods
oc delete pod -n openstack -l service=nova-conductor
oc delete pod -n openstack -l service=nova-scheduler
oc delete pod -n openstack -l service=nova-api

# Restart Neutron pods
oc delete pod -n openstack -l service=neutron

# Restart other affected services as needed
oc delete pod -n openstack -l service=placement
oc delete pod -n openstack -l service=cinder

# Wait for pods to restart (30-60 seconds)
watch oc get pods -n openstack
```

The operators will automatically recreate the pods with the current RabbitMQ credentials.

#### 7. OVN Controller Connection Failures

**Symptoms:**
```
stream_ssl|ERR|ssl:ovsdbserver-sb.openstack.svc:6642: connect: Address family not supported by protocol
```

**Status:**
This is a known issue under investigation. OVN controller connectivity may fail even though:
- DNS resolution works
- SSL handshake succeeds
- Network connectivity exists

The error appears to be related to IPv4/IPv6 socket binding. Nova compute can function without OVN controller for basic operations, but networking features may be limited.

---

## Architecture Notes

### Why LoadBalancer for Internal Services?

EDPM nodes are **external** to the Kubernetes cluster and need to access OpenStack API services:

1. **ClusterIP services** (10.217.x.x) are only reachable from within the cluster
2. **NodePort** would require EDPM to connect to OpenShift worker nodes
3. **LoadBalancer** provides direct IP access on the InternalAPI network

Services that EDPM needs:
- **DNS** (dnsmasq) - For resolving `.svc` names
- **Keystone** - For authentication
- **Placement** - For resource inventory reporting
- **Nova API** - For compute operations
- **Neutron** - For networking operations
- **Glance** - For image downloads
- **RabbitMQ** - For message bus communication

### MetalLB Pool Naming

The patch script ensures namespace-prefixed pool names:
- `openstack-internalapi` (172.17.0.80-90)
- `openstack2-internalapi` (172.27.0.80-90)

This prevents IP conflicts between multiple RHOSO instances and ensures predictable IP allocation.

---

## Files Reference

### Configuration Files
- [rhoso1-config.env](config/multi-rhoso/rhoso1-config.env) - Instance 1 config
- [rhoso2-config.env](config/multi-rhoso/rhoso2-config.env) - Instance 2 config

### Scripts
- [patch-openstack-metallb-pools.sh](scripts/patch-openstack-metallb-pools.sh) - Converts services to LoadBalancer
- [view-edpm-logs.sh](scripts/view-edpm-logs.sh) - Helper to view Ansible logs

### Makefile Targets
- `make edpm_deploy` - Deploy EDPM node (line 952)
- `make edpm_wait_deploy` - Wait for deployment completion
- `make openstack_deploy` - Includes automatic patching (line 852-853)

---

## Next Steps After EDPM Deployment

1. **Create OpenStack networks:**
   ```bash
   oc -n openstack rsh openstackclient
   openstack network create --external --provider-network-type flat --provider-physical-network datacentre public
   ```

2. **Create OpenStack flavors:**
   ```bash
   openstack flavor create --ram 2048 --disk 20 --vcpus 2 m1.small
   ```

3. **Upload images:**
   ```bash
   openstack image create --disk-format qcow2 --file cirros.qcow2 cirros
   ```

4. **Launch VMs:**
   ```bash
   openstack server create --flavor m1.small --image cirros --network public test-vm
   ```
