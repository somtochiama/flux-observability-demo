variable "name" {
    type = string
    default = "flux-observability"
}

variable "project" {
    type = string
    default = "dx-somtoxhi"
}

variable "service_account_name" {
    type = string
    default = "flux-gitops"
}

variable "namespace" {
    type = string
    default = "flux-system"
}

variable "k8s_serviceaccount" {
    type = string
    default = "kustomize-controller"
}
