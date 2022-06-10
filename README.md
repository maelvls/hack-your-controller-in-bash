# An ExternalSecret controller that creates missing Vault secrets using a random password generator

## Install

Prerequisites:

- [`k3d`](https://k3d.io/v5.4.3/#installation)
- [`telepresence`](https://www.telepresence.io/docs/latest/install/)

First, you will need a Vault instance running as well as a Kubernetes
cluster with the external-secrets operator running. To get all of these
three things, and run:

```sh
./setup.sh
```

> The above command creates a Kubernetes cluster, install Vault, and
> install external-secrets.

Get access to the Vault instance from outside the cluster:

```sh
telepresence connect
```

Finally, run the controller:

```sh
DEBUG=1 ./external-secrets-vault-creator.sh
```

## Run

First, create an external secret:

```sh
kubectl apply -f- <<EOF
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: example
  annotations:
    external-secrets-vault-creator=hex32 # ✨
spec:
  secretStoreRef:
    name: vault-backend
    kind: SecretStore
  target:
    name: example
    creationPolicy: Owner
  data:
    - remoteRef:
        key: secret/foo
        property: bar
      secretKey: bar
EOF
```

## Appendix

### FAQ 1: does the Vault Kubernetes auth work?

If you are getting `403 Forbidden` errors, follow the instructions below.

It is possible to check whether the Pod that runs
external-secrets-vault-creator can access the Vault API. Run the following
command:

```sh
kubectl run b -it --rm --restart=Never -q --image=hashicorp/vault:1.10.3 -- \
 sh -c 'export VAULT_ADDR=http://vault.vault.svc.cluster.local:8200; vault login token=$(vault write -field=token auth/kubernetes/login role=external-secrets-vault-creator jwt=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)); sh'
```

You are now given a shell. To see if the external-secrets-vault-creator
will be able to list secrets, you can try the command:

```sh
vault kv list secret
```

### FAQ 2 can I run the controller locally but still Vault outside of the cluster?

You can use telepresence for that. I tested telepresence v2. telepresence
v2 does not support "teleporting to a pod" without having a service
associated, so you will have to create a bogus service with the following
command:

```sh
kubectl expose deployment external-secrets-vault-creator --port 1
```

On Linux machines, you will need FUSE installed as well as the line
`user_allow_other` de-commecnted in your `/etc/fuse.conf`.
