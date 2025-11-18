#!/bin/bash
#
# Add secondary IP addresses to CRC node VLAN interfaces
# This is required when deploying multiple RHOSO instances that share the same VLANs
# but use different IP subnets (e.g., openstack uses 172.17.0.x, openstack2 uses 172.27.0.x)
#
# Usage: bash scripts/add-nncp-secondary-ips.sh
#
# This script reads environment variables to determine which secondary IPs to add:
# - NETWORK_INTERNALAPI_ADDRESS_PREFIX
# - NETWORK_STORAGE_ADDRESS_PREFIX
# - NETWORK_TENANT_ADDRESS_PREFIX
# - NETWORK_STORAGEMGMT_ADDRESS_PREFIX
#

set -e

if [ -z "${NAMESPACE}" ]; then
    echo "ERROR: NAMESPACE must be set"
    echo "Please source your instance config file first (e.g., source config/multi-rhoso/rhoso2-config.env)"
    exit 1
fi

if [ -z "${NETWORK_INTERNALAPI_ADDRESS_PREFIX}" ]; then
    echo "ERROR: NETWORK_INTERNALAPI_ADDRESS_PREFIX must be set"
    exit 1
fi

# Default NNCP name (can be overridden)
NNCP_NAME=${NNCP_NAME:-enp6s0-crc}

echo "=========================================="
echo "Adding Secondary IPs to NNCP"
echo "=========================================="
echo "Namespace: ${NAMESPACE}"
echo "NNCP: ${NNCP_NAME}"
echo "InternalAPI: ${NETWORK_INTERNALAPI_ADDRESS_PREFIX}.5/24"
echo "Storage: ${NETWORK_STORAGE_ADDRESS_PREFIX}.5/24"
echo "Tenant: ${NETWORK_TENANT_ADDRESS_PREFIX}.5/24"
echo "StorageMgmt: ${NETWORK_STORAGEMGMT_ADDRESS_PREFIX}.5/24"
echo "=========================================="
echo ""

# Check if NNCP exists
if ! kubectl get nncp ${NNCP_NAME} &>/dev/null; then
    echo "ERROR: NNCP ${NNCP_NAME} not found"
    echo "Available NNCPs:"
    kubectl get nncp
    exit 1
fi

# Check if secondary IPs already exist
echo "Checking if secondary IPs already exist..."
CURRENT_IPS=$(kubectl get nncp ${NNCP_NAME} -o jsonpath='{.spec.desiredState.interfaces[0].ipv4.address[*].ip}')
if echo "$CURRENT_IPS" | grep -q "${NETWORK_INTERNALAPI_ADDRESS_PREFIX}.5"; then
    echo "⚠️  Secondary IP ${NETWORK_INTERNALAPI_ADDRESS_PREFIX}.5 already exists on enp6s0.20"
    echo "Skipping InternalAPI secondary IP addition"
    SKIP_INTERNALAPI=true
fi

# Patch NNCP to add secondary IPs
echo ""
echo "Adding secondary IPs to VLAN interfaces..."

PATCH_OPS="["

# InternalAPI (enp6s0.20 - interface index 0)
if [ -z "$SKIP_INTERNALAPI" ]; then
    PATCH_OPS+="
  {\"op\": \"add\", \"path\": \"/spec/desiredState/interfaces/0/ipv4/address/-\",
   \"value\": {\"ip\": \"${NETWORK_INTERNALAPI_ADDRESS_PREFIX}.5\", \"prefix-length\": 24}},"
fi

# Storage (enp6s0.21 - interface index 1)
PATCH_OPS+="
  {\"op\": \"add\", \"path\": \"/spec/desiredState/interfaces/1/ipv4/address/-\",
   \"value\": {\"ip\": \"${NETWORK_STORAGE_ADDRESS_PREFIX}.5\", \"prefix-length\": 24}},"

# Tenant (enp6s0.22 - interface index 2)
PATCH_OPS+="
  {\"op\": \"add\", \"path\": \"/spec/desiredState/interfaces/2/ipv4/address/-\",
   \"value\": {\"ip\": \"${NETWORK_TENANT_ADDRESS_PREFIX}.5\", \"prefix-length\": 24}},"

# StorageMgmt (enp6s0.23 - interface index 3)
PATCH_OPS+="
  {\"op\": \"add\", \"path\": \"/spec/desiredState/interfaces/3/ipv4/address/-\",
   \"value\": {\"ip\": \"${NETWORK_STORAGEMGMT_ADDRESS_PREFIX}.5\", \"prefix-length\": 24}}"

PATCH_OPS+="]"

echo "Applying NNCP patch..."
kubectl patch nncp ${NNCP_NAME} --type=json -p="$PATCH_OPS"

echo ""
echo "Waiting for NNCP to be configured (30 seconds)..."
sleep 30

# Verify configuration
NNCP_STATUS=$(kubectl get nncp ${NNCP_NAME} -o jsonpath='{.status.conditions[?(@.type=="Available")].status}')
if [ "$NNCP_STATUS" == "True" ]; then
    echo "✅ NNCP successfully configured"
else
    echo "⚠️  NNCP status: $(kubectl get nncp ${NNCP_NAME} -o jsonpath='{.status.conditions[?(@.type=="Available")].reason}')"
    echo "Run 'kubectl get nncp ${NNCP_NAME}' to check status"
fi

echo ""
echo "Verifying secondary IPs on CRC node..."
oc debug node/crc -- chroot /host ip addr show enp6s0.20 2>/dev/null | grep -E 'inet (172|fd)' || echo "Unable to verify (check manually with: oc debug node/crc -- chroot /host ip addr show enp6s0.20)"

echo ""
echo "=========================================="
echo "Secondary IP addition complete!"
echo "=========================================="
echo ""
echo "Note: These secondary IPs allow MetalLB to advertise service IPs"
echo "from the ${NAMESPACE} network ranges on the same VLAN interfaces."
