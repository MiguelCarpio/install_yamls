#!/bin/bash
#
# Copyright 2024 Red Hat Inc.
#
# Multi-RHOSO MetalLB configuration patcher
# This script patches existing IPAddressPools to add new IP ranges and namespaces
# instead of replacing them
#
set -e

if [ -z "${OPENSTACK_NAMESPACE}" ]; then
    echo "ERROR: OPENSTACK_NAMESPACE must be set for multi-RHOSO deployment"
    exit 1
fi

if [ -z "${CTLPLANE_METALLB_POOL}" ]; then
    echo "ERROR: CTLPLANE_METALLB_POOL must be set"
    exit 1
fi

if [ -z "${INTERNALAPI_PREFIX}" ]; then
    echo "ERROR: INTERNALAPI_PREFIX must be set"
    exit 1
fi

if [ -z "${STORAGE_PREFIX}" ]; then
    echo "ERROR: STORAGE_PREFIX must be set"
    exit 1
fi

if [ -z "${TENANT_PREFIX}" ]; then
    echo "ERROR: TENANT_PREFIX must be set"
    exit 1
fi

if [ -z "${DESIGNATE_EXT_PREFIX}" ]; then
    echo "ERROR: DESIGNATE_EXT_PREFIX must be set"
    exit 1
fi

if [ -z "${INTERFACE}" ]; then
    echo "ERROR: INTERFACE must be set"
    exit 1
fi

if [ -z "${BRIDGE_NAME}" ]; then
    echo "ERROR: BRIDGE_NAME must be set"
    exit 1
fi

NAMESPACE="${OPENSTACK_NAMESPACE}"
echo "=========================================="
echo "Multi-RHOSO MetalLB Configuration"
echo "=========================================="
echo "Namespace: ${NAMESPACE}"
echo "CtlPlane Pool: ${CTLPLANE_METALLB_POOL}"
echo "InternalAPI: ${INTERNALAPI_PREFIX}.80-.90"
echo "Storage: ${STORAGE_PREFIX}.80-.90"
echo "Tenant: ${TENANT_PREFIX}.80-.90"
echo "DesignateExt: ${DESIGNATE_EXT_PREFIX}.80-.90"
echo "=========================================="
echo ""

# Function to patch or create IPAddressPool
patch_or_create_pool() {
    local pool_name=$1
    local address_range=$2
    local auto_assign=${3:-true}

    if oc get ipaddresspool "${pool_name}" -n metallb-system &>/dev/null; then
        echo "Pool '${pool_name}' exists - patching..."

        # Get current addresses
        current_addresses=$(oc get ipaddresspool "${pool_name}" -n metallb-system -o jsonpath='{.spec.addresses}')

        # Check if this address range already exists
        if echo "${current_addresses}" | grep -q "${address_range}"; then
            echo "  Address range ${address_range} already exists in pool ${pool_name}"
        else
            echo "  Adding address range: ${address_range}"
            oc patch ipaddresspool "${pool_name}" -n metallb-system --type=json -p="[
                {\"op\": \"add\", \"path\": \"/spec/addresses/-\", \"value\": \"${address_range}\"}
            ]"
        fi

        # Check if namespace is already in serviceAllocation
        current_namespaces=$(oc get ipaddresspool "${pool_name}" -n metallb-system -o jsonpath='{.spec.serviceAllocation.namespaces}' 2>/dev/null || echo "")

        if echo "${current_namespaces}" | grep -q "${NAMESPACE}"; then
            echo "  Namespace ${NAMESPACE} already in serviceAllocation"
        else
            echo "  Adding namespace: ${NAMESPACE}"
            # Check if serviceAllocation exists
            if oc get ipaddresspool "${pool_name}" -n metallb-system -o jsonpath='{.spec.serviceAllocation}' &>/dev/null; then
                oc patch ipaddresspool "${pool_name}" -n metallb-system --type=json -p="[
                    {\"op\": \"add\", \"path\": \"/spec/serviceAllocation/namespaces/-\", \"value\": \"${NAMESPACE}\"}
                ]"
            else
                oc patch ipaddresspool "${pool_name}" -n metallb-system --type=json -p="[
                    {\"op\": \"add\", \"path\": \"/spec/serviceAllocation\", \"value\": {\"namespaces\": [\"${NAMESPACE}\"]}}
                ]"
            fi
        fi
    else
        echo "Pool '${pool_name}' doesn't exist - creating..."
        cat <<EOF | oc apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: ${pool_name}
  namespace: metallb-system
spec:
  autoAssign: ${auto_assign}
  addresses:
  - ${address_range}
  serviceAllocation:
    namespaces:
    - ${NAMESPACE}
EOF
    fi
}

# Function to create L2Advertisement if it doesn't exist
create_l2adv_if_missing() {
    local adv_name=$1
    local pool_name=$2
    local interface=$3

    if oc get l2advertisement "${adv_name}" -n metallb-system &>/dev/null; then
        echo "L2Advertisement '${adv_name}' already exists - skipping"
    else
        echo "Creating L2Advertisement: ${adv_name}"
        cat <<EOF | oc apply -f -
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: ${adv_name}
  namespace: metallb-system
spec:
  ipAddressPools:
  - ${pool_name}
  interfaces:
  - ${interface}
EOF
    fi
}

echo "Step 1: Configuring IPAddressPools..."
echo "--------------------------------------"
patch_or_create_pool "ctlplane" "${CTLPLANE_METALLB_POOL}" "true"
patch_or_create_pool "internalapi" "${INTERNALAPI_PREFIX}.80-${INTERNALAPI_PREFIX}.90" "true"
patch_or_create_pool "storage" "${STORAGE_PREFIX}.80-${STORAGE_PREFIX}.90" "true"
patch_or_create_pool "tenant" "${TENANT_PREFIX}.80-${TENANT_PREFIX}.90" "true"
patch_or_create_pool "designateext" "${DESIGNATE_EXT_PREFIX}.80-${DESIGNATE_EXT_PREFIX}.90" "false"

echo ""
echo "Step 2: Configuring L2Advertisements..."
echo "--------------------------------------"
create_l2adv_if_missing "ctlplane" "ctlplane" "${BRIDGE_NAME}"
create_l2adv_if_missing "internalapi" "internalapi" "${INTERFACE}.20"
create_l2adv_if_missing "storage" "storage" "${INTERFACE}.21"
create_l2adv_if_missing "tenant" "tenant" "${INTERFACE}.22"
create_l2adv_if_missing "designateext" "designateext" "${INTERFACE}.26"

echo ""
echo "=========================================="
echo "Configuration complete!"
echo "=========================================="
echo ""
echo "Verification:"
oc get ipaddresspool -n metallb-system
echo ""
echo "Checking namespace scoping for internalapi pool:"
oc get ipaddresspool internalapi -n metallb-system -o jsonpath='{.spec.serviceAllocation.namespaces}' | jq .
echo ""
