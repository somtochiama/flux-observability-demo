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
Push changes 
```sh
gc -m "configure ks" && git push
```

- Create Slack Webhook URL and a secret containing URL
Go to [Slack Webhooks](https://api.slack.com/messaging/webhooks).
Note: Pushing the URL to git causes Slack to invalidate the webhook url. So we don't use the Provider's `spec.address`

```
kubectl create secret generic slack-url \
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

- Create Alerts and Provider
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

TODOS:
- export cluster name and GCP service account name

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

flux create alert-provider github --type github --secret-ref github-token --export \
>> ./clusters/my-clusters/notifications/commitstatus.yaml
```
