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

export KMS_ID=$(terraform output kms_key_id)
```

- Connect to created cluster
```sh
gcloud container clusters get-credentials flux-observability-two --zone us-central1-c --project dx-somtoxhi
```

---

## Bootstrap Flux

Bootstrap Flux on created cluster

```sh
export GITHUB_OWNER=somtochiama
export GITHUB_TOKEN=<GITHUB_TOKEN>
flux bootstrap github --owner $GITHUB_OWNER --repository flux-observability-demo  --path=clusters
```

Pull the most recent commit
```
git pull
```

---

## Configure Kustomization to decrypt secrets

Customize Flux manifest and annotate Kustomize controller with the service account by editing
the `kustomization.yaml`.

```yaml
patchesStrategicMerge:
- |-
  apiVersion: v1
  kind: ServiceAccount
  metadata:
    name: kustomize-controller
    namespace: flux-system
    annotations:
      iam.gke.io/gcp-service-account: flux-gitops@dx-somtoxhi.iam.gserviceaccount.com
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
[Test Flux channel](https://testflux.slack.com/services/B041D3SPU2W).

Note: Pushing the URL to git causes Slack to invalidate the webhook url. So we don't use the Provider's `spec.address`

```
mkdir -p ./clusters/notifications

kubectl create secret generic -n flux-system slack-url \
--from-literal=address=$SLACK_URL \
--dry-run=client -oyaml > ./clusters/notifications/secret.yaml
```

2. Create sops configuration yaml for encyption

```sh
cat <<EOF > .sops.yaml
 creation_rules:
 - path_regex: .*.yaml
   encrypted_regex: ^(data|stringData)$
   gcp_kms: ${KMS_ID}
EOF
```

4. Encrypt file
```sh
sops --encrypt --in-place clusters/notifications/secret.yaml
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

```sh
flux create source oci podinfo \
  --url=oci://ghcr.io/stefanprodan/manifests/podinfo \
  --tag=6.1.6 \
  --interval=10m --export > ./clusters/apps.yaml

flux create kustomization podinfo \
  --source=OCIRepository/podinfo \
  --target-namespace=default \
  --prune=true \
  --interval=5m --export >> ./clusters/apps.yaml
```

---

## Webhook receivers

Get Flux to reconcile immediately we do a git push

Create a LoadBalancer service:

```sh
mkdir -p ./clusters/my-clusters/webhook
```

Create LoadBalancer Service:

```sh
cat <<EOF > ./clusters/my-clusters/webhook/service.yaml
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
EOF
```

- Generate random token for webhook receiver:

```sh
TOKEN=$(head -c 12 /dev/urandom | shasum | cut -d ' ' -f1)
echo $TOKEN
```

Create a secret with the token and encrypt it (Always encrypt your secrets before pushing to git!)
```sh
kubectl -n flux-system create secret generic webhook-token \
--from-literal=token=$TOKEN --dry-run=client -oyaml > ./clusters/my-clusters/webhook/secret.yaml
```

We always encrypt our secrets!
```sh
sops --encrypt --in-place clusters/my-clusters/webhook/secret.yaml
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


Navigate to Github repository [Webhook settings](https://github.com/somtochiama/test-demo/settings/hooks) and put in payload url + token


Payload URL - `http://34.67.111.197/hook/20ec8773b05f33154fb7ff9d84bc076268d7f547321768ae5ade1d673b16c247
4d31bba5563aecaedacab1cac65a6efab27d4583
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

The prometheus-operator works with CRDS

(Tutorial Link)[https://github.com/prometheus-operator/prometheus-operator/blob/main/Documentation/user-guides/getting-started.md#related-resources]

We have the required YAML files in `infra/monitoring`

We would have slack url in monitoring

```sh
kubectl create secret generic -n monitoring slack-url \
--from-literal=address=$SLACK_URL \
--dry-run=client -oyaml > ./infra/kube-prometheus-stack/secret.yaml
```

Of course, encryption
```sh
sops --encrypt --in-place infra/kube-prometheus-stack/secret.yaml
```

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
kubectl create secret generic -n monitoring slack-url \
--from-literal=address=$SLACK_URL \
--dry-run=client -oyaml > ./infra/monitoring-config/secret.yaml
```

Encrypt!
```
sops --encrypt --in-place infra/monitoring-config/secret.yaml
```

---


```sh
flux create kustomization flux-config \
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
kubectl create secret generic -n tailscale tailscale-auth \
--from-literal=AUTH_KEY=$TAILSCALE_KEY \
--dry-run=client -oyaml > ./infra/tailscale/secret.yaml
```

Encrypt!
```
sops --encrypt --in-place infra/tailscale/secret.yaml
```

Install Tailscale
```
flux create kustomization tailscale \
--interval=10m0s \
--prune=true \
--source=flux-system \
--decryption-provider=sops \
--path="./infra/tailscale" \
--wait --export >> ./clusters/my-clusters/infra.yaml
```

---

[Login](https://login.tailscale.com/admin/machines) to your tailscale dashboard and approve routes.

Access prometheus and grafana with their cluster url
http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090

---

## Pixie

Create deploy key
```sh
export PX_DEPLOY_KEY=$(px deploy-key create)

kubectl create secret generic -n pl px-deploy-key \
--from-literal=DEPLOY_KEY=$PX_DEPLOY_KEY \
--dry-run=client -oyaml > ./infra/pixie/secret.yaml
```

Encrypt!
```
sops --encrypt --in-place infra/pixie/secret.yaml
```

---

## Install Pixie

```sh
flux create kustomization pixie \
--interval=10m0s \
--prune=true \
--source=flux-system \
--decryption-provider=sops \
--path="./infra/pixie" \
--wait --export >> ./clusters/my-clusters/infra.yaml
```

---

## Visualize data from Pixie

Use Pixie [community cloud](https://work2.withpixie.ai).
You can also use the self-hosted version or the Pixie grafana plugin if you don't want to use the hosted version.
