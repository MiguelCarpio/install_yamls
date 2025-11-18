#!/bin/bash
#
# Copyright 2024 Red Hat Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License"); you may
# not use this file except in compliance with the License. You may obtain
# a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
# License for the specific language governing permissions and limitations
# under the License.
set -ex

if [ -z "${DEPLOY_DIR}" ]; then
    echo "Please set DEPLOY_DIR"; exit 1
fi

if [ ! -d ${DEPLOY_DIR} ]; then
    mkdir -p ${DEPLOY_DIR}
fi

if [ -z "${INTERFACE}" ]; then
    echo "Please set INTERFACE"; exit 1
fi

if [ -z "${BRIDGE_NAME}" ]; then
    echo "Please set BRIDGE_NAME"; exit 1
fi

if [ -z "${ASN}" ]; then
    echo "Please set ASN"; exit 1
fi

if [ -z "${PEER_ASN}" ]; then
    echo "Please set PEER_ASN"; exit 1
fi

if [ -z "${LEAF_1}" ]; then
    echo "Please set LEAF_1"; exit 1
fi

if [ -z "${LEAF_2}" ]; then
    echo "Please set LEAF_2"; exit 1
fi

if [ -z "${SOURCE_IP}" ]; then
    echo "Please set SOURCE_IP"; exit 1
fi

if [ -z "$IPV4_ENABLED" ] && [ -z "$IPV6_ENABLED" ]; then
    echo "Please enable either IPv4 or IPv6 by setting IPV4_ENABLED or IPV6_ENABLED"; exit 1
fi

echo DEPLOY_DIR ${DEPLOY_DIR}
echo INTERFACE ${INTERFACE}
echo CTLPLANE_METALLB_POOL ${CTLPLANE_METALLB_POOL}
echo CTLPLANE_METALLB_IPV6_POOL ${CTLPLANE_METALLB_IPV6_POOL}
echo RHOSO_INSTANCE_NAME ${RHOSO_INSTANCE_NAME}

# Multi-RHOSO support: Use namespace-prefixed pool names
# Pool names include namespace prefix to ensure uniqueness
# Example: openstack-internalapi, openstack2-internalapi
# Requires kustomize patches to update service annotations
if [ -n "${OPENSTACK_NAMESPACE}" ]; then
    echo "Multi-RHOSO mode: Creating prefixed pools for namespace '${OPENSTACK_NAMESPACE}'"
    USE_NAMESPACE_SCOPING=true
    NAMESPACE="${OPENSTACK_NAMESPACE}"
    POOL_PREFIX="${OPENSTACK_NAMESPACE}-"
    L2ADV_SUFFIX="-${OPENSTACK_NAMESPACE}"
else
    echo "Single RHOSO mode: No namespace prefix"
    USE_NAMESPACE_SCOPING=false
    POOL_PREFIX=""
    L2ADV_SUFFIX=""
fi

cat > ${DEPLOY_DIR}/ipaddresspools.yaml <<EOF_CAT
---
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  namespace: metallb-system
  name: ${POOL_PREFIX}ctlplane
spec:
  addresses:
EOF_CAT
if [ -n "$IPV4_ENABLED" ]; then
    cat >> ${DEPLOY_DIR}/ipaddresspools.yaml <<EOF_CAT
  - ${CTLPLANE_METALLB_POOL}
EOF_CAT
fi
if [ -n "$IPV6_ENABLED" ]; then
    cat >> ${DEPLOY_DIR}/ipaddresspools.yaml <<EOF_CAT
  - ${CTLPLANE_METALLB_IPV6_POOL}
EOF_CAT
fi
if [ "${USE_NAMESPACE_SCOPING}" = "true" ]; then
    cat >> ${DEPLOY_DIR}/ipaddresspools.yaml <<EOF_CAT
  serviceAllocation:
    namespaces:
    - ${NAMESPACE}
EOF_CAT
fi
cat >> ${DEPLOY_DIR}/ipaddresspools.yaml <<EOF_CAT
---
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  namespace: metallb-system
  name: ${POOL_PREFIX}internalapi
