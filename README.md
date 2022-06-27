# Hack your Kubernetes controller in Bash in 10 minutes!

| [✨ Follow the presentation using the "live" slides][live] | [🎓️ Standard slides][slides] |
| ------------------- | ---------------- |

[live]: https://slides.com/d/jZelwBg/live "Live slides only available on 30 June 2022 for the presentation 'Hack your Kubernetes controller in Bash in 10 minutes!'"
[slides]: https://slides.com/maelvls/hack-your-kubernetes-controller-in-10-minutes "Slides of the presentation 'Hack your Kubernetes controller in Bash in 10 minutes!'"

On 30 June 2022, Antoine Le Squéren and Maël Valais presented "Hack your
Kubernetes controller in Bash in 10 minutes!" at Kubernetetes Community
Days Berlin. This README details how to reproduce what was presented during
the presentation.

## Try the one-liner controller for yourself (`controller.sh`)

In the presentation, we presented a simple "one-liner" controller that
relies on `kubectl` and `jq`. The one-liner looks like this:

```sh
#! /bin/bash

kubectl get externalsecret --watch -ojson \
  | jq 'select(.status.conditions[]?.reason == "SecretSyncedError")' --unbuffered \
  | jq '.spec.data[0].remoteRef | "\(.key) \(.property)"' -r --unbuffered \
  | while read key property; do
    vault kv put $key $property=somerandomvalue
  done
```

In this repository, you will find the file `controller.sh`. It contains
this one-liner.

To try this one-liner controller, you will need the following
prerequisites:

- [`k3d`](https://k3d.io/v5.4.3/#installation)
- [`telepresence`](https://www.telepresence.io/docs/latest/install/)

Now, let us set up everything needed to run the one-liner controller.

```sh
./setup.sh
```

> This command spawns a K3s Kubernetes cluster, installs Vault and
> external-secrets, and creates an ExternalSecret object so that you can see
> the controller's behavior.

Optional: you can watch the external secrets to follow the changes along:

```console
$ kubectl get externalsecret --watch
NAME       KEY                     PROPERTY   READY   REASON         MESSAGE
postgres   secret/dev-1/postgres   password   True    SecretSynced   Secret was synced
postgres   secret/dev-1/postgres   password   True    SecretSynced   Secret was synced
```

Then, create a tunnel to Vault:

```console
kubectl port-forward -n vault vault-0 8200
```

In a different Shell session, run the controller:

```sh
./controller.sh
```

The output of `controller.sh` shows when a `vault put` command is executed:

```console
$ ./controller.sh
======= Secret Path =======
secret/data/dev-1/postgres

======= Metadata =======
Key                Value
---                -----
created_time       2022-06-27T15:41:59.346502796Z
custom_metadata    <nil>
deletion_time      n/a
destroyed          false
version            1
```

The last step is to run the same thing in a Pod:

```sh
docker buildx build . -t controller:local -o type=docker,dest=img.tar && k3d images import img.tar
kubectl apply -f ./deploy.yaml
```

Check that the controller is running:

```console
$ kubectl logs -f deployment/controller
======= Secret Path =======
secret/data/dev-1/postgres

======= Metadata =======
Key                Value
---                -----
created_time       2022-06-27T15:41:59.346502796Z
custom_metadata    <nil>
deletion_time      n/a
destroyed          false
version            2
```

To see if the controller is working, you can run the following command:

```sh
vault kv metadata delete secret/dev-1/postgres
```

The logs of the controller should show that the secret was re-generated.

## Go further: try the advanced Bash controller (`controller-with-conditions.sh`)

As we demonstrated during the presentation, one-liner `controller.sh` has a
very uninformative logs.

On top of poor logs, `controller.sh` does not inform Kubernetes users why a
particular ExternalSecret object does not seem to be picked up by the
controller. Nothing shows in the status, and nothing shows in events.

To correct that, you can try `controller-with-conditions.sh`. This
controller is a bit more complex due to a limitation in `kubectl`
preventing us to update the status of an ExternalSecret object.

```sh
./controller-with-conditions.sh
```

This controller is a bit more elaborated; it waits until an ExternalSecret
has the annotation `create: true` before creating a random secret in Vault.
Thus, the next step is to tell the controller to create the secret with our
existing `postgres` ExternalSecret.

```sh
kubectl annotate externalsecret postgres create=true
```

The logs should look like this:

```console
$ ./controller-with-conditions.sh
info: started watching ExternalSecrets.
postgres: inconsistency: Created is True but SecretSyncedError is False. Attempting to recreate the secret in Vault to fix this issue.
postgres: the ExternalSecret is Ready=False, let us create a random password and put it in Vault.
postgres: the Vault secret was created.
```
