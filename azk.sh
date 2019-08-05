#!/bin/sh

main() {
    if [ "${1}" = "list" ]; then
        if [ "${#}" -eq 1 ]; then
            list
        else
            fatal "usage: ${0} list"
        fi
    elif [ "${1}" = "create" ]; then
        if [ "${#}" -eq 2 ] || [ "${#}" -eq 3 ]; then
            create "${2}" "${3}"
        else
            fatal "usage: ${0} create <config.json> [--confirm]"
        fi
    elif [ "${1}" = "delete" ]; then
        if [ "${#}" -eq 2 ]; then
            delete "${2}"
        else
            fatal "usage: ${0} delete <name>"
        fi
    elif [ "${1}" = "setup-aad" ]; then
        if [ "${#}" -eq 3 ]; then
            setup_aad "${2}" "${3}"
        else
            fatal "usage: ${0} setup-aad <server-name> <client-name>"
        fi
    else
        fatal "usage: ${0} [-h] <command> [<args>]"
    fi
}

list() {
    ACCOUNT="$(az account show)"
    SUBSCRIPTION_NAME="$(echo "${ACCOUNT}" | jq -r .name)"
    SUBSCRIPTION_ID="$(echo "${ACCOUNT}" | jq -r .id)"

    echo "${SUBSCRIPTION_NAME} (${SUBSCRIPTION_ID})"

    az aks list | jq -r .[].name
}

create() {
    read_config "${1}"

    check_az_extension "aks-preview"

    echo "Subscription: ${SUBSCRIPTION}"
    echo "Name: ${AKS_NAME}"
    echo "Node resource group: ${AKSRES_NAME}"
    echo "VM size: ${VM_SIZE}"
    echo "VM count: ${VM_COUNT}"

    if [ "${2}" != "--confirm" ]; then
        echo "Not creating cluster unless --confirm given"
        exit 0
    fi

    set_tags

    if ! resource_group_exists "${AKS_NAME}"; then
        create_resource_group "${AKS_NAME}"
    fi

    if ! aks_exists "${AKS_NAME}"; then
        if ! sp_exists "${AKS_NAME}"; then
            create_sp "${AKS_NAME}"
        fi

        reset_sp_password "${APP_ID}"

        create_aks
    fi

    set_resource_group_tags "${AKSRES_NAME}"

    if [ -n "${AAD_GROUP_ID}" ]; then
        apply_clusterrolebinding "${AAD_GROUP_ID}"
    fi

    info "Successfully created AKS cluster: ${AKS_NAME}"
}

delete() {
    AKS_NAME="${1}"

    SUBSCRIPTION="$(az account show | jq -r .id)"

    if aks_exists "${AKS_NAME}"; then
        delete_aks "${AKS_NAME}"
    fi

    if resource_group_exists "${AKS_NAME}"; then
        delete_resource_group "${AKS_NAME}"
    fi

    if sp_exists "${AKS_NAME}"; then
        delete_sp "${APP_ID}"
    fi

    info "AKS cluster has been deleted: ${AKS_NAME}"
}

setup_aad() {
    serverName="${1}"
    clientName="${2}"

    info "Creating app ${serverName} ..."

    serverApplicationId=$(az ad app create \
        --display-name "${serverName}" \
        --query appId -o tsv) || fatal "Could not create server app!"

    az ad app update --id "${serverApplicationId}" \
        --set groupMembershipClaims=All >/dev/null ||
        fatal "Could not update app!"

    az ad sp create --id "${serverApplicationId}" >/dev/null ||
        fatal "Could not create SP!"

    serverApplicationSecret=$(az ad sp credential reset \
        --name "${serverApplicationId}" \
        --credential-description "AKS" \
        --query password -o tsv) || fatal "Could not reset credentials"

    az ad app permission add \
        --id "${serverApplicationId}" \
        --api 00000003-0000-0000-c000-000000000000 \
        --api-permissions \
        e1fe6dd8-ba31-4d61-89e7-88639da4683d=Scope \
        06da0dbc-49e2-44d2-8312-53f166ab848a=Scope \
        7ab1d382-f21e-4acd-a863-ba3e13f7da61=Role >/dev/null ||
        fatal "Could not add permissions!"

    sleep 10

    az ad app permission grant --id "${serverApplicationId}" \
        --api 00000003-0000-0000-c000-000000000000 >/dev/null ||
        fatal "Could not grant permissions"

    sleep 10

    az ad app permission admin-consent --id "${serverApplicationId}" \
        >/dev/null || fatal "Could not consent to permissions"

    info "Creating app ${clientName} ..."

    clientApplicationId=$(az ad app create \
        --display-name "${clientName}" \
        --native-app \
        --query appId -o tsv) || fatal "Could not create client app!"

    az ad sp create --id "${clientApplicationId}" >/dev/null ||
        fatal "Could not create SP"

    oAuthPermissionId=$(az ad app show --id "${serverApplicationId}" \
        --query "oauth2Permissions[0].id" -o tsv) ||
        fatal "Could not get permission ID"

    az ad app permission add --id "${clientApplicationId}" \
        --api "${serverApplicationId}" \
        --api-permissions "${oAuthPermissionId}=Scope" >/dev/null ||
        fatal "Could not add permissions"

    az ad app permission grant --id "${clientApplicationId}" \
        --api "${serverApplicationId}" >/dev/null ||
        fatal "Could not grant permissions"

    info "App registrations created successfully!"
    info "Server: ${serverName} (${serverApplicationId})"
    info "Secret: ${serverApplicationSecret}"
    info "Client: ${clientName} (${clientApplicationId})"
}

