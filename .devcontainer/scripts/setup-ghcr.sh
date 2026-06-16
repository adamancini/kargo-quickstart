#!/bin/bash

## Exit here, maybe possible in the future
echo "GHCR setup not currently possible"
exit 0

## Login to ghcr
echo ${GITHUB_TOKEN} | docker login --username ${GITHUB_USER} --password-stdin ghcr.io

## This will create the image repo on GHCR
docker buildx imagetools create \
    ghcr.io/akuity/guestbook:latest \
    -t ghcr.io/${GITHUB_USER}/guestbook:v0.0.1

## Exit
exit 0

##
##
