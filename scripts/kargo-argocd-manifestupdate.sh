#!/bin/bash
set -e

for stage in $(kargo get stages --project kargo-simple -o jsonpath='{.items[*].metadata.name}')
do
	kargo get stage ${stage} -p kargo-simple -o json | jq ".spec.promotionMechanisms.argoCDAppUpdates[0] += {\"appName\": \"guestbook-simple-${stage}\"}" | kargo apply -f -
done
