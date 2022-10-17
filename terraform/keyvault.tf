resource "google_kms_key_ring" "keyring" {
  name     = "sops-demos"
  location = "global"
}

resource "google_kms_crypto_key" "sops-key" {
  name            = "sops-demo-key"
  key_ring        = google_kms_key_ring.keyring.id
  rotation_period = "100000s"
}
