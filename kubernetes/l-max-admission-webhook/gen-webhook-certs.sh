#!/usr/bin/env bash
# L-MAX: create the TLS material the admission webhook needs, with nothing but openssl and kubectl.
#   1. a throw-away CA,
#   2. a serving certificate signed by it, with the Service DNS names in subjectAltName
#      (Go has rejected CN-only certificates since 1.15, so `-subj /CN=...` alone does not work),
#   3. the webhook-tls Secret (tls.crt, tls.key) the webhook Deployment mounts,
#   4. the two WebhookConfigurations, applied with the CA bundle filled in.
# In production let cert-manager do this (annotation cert-manager.io/inject-ca-from) so it rotates.
#
# Usage: bash gen-webhook-certs.sh          (kubectl must point at the lab cluster)
set -euo pipefail

NAMESPACE="${NAMESPACE:-demo}"
SERVICE="${SERVICE:-webapp-webhook-service}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

openssl req -x509 -newkey rsa:2048 -nodes -days 365 -keyout "${WORK}/ca.key" -out "${WORK}/ca.crt" \
  -subj "/CN=webapp-webhook-ca" 2>/dev/null

openssl req -newkey rsa:2048 -nodes -keyout "${WORK}/tls.key" -out "${WORK}/tls.csr" \
  -subj "/CN=${SERVICE}.${NAMESPACE}.svc" 2>/dev/null
printf 'subjectAltName=DNS:%s,DNS:%s.%s,DNS:%s.%s.svc\nextendedKeyUsage=serverAuth\n' \
  "${SERVICE}" "${SERVICE}" "${NAMESPACE}" "${SERVICE}" "${NAMESPACE}" > "${WORK}/san.ext"
openssl x509 -req -in "${WORK}/tls.csr" -CA "${WORK}/ca.crt" -CAkey "${WORK}/ca.key" -CAcreateserial \
  -days 365 -extfile "${WORK}/san.ext" -out "${WORK}/tls.crt" 2>/dev/null

kubectl -n "${NAMESPACE}" create secret tls webhook-tls --cert="${WORK}/tls.crt" --key="${WORK}/tls.key" \
  --dry-run=client -o yaml | kubectl apply -f -

# Only namespaces carrying this label are intercepted (see namespaceSelector in the configuration).
kubectl label namespace "${NAMESPACE}" webhook-injection=enabled --overwrite

CA_BUNDLE="$(base64 -w0 < "${WORK}/ca.crt")"
sed "s|caBundle: \"\".*|caBundle: ${CA_BUNDLE}|" "${HERE}/webhook-validating-mutating-configuration.yaml" | kubectl apply -f -
echo "webhook-tls Secret created and WebhookConfigurations applied in namespace ${NAMESPACE}."
