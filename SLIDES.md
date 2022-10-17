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

---

## Bootstrap Flux

Bootstrap Flux on created cluster

```sh
export GITHUB_OWNER=somtochiama
export GITHUB_TOKEN=<GITHUB_TOKEN>
flux bootstrap github --owner $GITHUB_OWNER --repository flux-observability  --path=clusters/my-clusters
```

---

## Configure Kustomization to decrypt secrets

Customize Flux manifest and annotate Kustomize controller with the service account

```yaml
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

---

## Create Slack Wenhook URL 

1. Create Slack Webhook URL and a secret containing URL

Go to [Slack Webhooks](https://api.slack.com/messaging/webhooks).
https://testflux.slack.com/services/B041D3SPU2W

Note: Pushing the URL to git causes Slack to invalidate the webhook url. So we don't use the Provider's `spec.address`

```
kubectl create secret generic slack-url \
--from-literal=address=<slack-webhook> \
--dry-run=client -oyaml > ./clusters/my-clusters/notifications/secret.yaml
```

2. Create sops configuration yaml for encyption

Export Keyvault URL
```
export KMS_ID=$(terraform output kms_key_id)
```

3. Create `.sops.yaml` file

```
cat <<EOF > ../../test-demo/.sops.yaml
 creation_rules:
 - path_regex: .*.yaml
   encrypted_regex: ^(data|stringData)$
   gcp_kms: ${KMS_ID}
EOF
```

4. Encrypt file
```
sops --encrypt --in-place clusters/my-clusters/notifications/secret.yaml
```

---

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

**git push!** 

---

## Deploy app and get notifications

Create an app so that the controller can notify about it 

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

---

## Webhook receivers

Get Flux to reconcile immediately we do a git push

1. Create a LoadBalancer service:
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
```

Create a secret with the token and encrypt it (Always encrypt your secrets before pushing to git!)
```sh
kubectl -n flux-system create secret generic webhook-token \	
--from-literal=token=$TOKEN --dry-run=client -oyaml >> ./clusters/my-clusters/webhook/secret.yaml
```

---

## Create webhook receiver yaml

```sh
flux create receiver github-receiver \
    --type github \
    --event ping \
    --event push \
    --secret-ref webhook-token \
    --resource GitRepository/flux-system \
    --export >>  ./clusters/my-clusters/webhook/receiver.yaml
```
**Commit and push!**


Navigate to Github repository Webhook settings and put in payload url + token

Payload URL - `https://<ServiceURL>/<receiver-url>
Token - `echo $TOKEN`

---

## Github Commit Status

Create a Github PAT with repo:status permission

```sh
export GH_PAT_TOKEN=<TOKEN>

kubectl -n flux-system create secret generic github-token \            
--from-literal=token=$GH_PAT_TOKEN --dry-run=client -oyaml > ./clusters/my-clusters/notifications/token.yaml

sops --encrypt --in-place clusters/my-clusters/notifications/token.yaml
```

---

## Create Alert and Github Provider
```
flux create alert commit-status --provider-ref github \
--event-source "Kustomization/flux-system" \
--export > ./clusters/my-clusters/notifications/commitstatus.yaml

flux create alert-provider github \
--address https://github.com/somtochiama/test-demo \
--type github --secret-ref github-token --export \
>> ./clusters/my-clusters/notifications/commitstatus.yaml
```

**commit and push!**
**check github for the status check**

---

## Kube Prometheus Stack

We have the required YAML files in `infra/monitoring`

Create Kustomization for `infra/monitoring`

```
flux create kustomization kube-prometheus-stack \
  --interval=1h \
  --prune \
  --source=flux-system \
  --path="./infra/kube-prometheus-stack" \
  --health-check-timeout=5m \
  --decryption-provider=sops \
  --wait --export >> clusters/my-clusters/infra.yaml
```

---

Create `monitoring config`:

```
flux create kustomization monitoring-config \
--depends-on=kube-prometheus-stack \
--interval=1h \
--prune=true \
--source=flux-system \
--path="./infra/monitoring-config" \
--health-check-timeout=1m \
--wait --export >> ./clusters/my-clusters/infra.yaml
```

**Check all pods are running!**

---

## Setup Tailscale Subnet router

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

Install Pixie
```
flux create kustomization tailscale \
--interval=10m0s \
--prune=true \
--source=flux-system \
--decryption-provider=sops \
--path="./infra/tailscale" \
--wait --export >> ./clusters/my-clusters/infra.yaml
```
