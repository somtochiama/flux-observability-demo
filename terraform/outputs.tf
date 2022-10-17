output "kubeconfig" {
  description = "kubeconfig of the created GKE cluster"
  value       = module.gke_auth.kubeconfig_raw
  sensitive   = true
}

output "kms_key_id" {
  description = "Id for GCP Crypto Keys"
  value = google_kms_crypto_key.sops-key.id
}
