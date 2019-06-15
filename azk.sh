#!/bin/sh

if [ "$#" -ne 2 ]; then
    echo "usage: $0 SUBSCRIPTION NAME" >&2
    exit 1
fi

SUBSCRIPTION="${1}"
NAME="${2}"

LOCATION="westeurope"

CREATOR="$(az account show --query "user.name" | tr -d '"')"
if [ -z "${CREATOR}" ]; then
    echo "Could not get user!" >&2
    exit 1
fi

TAGS="Creator=${CREATOR}"

echo "Creating RG ${NAME} ..."
az group create --subscription "${SUBSCRIPTION}" --tags "${TAGS}" --location "${LOCATION}" --name "${NAME}" >/dev/null || exit 1

echo "Creating SP ..."
APP_ID="$(az ad sp create-for-rbac --skip-assignment -n "${NAME}" --query appId | tr -d '"')"
APP_PASSWORD="$(az ad sp credential reset -n "${APP_ID}" --years 50 --query password | tr -d '"')"
sleep 60
echo "Created SP: ${APP_ID}"

az aks create --subscription "${SUBSCRIPTION}" --name "${NAME}" --location "${LOCATION}" --resource-group "${NAME}" \
    --service-principal "${APP_ID}" --client-secret "${APP_PASSWORD}" --tags "${TAGS}" >/dev/null || exit 1
