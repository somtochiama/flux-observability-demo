## Flux + Observability

This repository contains manifests for Flux + other monitoring solutions such as kube-prometheus-stack and Pixie. It also installs tailscale for a little magic to connect to the services running on your cluster without exposing them.

Repository structure
```sh
.
├── clusters #flux is bootstap to this cluster
│   └── my-clusters
│       ├── flux-system
│       ├── notifications
│       └── webhook
├── infra # yamls for installing infra
│   ├── kube-prometheus-stack # install prom-operator and grafana
│   ├── monitoring-config # CRs and config maps for prom-operator and grafana
│   ├── pixie # pixie uses ebpf for monitoring
│   └── tailscale # subnet-router to access services in cluster with their cluster IPs
└── terraform # Terraform files for spinning up GKE infra
```

This repository is the demo for the Kubecon NA 2022 talk:
```
Flux + Observability: Featuring different tools such as  kube-prometheus-stack and Pix
```

You create this repository by following the instructures in SLIDES.md which serves as secondary slides for the demo.
