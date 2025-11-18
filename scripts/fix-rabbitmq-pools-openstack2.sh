#!/bin/bash
#
# Fix RabbitMQ pool annotations for openstack2
#

set -e

NAMESPACE=openstack2
POOL_NAME="openstack2-internalapi"

echo "========================================"
echo "Fixing RabbitMQ MetalLB Pool Annotations"
echo "========================================"
echo "Namespace: ${NAMESPACE}"
echo "Pool: ${POOL_NAME}"
echo "========================================"
echo ""

# Get the control plane name
CONTROLPLANE_NAME=$(oc get openstackcontrolplanes.core.openstack.org -n ${NAMESPACE} -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -z "${CONTROLPLANE_NAME}" ]; then
    echo "ERROR: No OpenStackControlPlane found in namespace ${NAMESPACE}"
    exit 1
fi

echo "ControlPlane: ${CONTROLPLANE_NAME}"
echo ""

# Use 'replace' operation to force update
echo "Updating RabbitMQ service annotations..."
oc patch openstackcontrolplanes.core.openstack.org ${CONTROLPLANE_NAME} -n ${NAMESPACE} --type=json -p="[
    {
        \"op\": \"replace\",
        \"path\": \"/spec/rabbitmq/templates/rabbitmq/override/service/metadata/annotations/metallb.universe.tf~1address-pool\",
        \"value\": \"${POOL_NAME}\"
    },
    {
        \"op\": \"replace\",
        \"path\": \"/spec/rabbitmq/templates/rabbitmq/override/service/metadata/annotations/metallb.universe.tf~1allow-shared-ip\",
        \"value\": \"${POOL_NAME}\"
    }
]" 2>&1 || echo "  Trying full path replacement..."

# Alternative: Try full service override replacement
oc patch openstackcontrolplanes.core.openstack.org ${CONTROLPLANE_NAME} -n ${NAMESPACE} --type=json -p="[
    {
        \"op\": \"replace\",
        \"path\": \"/spec/rabbitmq/templates/rabbitmq/override/service\",
        \"value\": {
            \"spec\": {
                \"type\": \"LoadBalancer\"
            },
            \"metadata\": {
                \"annotations\": {
                    \"metallb.universe.tf/address-pool\": \"${POOL_NAME}\",
                    \"metallb.universe.tf/allow-shared-ip\": \"${POOL_NAME}\"
                }
            }
        }
    },
    {
        \"op\": \"replace\",
        \"path\": \"/spec/rabbitmq/templates/rabbitmq-cell1/override/service\",
        \"value\": {
            \"spec\": {
                \"type\": \"LoadBalancer\"
            },
            \"metadata\": {
                \"annotations\": {
                    \"metallb.universe.tf/address-pool\": \"${POOL_NAME}\",
                    \"metallb.universe.tf/allow-shared-ip\": \"${POOL_NAME}\"
                }
            }
        }
    }
]"

echo ""
echo "========================================"
echo "Patch applied!"
echo "========================================"
echo ""
echo "Waiting for RabbitMQ services to be recreated..."
echo "Check with: oc get svc -n ${NAMESPACE} | grep rabbitmq"
