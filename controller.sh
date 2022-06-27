#! /bin/bash

kubectl get externalsecret --watch -ojson \
  | jq 'select(.status.conditions[]?.reason == "SecretSyncedError")' --unbuffered \
  | jq '.spec.data[0].remoteRef | "\(.key) \(.property)"' -r --unbuffered \
  | while read key property; do
    vault kv put $key $property=somerandomvalue
  done
