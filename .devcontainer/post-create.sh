#!/bin/bash

## Log start
echo "post-create start" >> ~/.status.log

## Create K3d cluster
k3d cluster create kargo-quickstart | tee -a ~/.status.log

## Update Repo With proper username
bash .devcontainer/scripts/update-repo-for-workshop.sh | tee -a ~/.status.log

## Create GHCR container
bash .devcontainer/scripts/setup-ghcr.sh | tee -a ~/.status.log

## Log things
echo "post-create complete" >> ~/.status.log
echo "--------------------" >> ~/.status.log

##
