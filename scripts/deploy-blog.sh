#!/usr/bin/env bash

set -Eeuo pipefail

NAMESPACE="${BLOG_NAMESPACE:-blog}"
DEPLOYMENT="${BLOG_DEPLOYMENT:-blog}"
TIMEOUT="${BLOG_ROLLOUT_TIMEOUT:-10m}"
POD_SELECTOR="${BLOG_POD_SELECTOR:-}"

echo "Kubernetes context: $(kubectl config current-context)"
echo "Deploying ${DEPLOYMENT} in namespace ${NAMESPACE}"

kubectl get deployment "${DEPLOYMENT}" --namespace "${NAMESPACE}" > /dev/null

if [[ -z "${POD_SELECTOR}" ]]; then
    POD_SELECTOR="$(kubectl get deployment "${DEPLOYMENT}" \
        --namespace "${NAMESPACE}" \
        --output go-template='{{range $key, $value := .spec.selector.matchLabels}}{{printf "%s=%s," $key $value}}{{end}}')"
    POD_SELECTOR="${POD_SELECTOR%,}"
fi

if [[ -z "${POD_SELECTOR}" ]]; then
    echo "Unable to derive a pod selector for deployment ${DEPLOYMENT}; set BLOG_POD_SELECTOR explicitly"
    exit 1
fi

echo "Pod selector: ${POD_SELECTOR}"

kubectl rollout restart deployment/"${DEPLOYMENT}" --namespace "${NAMESPACE}"

if ! kubectl rollout status deployment/"${DEPLOYMENT}" --namespace "${NAMESPACE}" --timeout="${TIMEOUT}"; then
    echo "Deployment ${DEPLOYMENT} failed to roll out in namespace ${NAMESPACE} within ${TIMEOUT}"
    kubectl get pods --namespace "${NAMESPACE}" -o wide
    kubectl describe deployment "${DEPLOYMENT}" --namespace "${NAMESPACE}"
    exit 1
fi

echo "Blog deployment ${DEPLOYMENT} successfully rolled out in namespace ${NAMESPACE}"

kubectl get pods --namespace "${NAMESPACE}" --selector "${POD_SELECTOR}" -o wide
