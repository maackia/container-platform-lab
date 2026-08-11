#!/usr/bin/bash

set -Eeuo pipefail

NAMESPACE="${BLOG_NAMESPACE:-blog}"
DEPLOYMENT="${BLOG_DEPLOYMENT:-blog}"
TIMEOUT="${BLOG_ROLLOUT_TIMEOUT:-180s}"

echo "Kubernetes context: $(kubectl config current-context)"
echo "Deploying ${DEPLOYMENT} in namespace ${NAMESPACE}"

kubectl get deployment "${DEPLOYMENT}" --namespace "${NAMESPACE}" > /dev/null

kubectl rollout restart deployment/"${DEPLOYMENT}" --namespace "${NAMESPACE}"

if ! kubectl rollout status deployment/"${DEPLOYMENT}" --namespace "${NAMESPACE}" --timeout="${TIMEOUT}"; then
    echo "Deployment ${DEPLOYMENT} failed to roll out in namespace ${NAMESPACE} within ${TIMEOUT}"
    kubectl get pods --namespace "${NAMESPACE}" -o wide
    kubectl describe deployment "${DEPLOYMENT}" --namespace "${NAMESPACE}"
    exit 1
fi

echo "Blog deployment ${DEPLOYMENT} successfully rolled out in namespace ${NAMESPACE}"

kubectl get pods --namespace "${NAMESPACE}" --selector app=blog -o wide
