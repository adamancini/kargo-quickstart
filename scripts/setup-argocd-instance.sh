#!/bin/bash
set -e  # Exit on non-zero exit code from commands

[[ -z ${AKUITY_API_KEY_ID} ]] || [[ -z ${AKUITY_API_KEY_SECRET} ]] && echo "Please export Akuity API Creds" && exit 13

# Function to get the health status code
get_health_status() {
    akuity argocd instance list -o json | jq -r '.[0].healthStatus.code'
}

ORG_ID=$(akuity org list | awk 'NR==2 {print $1}')
# Set the organization id in the cli config so users don't have to set it.
akuity config set --organization-id=${ORG_ID}
echo "Set the org id to \"${ORG_ID}\"."

# Apply the declarative akuity platform configuration.
echo "Creating an Argo CD instance on the Akuity Platform,"
akuity argocd apply -f akuity/

# Loop until the instance becomes healthly.
echo -n "Waiting for the Argo CD instance to be healthy."
counter=0
while true; do
    [[ ${counter} -ge 5 ]] && echo -e "\nError: Timed out wating for instance" && exit 13
    health_status=$(get_health_status)
    if [ "$health_status" = "STATUS_CODE_HEALTHY" ]; then
        echo -e "\nThe Argo CD instance is healthy!"
        break
    fi
    echo -n "."
    counter=$((counter + 1))
    sleep 30  # Average 90 seconds
done

# Deploy agent to clusters.
echo "Deploying Akuity Agent manifests to local k8s cluster."
akuity argocd cluster get-agent-manifests \
  --instance-name=my-argocd-instance kargo-quickstart | kubectl apply -f -

argocd login \
  "$(akuity argocd instance get my-argocd-instance -o json | jq -r '.id').cd.akuity.cloud" \
  --username admin \
  --password akuity-argocd \
  --grpc-web 
echo "Configured the \"argocd\" cli."

# Trigger refresh since app may get deployed before repo server is up (stuck with ComparisonError).
##jitter
sleep 5
for app in dev staging prod
do
    argocd app get guestbook-simple-${app} --refresh > /dev/null
done

echo "======================="
echo "Argo CD instance setup!"
echo "======================="
