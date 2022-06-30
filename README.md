# Hack your Kubernetes controller in Bash in 10 minutes!

| [🎓️ Slides][slides] |
| ----------------------------- |

[slides]: https://slides.com/maelvls/hack-your-kubernetes-controller-in-10-minutes "Slides of the presentation 'Hack your Kubernetes controller in Bash in 10 minutes!'"

On 30 June 2022, Antoine Le Squéren and Maël Valais presented "Hack your
Kubernetes controller in Bash in 10 minutes!" at Kubernetetes Community
Days Berlin. The rest of this document shows how to run the "one-liner
controller" we talked about in the presentation.

## Try the one-liner controller for yourself (`controller.sh`)

In the presentation, we show a controller that takes for form of a
"one-liner" that you can copy-paste in your terminal.

```sh
kubectl get externalsecret --watch -ojson \
  | jq 'select(.status.conditions[]?.reason == "SecretSyncedError")' --unbuffered \
  | jq '.spec.data[0].remoteRef | "\(.key) \(.property)"' -r --unbuffered \
  | while read key property; do
    vault kv put $key $property=somerandomvalue
  done
```

The file `controller.sh` contains the above command.

To try this controller, you will need to install the following tools:

- `docker` which you can get with [`colima`](https://github.com/abiosoft/colima)
  on M1 and Intel Macs (instead of Docker Desktop for Mac).
- [`kubectl`](https://kubernetes.io/docs/tasks/tools/install-kubectl/) 1.24 or above (required for `--subresource`),
- [`k3d`](https://k3d.io/v5.4.3/#installation).

Then, run the following command. The command creates a K3s cluster
and installs Vault and external-secrets, as well as an ExternalSecret
object called `postgres` for demonstration purposes:

```sh
./setup.sh
```

Run the following long-running command (this is an optional step):

```console
$ kubectl get externalsecret --watch
NAME       KEY                     PROPERTY   READY   REASON         MESSAGE
postgres   secret/dev-1/postgres   password   True    SecretSynced   Secret was synced
postgres   secret/dev-1/postgres   password   True    SecretSynced   Secret was synced
```

Open a second shell session to create a tunnel to Vault with
the following command:

```console
kubectl port-forward -n vault vault-0 8200
```

In a third shell session, run the controller with the command:

```sh
export VAULT_ADDR=http://localhost:8200 VAULT_TOKEN=root
./controller.sh
```

Looking at the first shell session (the one with `kubectl get externalsecret --watch`)
you will see the `postgres` external secret going from `SecretSyncedError` to
`SecretSynced`:

```text
NAME       KEY                     PROPERTY   READY   REASON             MESSAGE
postgres   secret/dev-1/postgres   password   False   SecretSyncedError  could not get secret data from provider
postgres   secret/dev-1/postgres   password   True    SecretSynced       Secret was synced
```

The controller's output isn't great. It just shows what `vault put` shows
when an external secret is processed.

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

(Optional) You can now run the controller in a Pod. Run the following
two commands to build the container and

```sh
docker buildx build . -t controller:local -o type=docker,dest=img.tar && k3d images import img.tar
kubectl apply -f ./deploy.yaml
```

> **⁉️ `docker build` vs. `docker buildx build`**: In the above command, we use the
> `buildx` subcommand, also called BuildKit. Unlike the traditional `docker build`
> command, with BuildKit, it is possible to save the Docker-compatible image tarball
> directly to disk using `-o type=docker,dest=img.tar`.

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

In the first shell session where `kubectl get externalsecret --watch` is running,
you will see the external secret from `SecretSynced` to `SecretSyncedError`
and back to `SecretSyncedError`:

```text
NAME       KEY                     PROPERTY   READY   REASON             MESSAGE
postgres   secret/dev-1/postgres   password   False   SecretSyncedError  could not get secret data from provider
postgres   secret/dev-1/postgres   password   True    SecretSynced       Secret was synced
postgres   secret/dev-1/postgres   password   True    SecretSynced       Secret was synced
postgres   secret/dev-1/postgres   password   True    SecretSynced       Secret was synced
postgres   secret/dev-1/postgres   password   False   SecretSyncedError  could not get secret data from provider
postgres   secret/dev-1/postgres   password   True    SecretSynced       Secret was synced
```

## Go further: try the advanced Bash controller (`controller-with-conditions.sh`)

As we demonstrated during the presentation, one-liner `controller.sh` has a
very uninformative logs.

On top of poor logs, `controller.sh` does not inform Kubernetes users why a
particular ExternalSecret object does not seem to be picked up by the
controller. Nothing shows in the status, and nothing shows in events.

The file `controller-with-conditions.sh` is similar to `controller.sh`, except
for three aspects:

1. The user is now alerted of problems with the condition `Created`.
2. The user now has to set the annotation `create: true` to enable the
   auto-generation of the secret in Vault.
3. The logs are now well structured.

In a first shell session, turn on port-forwarding to Vault with the command:

```console
kubectl port-forward -n vault vault-0 8200
```

In a second shell session, run the controller with the command:

```sh
export VAULT_ADDR=http://localhost:8200 VAULT_TOKEN=root
./controller-with-conditions.sh
```

You can now "enable" the behavior on the external secret `postgres` with the
following command:

```sh
kubectl annotate externalsecret postgres create=true
```

The logs should look like this:

```console
$ ./controller-with-conditions.sh
info: started watching ExternalSecrets.
postgres: the ExternalSecret is Ready=False, let us create a random password and put it in Vault.
postgres: the Vault secret was created.
postgres: inconsistency: Created is True but SecretSyncedError is False. Attempting to recreate the secret in Vault to fix this issue.
postgres: the ExternalSecret is Ready=False, let us create a random password and put it in Vault.
postgres: the Vault secret was created.
```
