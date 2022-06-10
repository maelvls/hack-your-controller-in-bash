#!/usr/bin/env bash

set -uo pipefail
# I won't set -x because this is a long-lasting script and I can't afford
# crashes. The flag '-b' silences bash's job control messages.

# For testing purposes, that allows me to run
# ./external-secrets-vault-creator.sh without having to put kubectl-curl in
# my PATH.
export PATH="$PATH:$PWD"

DEBUG="${DEBUG:-}"

SOCK=/tmp/external-secrets-vault-creator-$$.sock
kubectl proxy --unix-socket "$SOCK" >/dev/null &
# I disable the shellcheck SC2064 because $! and $SOCK are immediately
# expanded so that we know which process to kill in the trap.
# shellcheck disable=SC2064
trap "trap - SIGTERM && kill $! && rm -f $SOCK" SIGINT SIGTERM EXIT
while ! curl --unix-socket "$SOCK" --fail http://localhost -o /dev/null >/dev/null 2>&1; do
    sleep 0.01
done

printf "info: started watching ExternalSecrets.\n"

kubectl get externalsecret --all-namespaces -ojson --watch | jq -c --unbuffered | while read -r extsec; do
    annotation_value_print=$(jq -r '.metadata.annotations."external-secrets-vault-creator"' <<<"$extsec") # Usual values: "null" or "hex32".
    condition_status_ready=$(jq -r '.status.conditions[]? | select(.type == "Ready") | .status' <<<"$extsec")
    condition_reason_ready=$(jq -r '.status.conditions[]? | select(.type == "Ready") | .reason' <<<"$extsec")
    condition_reason_created=$(jq -r '.status.conditions[]? | select(.type == "Created") | .status' <<<"$extsec")

    [ -z "$DEBUG" ] || printf "%s: reconciling. (state: Annot=external-secrets-vault-creator:$annotation_value_print, Ready=$condition_status_ready, Reason=$condition_reason_ready, Created=$condition_reason_created)\n" "$(jq -r .metadata.name <<<"$extsec")"
    case "Annot=$annotation_value_print,Ready=$condition_status_ready,Reason=$condition_reason_ready,Created=$condition_reason_created" in

    Annot=null,*)
        printf "%s: the ExternalSecret does not have the 'external-secrets-vault-creator' annotation, skipping.\n" "$(jq -r .metadata.name <<<"$extsec")"
        continue
        ;;

    Annot=hex32,Ready=False,Reason=SecretSyncedError,Created=False)
        printf "%s: the ExternalSecret is Ready=False, let us create a random password and put it in Vault.\n" "$(jq -r .metadata.name <<<"$extsec")"

        # WARNING: for now, we only support the first value in "data".
        vault_path=$(jq -r '.spec.data[0].remoteRef.key' <<<"$extsec")
        vault_key=$(jq -r '.spec.data[0].remoteRef.property' <<<"$extsec")
        if ! out=$(vault kv put "$vault_path" "$vault_key"="$(openssl rand -hex 32)" 2>&1); then
            printf "%s: vault secret write failed: %s\n" "$(jq -r .metadata.name <<<"$extsec")" "$out"
            if ! out2=$(curl --unix-socket "$SOCK" --fail -sS -k -H "Content-Type: application/json-patch+json" \
                -X PATCH http://localhost/apis/external-secrets.io/v1beta1/namespaces/default/externalsecrets/"$(jq -r .metadata.name <<<"$extsec")"/status \
                -d '[{"op": "add", "path": "/status/conditions", "value":[{
                "type": "Created",
                "status": "False",
                "reason": "ErrorCreating",
                "message": "While putting the random value: '"$(tr $'\n' ' ' <<<"$out")"'"
            }]}]' 2>&1); then
                printf "%s: failed to set the 'Created' condition to 'False': %s\n" "$(jq -r .metadata.name <<<"$extsec")" "$(tr $'\n' ' ' <<<"$out2")"
            fi
        fi

        printf "%s: the Vault secret was created.\n" "$(jq -r .metadata.name <<<"$extsec")"

        if ! out=$(curl --unix-socket "$SOCK" --fail -sS -k -H "Content-Type: application/json-patch+json" \
            -X PATCH http://localhost/apis/external-secrets.io/v1beta1/namespaces/default/externalsecrets/"$(jq -r .metadata.name <<<"$extsec")"/status \
            -d '[{"op": "add", "path": "/status/conditions", "value":[{
                "type": "Created",
                "status": "True",
                "reason": "Created",
                "message": "The random value was generated with the mode hex32 and put into Vault."
            }]}]' 2>&1); then
            printf "%s: failed to set the 'Created' condition to 'False': %s\n" "$(jq -r .metadata.name <<<"$extsec")" "$(tr $'\n' ' ' <<<"$out")"
        fi
        ;;

    Annot=hex32,Ready=False,Reason=SecretSyncedError,Created=True)
        vault_path=$(jq -r '.spec.data[0].remoteRef.key' <<<"$extsec")
        vault_key=$(jq -r '.spec.data[0].remoteRef.property' <<<"$extsec")
        if ! vault get "$vault_path/$vault_key" >/dev/null 2>&1; then
            if ! out2=$(curl --unix-socket "$SOCK" --fail -sS -k -H "Content-Type: application/json-patch+json" \
                -X PATCH http://localhost/apis/external-secrets.io/v1beta1/namespaces/default/externalsecrets/"$(jq -r .metadata.name <<<"$extsec")"/status \
                -d '[{"op": "add", "path": "/status/conditions", "value":[{
                "type": "Created",
                "status": "False",
                "reason": "Recreating",
                "message": "The Vault secret previously created cannot be found anymore, it needs to be recreated."
            }]}]' 2>&1); then
                printf "%s: failed to set the 'Created' condition to 'False': %s\n" "$(jq -r .metadata.name <<<"$extsec")" "$(tr $'\n' ' ' <<<"$out2")"
            fi
        fi

        printf "%s: although we already created the secret at some point, it seems.\n" "$(jq -r .metadata.name <<<"$extsec")"
        ;;

    # In case the user has given an invalid annotation value, we'll notify
    # the user.
    Annot=*,Ready=False,Reason=SecretSyncedError,Created=*)
        printf "%s: the only valid value for the annotation 'external-secrets-vault-creator' is 'hex32'. Skipping.\n" "$(jq -r .metadata.name <<<"$extsec")"
        if ! out=$(curl --unix-socket "$SOCK" --fail -sS -k -H "Content-Type: application/json-patch+json" \
            -X PATCH http://localhost/apis/external-secrets.io/v1beta1/namespaces/default/externalsecrets/"$(jq -r .metadata.name <<<"$extsec")"/status \
            -d '[{"op": "add", "path": "/status/conditions", "value":[{
                "type": "Created",
                "status": "False",
                "reason": "ErrorAnnotation",
                "message": "The only accepted value for the external-secrets-vault-creator is hex32."
            }]}]' 2>&1); then
            printf "%s: failed to set the 'Created' condition to 'False': %s\n" "$(jq -r .metadata.name <<<"$extsec")" "$(tr $'\n' ' ' <<<"$out")"
        fi
        continue
        ;;

    # If we previously tried to create the Vault secret, but in the
    # meantime the external-secrets operator managed to find the secret,
    # let's make sure that we set Created=True just to avoid confusion.
    Annot=*,Ready=True,Reason=*,Created=False)
        printf "%s: turning Created=False to Created=True since the external-secrets operator found the secret in Vault.\n" "$(jq -r .metadata.name <<<"$extsec")"
        if ! out=$(curl --unix-socket "$SOCK" --fail -sS -k -H "Content-Type: application/json-patch+json" \
            -X PATCH http://localhost/apis/external-secrets.io/v1beta1/namespaces/default/externalsecrets/"$(jq -r .metadata.name <<<"$extsec")"/status \
            -d '[{"op": "add", "path": "/status/conditions", "value":[{
                "type": "Created",
                "status": "True",
                "reason": "Exists",
                "message": "The external-secrets operator has found the secret."
            }]}]' 2>&1); then
            printf "%s: failed to set the 'Created' condition to 'False': %s\n" "$(jq -r .metadata.name <<<"$extsec")" "$(tr $'\n' ' ' <<<"$out")"
        fi
        continue
        ;;

    # When the ExternalSecret isn't marked as SecretSyncedError, we do nothing.
    *,Ready=*,Reason=*,Created=*)
        [ -z "$DEBUG" ] || printf "%s: doing nothing.\n" "$(jq -r .metadata.name <<<"$extsec")"
        continue
        ;;
    esac
done

exit 123