spec:
  addresses:
EOF_CAT
if [ -n "$IPV4_ENABLED" ]; then
    cat >> ${DEPLOY_DIR}/ipaddresspools.yaml <<EOF_CAT
  - ${INTERNALAPI_PREFIX}.80-${INTERNALAPI_PREFIX}.90
EOF_CAT
fi
if [ -n "$IPV6_ENABLED" ]; then
    cat >> ${DEPLOY_DIR}/ipaddresspools.yaml <<EOF_CAT
  - fd00:bbbb::80-fd00:bbbb::90
EOF_CAT
fi
if [ "${USE_NAMESPACE_SCOPING}" = "true" ]; then
    cat >> ${DEPLOY_DIR}/ipaddresspools.yaml <<EOF_CAT
  serviceAllocation:
    namespaces:
    - ${NAMESPACE}
EOF_CAT
fi
cat >> ${DEPLOY_DIR}/ipaddresspools.yaml <<EOF_CAT
---
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  namespace: metallb-system
  name: ${POOL_PREFIX}storage
spec:
  addresses:
EOF_CAT
if [ -n "$IPV4_ENABLED" ]; then
    cat >> ${DEPLOY_DIR}/ipaddresspools.yaml <<EOF_CAT
  - ${STORAGE_PREFIX}.80-${STORAGE_PREFIX}.90
EOF_CAT
fi
if [ -n "$IPV6_ENABLED" ]; then
    cat >> ${DEPLOY_DIR}/ipaddresspools.yaml <<EOF_CAT
  - fd00:cccc::80-fd00:cccc::90
EOF_CAT
fi
if [ "${USE_NAMESPACE_SCOPING}" = "true" ]; then
    cat >> ${DEPLOY_DIR}/ipaddresspools.yaml <<EOF_CAT
  serviceAllocation:
    namespaces:
    - ${NAMESPACE}
EOF_CAT
fi
cat >> ${DEPLOY_DIR}/ipaddresspools.yaml <<EOF_CAT
---
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  namespace: metallb-system
  name: ${POOL_PREFIX}tenant
spec:
  addresses:
EOF_CAT
if [ -n "$IPV4_ENABLED" ]; then
    cat >> ${DEPLOY_DIR}/ipaddresspools.yaml <<EOF_CAT
  - ${TENANT_PREFIX}.80-${TENANT_PREFIX}.90
EOF_CAT
fi
if [ -n "$IPV6_ENABLED" ]; then
    cat >> ${DEPLOY_DIR}/ipaddresspools.yaml <<EOF_CAT
  - fd00:dddd::80-fd00:dddd::90
EOF_CAT
fi
if [ "${USE_NAMESPACE_SCOPING}" = "true" ]; then
    cat >> ${DEPLOY_DIR}/ipaddresspools.yaml <<EOF_CAT
  serviceAllocation:
    namespaces:
    - ${NAMESPACE}
EOF_CAT
fi
cat >> ${DEPLOY_DIR}/ipaddresspools.yaml <<EOF_CAT
---
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  namespace: metallb-system
  name: ${POOL_PREFIX}designateext
spec:
  autoAssign: false
  addresses:
EOF_CAT
if [ -n "$IPV4_ENABLED" ]; then
    cat >> ${DEPLOY_DIR}/ipaddresspools.yaml <<EOF_CAT
  - ${DESIGNATE_EXT_PREFIX}.80-${DESIGNATE_EXT_PREFIX}.90
EOF_CAT
fi
if [ -n "$IPV6_ENABLED" ]; then
    cat >> ${DEPLOY_DIR}/ipaddresspools.yaml <<EOF_CAT
  - fd00:eaea::80-fd00:eaea::90
EOF_CAT
fi
if [ "${USE_NAMESPACE_SCOPING}" = "true" ]; then
    cat >> ${DEPLOY_DIR}/ipaddresspools.yaml <<EOF_CAT
  serviceAllocation:
    namespaces:
    - ${NAMESPACE}
