## Terraform infrastructure
Terraform folder contains terraform files for creating infrastructure

It creates:
1. GKE cluster with Workload Identity enable and access to Key Vault
2. GCP KMS keyring and crypto keys

Create terraform infrastructure
```sh
cd terraform
terraform init
terraform apply
```

- Connect to created cluster
```sh
gcloud container clusters get-credentials flux-observability --zone us-central1-c --project dx-somtoxhi
```

## Bootstrap Flux

- Bootstrap Flux on created cluster
Note: Talk a bit about bootstrapp while it is 

```sh
export GITHUB_OWNER=somtochiama
export GITHUB_TOKEN=<GITHUB_TOKEN>
flux bootstrap github --owner $GITHUB_OWNER --repository test-demo --path=clusters/my-clusters
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
Push changes 
```sh
gc -m "configure ks" && git push
```

## Create Slack Wenhook URL 
Note: Add providers

- Create Slack Webhook URL and a secret containing URL
Go to [Slack Webhooks](https://api.slack.com/messaging/webhooks).
Note: Pushing the URL to git causes Slack to invalidate the webhook url. So we don't use the Provider's `spec.address`

```
kubectl create secret generic -n flux-system slack-url \
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

## Create Alerts and Provider
```sh
flux create alert flux-system \
--provider-ref slack \
--event-source "GitRepository/*" \
--event-source "OCIRepository/*" \
--event-source "Kustomization/*" \
--event-source "HelmRepository/*" \
--export >> ./clusters/my-clusters/notifications/alert.yaml

flux create alert-provider slack --type slack --secret-ref slack-url --export \
>> ./clusters/my-clusters/notifications/provider.yaml
```

## Deploy app and get notifications
6. Create an app so that the controller can notify about it 
```
flux create source oci podinfo \
  --url=oci://ghcr.io/stefanprodan/manifests/podinfo \
  --tag=6.1.6 \
  --interval=10m --export >> ./clusters/my-clusters/notification/apps.yaml

flux create kustomization podinfo \
  --source=OCIRepository/podinfo \
  --target-namespace=default \
  --prune=true \
  --interval=5m --export >> ./clusters/my-clusters/notification/apps.yaml
```

- Webhook receivers: Get Flux to reconcile immediately we do a git push

Create a LoadBalancer service:
```
apiVersion: v1
kind: Service
metadata:
  name: receiver
  namespace: flux-system
spec:
  type: LoadBalancer
  selector:
    app: notification-controller
  ports:
    - name: http
      port: 80
      protocol: TCP
      targetPort: 9292
```

Generate random token for webhook receiver:
```sh
TOKEN=$(head -c 12 /dev/urandom | shasum | cut -d ' ' -f1)
echo $TOKEN

kubectl -n flux-system create secret generic webhook-token \	
--from-literal=token=$TOKEN --dry-run=client -oyaml >> ./clusters/my-clusters/webhook/secret.yaml
```

Create webhook receiver
```sh
flux create receiver github-receiver \
    --type github \
    --event ping \
    --event push \
    --secret-ref webhook-token \
    --resource GitRepository/flux-system \
    --export >>  ./clusters/my-clusters/webhook/receiver.yaml
```
** Commit and push

Navigate to repository settings and put in payload url + token
Payload URL - `https://<ServiceURL>/hook/bed6d00b5555b1603e1f59b94d7fdbca58089cb5663633fb83f2815dc626d92b
Token - `echo $TOKEN`

## Github Commit Status

Create a Github PAT with repo:status permission

```sh
export GH_PAT_TOKEN=<TOKEN>

kubectl -n flux-system create secret generic github-token \            
--from-literal=token=$GH_PAT_TOKEN --dry-run=client -oyaml > ./clusters/my-clusters/notifications/token.yaml
```

Create Provider
```
flux create alert commit-status --provider-ref github \
--event-source "Kustomization/flux-system" \
--export > ./clusters/my-clusters/notifications/commitstatus.yaml

flux create alert-provider github \
--address https://github.com/somtochiama/test-demo \
--type github --secret-ref github-token --export \
>> ./clusters/my-clusters/notifications/commitstatus.yaml
```

## Kube Prometheus Stack

We have the required YAML files in `infra/monitoring`

We would have slack url in monitoring

```sh
kubectl create secret generic -n flux-system slack-url \
--from-literal=address=$SLACK_URL \
--dry-run=client -oyaml > ./infra/kube-prometheus-stack/secret.yaml
```

Of course, encryption
```
sops --encrypt --in-place infra/kube-prometheus-stack/secret.yaml
```

Create Kustomization for `infra/monitoring`

```sh
flux create kustomization kube-prometheus-stack \
  --interval=1h \
  --prune \
  --source=flux-system \
  --path="./infra/kube-prometheus-stack" \
  --health-check-timeout=5m \
  --decryption-provider=sops \
  --wait --export >> clusters/my-clusters/infra.yaml
```

**git push**

Create `monitoring config`:

```
flux create kustomization flux-config \
--depends-on=kube-prometheus-stack \
--interval=1h \
--prune=true \
--source=flux-system \
--path="./infra/monitoring-config" \
--health-check-timeout=1m \
--wait --export >> ./clusters/my-clusters/infra.yaml
```

Setup Tailscale
1. Create a reusuable key for tailscale

```
kubectl create secret generic tailscale-auth \
--from-literal=AUTH_KEY=$TAILSCALE_KEY \
--dry-run=client -oyaml > ./infra/tailscale/secret.yaml
```

Create Tailscale something
```
flux create kustomization tailscale \
--interval=10m0s \
--prune=true \
--source=flux-system \
--decryption-provider=sops \
--path="./infra/tailscale" \
--wait --export >> ./clusters/my-clusters/infra.yaml
```

## Pixie

Create deploy key
```
export PX_DEPLOY_KEY=$(px deploy-key create)
```

Notes:
- Start with a fresh cluster
- export all needed secret - flux, tailscale, pixie
- Delete key ring from UI in GCP
- cd into terraform before exporting KeyVault


For kind:

gpg --export-secret-keys --armor "${KEY_FP}" |
kubectl create secret generic sops-gpg \
--namespace=flux-system \
--from-file=sops.asc=/dev/stdin
export KEY_FP=22FE5F30631096FFEE7F1E9B40803ABF3FE40332
