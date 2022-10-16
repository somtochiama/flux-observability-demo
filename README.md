Terraform folder contains terraform files for creating infrastructure

- Create terraform infrastructure
```sh
cd terraform
terraform init
terraform apply
```

- Connect to created cluster
```sh
gcloud container clusters get-credentials flux-observability --zone us-central1-c --project dx-somtoxhi
```

- Bootstrap Flux on created cluster
```sh
export GITHUB_OWNER=somtochiama
flux bootstrap github --owner $GITHUB_OWNER --repository flux-observability  --path=clusters/my-clusters
```

- Configure Kustomization to decrypt secrets
Customize Flux manifest and annotate Kustomize controller with the service account
```
patchesStrategicMerge:
- |-
  apiVersion: v1
  kind: ServiceAccount
  metadata:
    name: kustomize-controller
    namespace: flux-system
    annotations:
      iam.gke.io/gcp-service-account: <iam-service-account>@<PROJECT_ID>.iam.gserviceaccount.com
    decryption:
      provider: sops
- |-
  apiVersion: kustomize.toolkit.fluxcd.io/v1beta2
  kind: Kustomization
  metadata:
    name: flux-system
    namespace: flux-system
  spec:
    decryption:
      provider: sops
```

- Create Slack Webhook URL and a secret containing URL
Go to [Slack Webhooks](https://api.slack.com/messaging/webhooks).
Note: Pushing the URL to git causes Slack to invalidate the webhook url. So we don't use the Provider's `spec.address`
```
kubectl create secret generic provider-url \
--from-literal=address=<slack-webhook> \
--dry-run=client -oyaml > ./clusters/my-clusters/notifications/secret.yaml
```

- Create sops configuration yaml for encyption
Export Keyvault URL
```
export KMS_ID=$(terraform output kms_key_id)
```

Create `.sops.yaml` file

```
cat <<EOF > ../../test-demo/.sops.yaml
 creation_rules:
 - path_regex: .*.yaml
   encrypted_regex: ^(data|stringData)$
   gcp_kms: ${KMS_ID}
EOF
```

Encrypt file
```
sops --encrypt --in-place clusters/my-clusters/notifications/secret.yaml
```


TODOS:
- export cluster name and GCP service account name
