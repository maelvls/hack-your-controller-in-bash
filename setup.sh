#! /bin/bash

set -uexo pipefail

k3d cluster list | grep -q k3s-default || k3d cluster create

helm repo add --force-update hashicorp https://helm.releases.hashicorp.com
helm upgrade --install vault hashicorp/vault \
  -n vault --create-namespace \
  --set server.dev.enabled=true \
  --set server.ingress.enabled=true \
  --set global.tlsDisable=true

helm repo add --force-update external-secrets https://charts.external-secrets.io
helm upgrade --install external-secrets \
  external-secrets/external-secrets \
  -n external-secrets --create-namespace \
  --set installCRDs=true

# The external-secrets webhook pod takes some time to get started. This
# command waits until the webhook responds.
timeout 5m bash -c "until kubectl apply --dry-run=server -f- <<<$'apiVersion: external-secrets.io/v1beta1\nkind: SecretStore\nmetadata:\n  name: test\nspec:\n  provider: {fake: {data: []}}'; do sleep 1; done"

# When running "kubectl get externalsecret", the columns are not very
# informative. This command modifies the displayed columns so that we can see
# the status and message of the Ready condition, as well as the key and
# property of the remote secret. The new output looks like this:
#
#   $ kubectl get externalsecret
#   NAME       KEY                     PROPERTY   READY   REASON         MESSAGE
#   postgres   secret/dev-1/postgres   password   True    SecretSynced   Secret was synced
kubectl get crd externalsecrets.external-secrets.io -ojson \
  | jq '(.spec.versions[].additionalPrinterColumns) = [{"jsonPath":".spec.data[*].remoteRef.key","name":"Key","type":"string"},{"jsonPath":".spec.data[*].remoteRef.property","name":"Property","type":"string"},{"jsonPath":".status.conditions[?(@.type==\"Ready\")].status","name":"Ready","type":"string"},{"jsonPath":".status.conditions[?(@.type==\"Ready\")].reason","name":"Reason","type":"string"},{"jsonPath":".status.conditions[?(@.type==\"Ready\")].message","name":"Message","type":"string"}]' \
  | kubectl apply -f-

kubectl apply -f- <<EOF
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: vault-backend
spec:
  provider:
    vault:
      server: http://vault.vault.svc.cluster.local:8200
      path: secret
      version: v2
      auth:
        tokenSecretRef:
          name: vault-token
          key: vault-token
---
apiVersion: v1
kind: Secret
metadata:
  name: vault-token
stringData:
  vault-token: root
EOF

kubectl apply -f- <<EOF
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: postgres
spec:
  data:
  - remoteRef:
      key: secret/dev-1/postgres
      property: password
    secretKey: password
  refreshInterval: 5s
  secretStoreRef:
    name: vault-backend
  target:
    name: postgres
EOF
