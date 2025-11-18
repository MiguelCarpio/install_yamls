#!/bin/bash
#
# Emergency fix for multi-RHOSO MetalLB pools
#
# This script replaces the incorrect single-instance pools with
# combined pools that support both openstack and openstack2 namespaces
#

set -e

echo "==========================================="
echo "Multi-RHOSO MetalLB Pool Recovery"
echo "==========================================="
echo ""

# Step 1: Delete existing pools
echo "Step 1: Deleting existing MetalLB pools..."
oc delete ipaddresspool --all -n metallb-system
oc delete l2advertisement --all -n metallb-system

echo ""
echo "Step 2: Applying combined MetalLB configuration..."
oc apply -f config/multi-rhoso/combined-metallb-pools.yaml

echo ""
echo "Step 3: Verifying pools..."
oc get ipaddresspool -n metallb-system

echo ""
echo "Step 4: Verifying L2 advertisements..."
oc get l2advertisement -n metallb-system

echo ""
echo "Step 5: Checking pool namespace scoping..."
oc get ipaddresspool internalapi -n metallb-system -o jsonpath='{.spec.serviceAllocation.namespaces}'
echo ""

echo ""
echo "==========================================="
echo "Recovery complete!"
echo "==========================================="
echo ""
echo "Now watch your services get IPs:"
echo "  oc get svc -n openstack | grep LoadBalancer"
echo "  oc get svc -n openstack2 | grep LoadBalancer"
echo ""
