#!/usr/bin/env bash

# This controller only works with kubectl 1.24 and above, since
# --subresource appeared with kubectl 1.24.

set -buo pipefail
# I won't set -x because this is a long-lasting script and I can't afford
# crashes. The flag '-b' silences bash's job control messages.

DEBUG="${DEBUG:-}"

# Since 1.24, it is now possible to update resource statuses. This function
# makes it easy to set a condition on a given externalsecret (e.g.,
# Ready=True).
#
#   Usage: kubectl-condition postgres Ready False SyncedError "Message"
#                            <--$1--> <---> <---> <---$4----> <--$5--->
#                                       $2    $3
# $1 is the external secret name, $2 is the condition type, $3 is the
# condition status, $4 is the reason and $5 the message. The message can contain
# new lines characters.
kubectl-condition() {
    while ! out=$(kubectl get es "$1" --subresource status -ojson 2>&1 \
        | jq 'del(.status.conditions[] | select(.type=="Created"))' 2>&1 \
        | jq '(.status.conditions[]) |= . + {
                "type": "'"$2"'",
                "status": "'"$3"'",
                "reason": "'"$4"'",
                "message": '"$(printf %s "$5" | jq --raw-input --slurp)"'
            }' 2>&1 \
        | kubectl replace es "$1" --subresource status -f- 2>&1); do
        printf "%s: retrying in 1s: failed to set the condition '$2' to '$3' %s\n" "$1" "$(tr $'\n' ' ' <<<"$out")"
        sleep 1
    done
}

printf "info: started watching ExternalSecrets.\n"
kubectl get externalsecret --all-namespaces -ojson --watch | jq -c --unbuffered | while read -r extsec; do
    name=$(jq -r '.metadata.name' <<<"$extsec")
    has_annotation=$(jq -r '.metadata.annotations."create"' <<<"$extsec") # Usual values: "null" or "true".
    condition_status_ready=$(jq -r '.status.conditions[]? | select(.type == "Ready") | .status' <<<"$extsec")
    condition_reason_ready=$(jq -r '.status.conditions[]? | select(.type == "Ready") | .reason' <<<"$extsec")
    condition_reason_created=$(jq -r '.status.conditions[]? | select(.type == "Created") | .status' <<<"$extsec")

    [ -z "$DEBUG" ] || printf "%s: reconciling. (state: HasAnnot=$has_annotation, Ready=$condition_status_ready, Reason=$condition_reason_ready, Created=$condition_reason_created)\n" "$name"
    case "HasAnnot=$has_annotation,Ready=$condition_status_ready,Reason=$condition_reason_ready,Created=$condition_reason_created" in

    HasAnnot=null,*)
        [ -z "$DEBUG" ] || printf "%s: the ExternalSecret does not have the 'create' annotation, skipping.\n" "$name"
        ;;

    HasAnnot=true,Ready=False,Reason=SecretSyncedError,Created=False)
        printf "%s: the ExternalSecret is Ready=False, let us create a random password and put it in Vault.\n" "$name"

        # WARNING: for now, we only support the first value in "data".
        vault_path=$(jq -r '.spec.data[0].remoteRef.key' <<<"$extsec")
        vault_key=$(jq -r '.spec.data[0].remoteRef.property' <<<"$extsec")
        if ! out=$(vault kv put "$vault_path" "$vault_key"="$(openssl rand -hex 32)" 2>&1); then
            printf "%s: vault secret write failed: %s\n" "$name" "$out"
            kubectl-condition "$name" Created False ErrorCreating "While putting the random value: $out"
            continue
        fi

        printf "%s: the Vault secret was created.\n" "$name"
        kubectl-condition "$name" Created True Success "A random value was put into Vault."
        ;;

    HasAnnot=true,Ready=False,Reason=SecretSyncedError,Created=True)
        kubectl-condition "$name" Created False Recreating "The Vault secret previously created cannot be found anymore, it needs to be recreated."
        printf "%s: inconsistency: Created is True but SecretSyncedError is False. Attempting to recreate the secret in Vault to fix this issue.\n" "$name"
        ;;

    # In case the user has given an invalid annotation value, we'll notify
    # the user.
    HasAnnot=*,Ready=False,Reason=SecretSyncedError,Created=*)
        printf "%s: the only valid value for the annotation 'create' is 'true'. Skipping.\n" "$name"
        kubectl-condition "$name" Created False ErrorAnnotation "The only accepted value for the annotation 'create' is 'true'."
        ;;

    # If we previously tried to create the Vault secret, but in the
    # meantime the external-secrets operator managed to find the secret,
    # let's make sure that we set Created=True just to avoid confusion.
    HasAnnot=*,Ready=True,Reason=*,Created=False)
        printf "%s: turning condition 'Created' from False to True since the external-secrets operator found the secret in Vault.\n" "$name"
        kubectl-condition "$name" Created True Exists "The external-secrets operator has found the secret."
        ;;

    # When the ExternalSecret isn't marked as SecretSyncedError, we do nothing.
    *,Ready=*,Reason=*,Created=*)
        [ -z "$DEBUG" ] || printf "%s: doing nothing.\n" "$name"
        ;;
    esac
done

exit 123
