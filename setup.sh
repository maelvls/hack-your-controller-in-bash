#! /bin/bash

k3d cluster create

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

kubectl exec -n vault vault-0 -i -- vault auth enable kubernetes

# shellcheck disable=SC2016
kubectl exec -n vault vault-0 -i -- sh <<'EOF'
vault write auth/kubernetes/config \
    token_reviewer_jwt="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" \
    kubernetes_host="https://$(echo $KUBERNETES_PORT_443_TCP_ADDR):443" \
    kubernetes_ca_cert=@<(cat /var/run/secrets/kubernetes.io/serviceaccount/ca.crt)
EOF

kubectl exec -n vault vault-0 -i -- vault policy write external-secrets-operator - <<'EOF'
path "secret/*"   { capabilities = ["read", "list"] }
EOF
kubectl exec -n vault vault-0 -i -- sh <<'EOF'
vault write auth/kubernetes/role/external-secrets-operator \
    bound_service_account_names=external-secrets \
    bound_service_account_namespaces=external-secrets \
    policies=external-secrets-operator \
    ttl=1h
EOF

# The "external-secrets-vault-creator" service account doesn't need any
# permission, it is only used by a pod to access the Vault API using the
# pod's Kubernetes token.
kubectl create -n default serviceaccount external-secrets-vault-creator
kubectl exec -n vault vault-0 -i -- vault policy write external-secrets-vault-creator - <<'EOF'
path "secret/*"   { capabilities = ["read", "list"] }
path "secret/*"   { capabilities = ["create", "update"] }
EOF
kubectl exec -n vault vault-0 -i -- sh <<'EOF'
vault write auth/kubernetes/role/external-secrets-vault-creator \
    bound_service_account_names=external-secrets-vault-creator \
    bound_service_account_namespaces=default \
    policies=external-secrets-vault-creator \
    ttl=1h
EOF

kubectl apply -f- <<EOF
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: vault-backend
spec:
  provider:
    vault:
      server: "http://vault.vault.svc.cluster.local:8200"
      path: secret
      version: v2
      auth:
        kubernetes:
          mountPath: kubernetes
          role: external-secrets-operator
EOF