EOF_CAT
fi

cat > ${DEPLOY_DIR}/l2advertisement.yaml <<EOF_CAT
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: ${POOL_PREFIX}ctlplane
  namespace: metallb-system
spec:
  ipAddressPools:
  - ${POOL_PREFIX}ctlplane
  interfaces:
  - ${BRIDGE_NAME}
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: ${POOL_PREFIX}internalapi
  namespace: metallb-system
spec:
  ipAddressPools:
  - ${POOL_PREFIX}internalapi
  interfaces:
  - ${INTERFACE}.20
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: ${POOL_PREFIX}storage
  namespace: metallb-system
spec:
  ipAddressPools:
  - ${POOL_PREFIX}storage
  interfaces:
  - ${INTERFACE}.21
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: ${POOL_PREFIX}tenant
  namespace: metallb-system
spec:
  ipAddressPools:
  - ${POOL_PREFIX}tenant
  interfaces:
  - ${INTERFACE}.22
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: ${POOL_PREFIX}designateext
  namespace: metallb-system
spec:
  ipAddressPools:
  - ${POOL_PREFIX}designateext
  interfaces:
  - ${INTERFACE}.26
EOF_CAT
cat > ${DEPLOY_DIR}/bgppeers.yaml <<EOF_CAT
---
apiVersion: metallb.io/v1beta2
kind: BGPPeer
metadata:
  name: ${POOL_PREFIX}bgp-peer
  namespace: metallb-system
spec:
  myASN: ${ASN}
  peerASN: ${PEER_ASN}
  peerAddress: ${LEAF_1}
  password: f00barZ
  routerID: ${SOURCE_IP}
---
apiVersion: metallb.io/v1beta2
kind: BGPPeer
metadata:
  name: ${POOL_PREFIX}bgp-peer-2
  namespace: metallb-system
spec:
  myASN: ${ASN}
  peerASN: ${PEER_ASN}
  peerAddress: ${LEAF_2}
  password: f00barZ
  routerID: ${SOURCE_IP}
EOF_CAT
cat > ${DEPLOY_DIR}/bgpadvertisement.yaml <<EOF_CAT
---
apiVersion: metallb.io/v1beta1
kind: BGPAdvertisement
metadata:
  name: ${POOL_PREFIX}bgpadvertisement
  namespace: metallb-system
spec:
  ipAddressPools:
  - ${POOL_PREFIX}ctlplane
  - ${POOL_PREFIX}internalapi
  - ${POOL_PREFIX}storage
  - ${POOL_PREFIX}tenant
  - ${POOL_PREFIX}designateext
  peers:
  - ${POOL_PREFIX}bgp-peer
  - ${POOL_PREFIX}bgp-peer-2
EOF_CAT
cat > ${DEPLOY_DIR}/bgpextras.yaml << EOF_CAT
---
apiVersion: v1
kind: ConfigMap
metadata:
  namespace: metallb-system
  name: bgpextras
data:
  extras: |
    router bgp ${ASN}
      network ${SOURCE_IP}/32
      neighbor ${LEAF_1} allowas-in origin
      neighbor ${LEAF_2} allowas-in origin

    ! ip prefix-list osp permit 172.16.0.0/16 le 32
    route-map ${LEAF_1}-in permit 20
      ! match ip address prefix-list osp
      set src ${SOURCE_IP}
    route-map ${LEAF_2}-in permit 20
      ! match ip address prefix-list osp
      set src ${SOURCE_IP}
    ip protocol bgp route-map ${LEAF_1}-in
    ip protocol bgp route-map ${LEAF_2}-in

    ip prefix-list ocp-lo permit ${SOURCE_IP}/32
    route-map ${LEAF_1}-out permit 3
      match ip address prefix-list ocp-lo
    route-map ${LEAF_2}-out permit 3
      match ip address prefix-list ocp-lo
EOF_CAT