read_config() {
    if ! CONFIG="$(cat "${1}")"; then
        fatal "Could not read configuration file: ${1}"
    fi

    AKS_NAME="$(get_config "name" "")"
    if [ -z "${AKS_NAME}" ]; then
        fatal "Invalid configuration file: Missing field 'name'"
    fi

    SUBSCRIPTION="$(get_config "subscription" "")"
    if [ -z "${SUBSCRIPTION}" ]; then
        SUBSCRIPTION="$(az account show | jq -r .id)"
    fi

    AKSRES_NAME="$(get_config "nodeResourceGroup" "${AKS_NAME}-res")"
    LOCATION="$(get_config "location" "westeurope")"

    VM_SIZE="$(get_config "vmSize" "Standard_DS2_v2")"
    VM_COUNT="$(get_config "vmCount" "3")"

    AAD_TENANT_ID="$(get_config "aadTenantId" "")"
    AAD_SERVER_APP_ID="$(get_config "aadServerAppId" "")"
    AAD_SERVER_APP_SECRET="$(get_config "aadServerAppSecret" "")"
    AAD_CLIENT_APP_ID="$(get_config "aadClientAppId" "")"
    AAD_GROUP_ID="$(get_config "aadGroupId" "")"
}

get_config() {
    FIELD="${1}"
    DEFAULT="${2}"
    if ! VALUE="$(echo "${CONFIG}" | jq -r ".${FIELD} // empty")"; then
        fatal "Could not read field: ${FIELD}"
    fi
    if [ -n "${VALUE}" ]; then
        echo "${VALUE}"
    else
        echo "${DEFAULT}"
    fi
}

set_tags() {
    CURRENT_USER="$(az account show | jq -r .user.name)"
    if [ -z "${CURRENT_USER}" ]; then
        fatal "Could not get current user!"
    fi
    TAGS="Creator=${CURRENT_USER}"
}

check_az_extension() {
    if ! az extension list | grep -q "${1}"; then
        fatal "Extension ${1} is not installed!"
    fi
}

resource_group_exists() {
    az group exists --subscription "${SUBSCRIPTION}" -n "${1}" | grep -q "true"
}

create_resource_group() {
    info "Creating group ${1} ..."
    az group create --subscription "${SUBSCRIPTION}" --tags "${TAGS}" \
        --location "${LOCATION}" --name "${1}" >/dev/null ||
        fatal "Could not create group!"
}

delete_resource_group() {
    info "Deleting group ${1} ..."
    az group delete --yes --subscription "${SUBSCRIPTION}" \
        --name "${1}" >/dev/null ||
        fatal "Could not delete group!"
}

set_resource_group_tags() {
    az group update --subscription "${SUBSCRIPTION}" -n "${1}" \
        --tags "${TAGS}" >/dev/null ||
        fatal "Could not set tags!"
}

sp_exists() {
    APP_ID="$(az ad sp list --filter "DisplayName eq '${1}'" --query "[0].appId" | tr -d '"')"
    echo "${APP_ID}" | grep -q "."
}

create_sp() {
    info "Creating service principal ${1} ..."
    if ! APP_ID="$(az ad sp create-for-rbac --skip-assignment -n "${1}" | jq -r .appId)"; then
        fatal "Could not create service principal!"
    fi
}

reset_sp_password() {
    info "Resetting service principal password for ${1} ..."
    if ! APP_PASSWORD="$(az ad sp credential reset -n "${1}" \
        --end-date 2099-12-31 --query 'password' | tr -d '"')"; then
        fatal "Could not reset password!"
    fi
    sleep 60
}

delete_sp() {
    info "Deleting service principal ${1} ..."
    az ad sp delete --id "${1}" >/dev/null ||
        fatal "Could not delete service principal!"
}

aks_exists() {
    az aks show --subscription "${SUBSCRIPTION}" \
        --resource-group "${1}" --name "${1}" -o none 2>/dev/null
}

create_aks() {
    info "Creating AKS cluster ${AKS_NAME} ..."
    az aks create --verbose \
        --name "${AKS_NAME}" \
        --subscription "${SUBSCRIPTION}" \
        --location "${LOCATION}" \
        --resource-group "${AKS_NAME}" \
        --node-resource-group "${AKSRES_NAME}" \
        --service-principal "${APP_ID}" \
        --client-secret "${APP_PASSWORD}" \
        --aad-tenant-id "${AAD_TENANT_ID}" \
        --aad-server-app-id "${AAD_SERVER_APP_ID}" \
        --aad-server-app-secret "${AAD_SERVER_APP_SECRET}" \
        --aad-client-app-id "${AAD_CLIENT_APP_ID}" \
        --node-vm-size "${VM_SIZE}" \
        --node-count "${VM_COUNT}" \
        --tags "${TAGS}" \
        --no-ssh-key >/dev/null ||
        fatal "Could not create AKS cluster!"
}

delete_aks() {
    info "Deleting AKS cluster ${1} ..."
    az aks delete \
        --name "${1}" \
        --subscription "${SUBSCRIPTION}" \
        --resource-group "${1}" ||
        fatal "Could not delete AKS cluster!"
}

apply_clusterrolebinding() {
    KUBECONFIG_FILE=".kubeconfig-$(date +%Y%m%d%H%M%S).json"
    az aks get-credentials \
        --subscription "${SUBSCRIPTION}" \
        --resource-group "${AKS_NAME}" \
        --name "${AKS_NAME}" \
        --path "${KUBECONFIG_FILE}" --admin
    echo "apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: aad-default-group-cluster-admin-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- apiGroup: rbac.authorization.k8s.io
  kind: Group
  name: $1" | kubectl --kubeconfig "${KUBECONFIG_FILE}" apply -f -
    rm -f "${KUBECONFIG_FILE}"
}

info() {
    echo "$@" >&2
}

fatal() {
    echo "$@" >&2
    exit 1
}

main "$@"
