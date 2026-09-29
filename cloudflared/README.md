======

### CLOUDFLARED DEPLOYMENT ###

======

`deployment.yaml` runs `cloudflared` as a Kubernetes Deployment that connects a remotely-managed Cloudflare Tunnel. The pods open outbound connections to the Cloudflare edge and forward inbound tunnel traffic to in-cluster Services. No inbound ports, LoadBalancer, or Ingress are needed on the cluster side.

# WHAT THE MANIFEST CONTAINS

- **Deployment `cloudflared` in namespace `cloudflared`**, with 2 replicas. Each replica is its own connector for the same tunnel, so if one fails the other keeps serving traffic.
- **Rolling update with `maxSurge: 1` / `maxUnavailable: 0`**, so a new connector starts before an old one stops.
- **Preferred pod anti-affinity on `kubernetes.io/hostname`**, which spreads replicas across nodes when it can and still schedules on a single-node cluster.
- **Tunnel token from Secret `cloudflared-tunnel-token` (key `token`)**, passed in as the `TUNNEL_TOKEN` environment variable. The manifest does not create this Secret (see below).
- **Metrics on port 2000 (`--metrics 0.0.0.0:2000`)**, which serves Prometheus metrics at `/metrics` and a readiness endpoint at `/ready`.
- **Liveness probe on `/ready`**. It returns 200 only while the connector has at least one active edge connection, so a pod that has lost all edge connections gets restarted.
- **`--no-autoupdate`**, because the binary should not replace itself inside an immutable container. You update by changing the image tag.
- **Hardened security context**: non-root UID/GID 65532, `RuntimeDefault` seccomp, no privilege escalation, all capabilities dropped, read-only root filesystem, and no service account token mounted.

======

### ENVIRONMENT REQUIREMENTS ###

======

# OUTBOUND INTERNET ACCESS

cloudflared only works if it can reach the Cloudflare edge. By default it tries QUIC over UDP 7844 and falls back to HTTP/2 over TCP 7844. It also needs DNS resolution of Cloudflare's edge hostnames. **A fully airgapped cluster cannot run this workload.** It needs a network segment with approved egress to Cloudflare. Running it also creates an inbound path into the cluster that is controlled from outside the enclave, so it needs its own security and accreditation review before deployment.

# IMAGE SOURCE

The upstream image is `docker.io/cloudflare/cloudflared`. The manifest points to a placeholder internal mirror, `registry.example.internal/cloudflare/cloudflared`, and an example tag. Before deploying:

1. Mirror the image into the approved internal registry through the normal import and scan process.
2. Pin the tag to the specific release that passed review. Optionally pin by digest (`image: <registry>/cloudflare/cloudflared@sha256:<digest>`).
3. Update the `image:` field to match.

The upstream image has not been reviewed against STIG or other hardening baselines as part of this manifest. Treat it like any other third-party image that needs review.

# RUN-AS USER

The manifest sets UID/GID 65532 to match the distroless `nonroot` user in the upstream image. If the mirrored or rebuilt image uses a different user, change `runAsUser` and `runAsGroup` to match. With `runAsNonRoot: true`, the kubelet refuses to start a container that resolves to UID 0.

# READ-ONLY ROOT FILESYSTEM

`readOnlyRootFilesystem: true` assumes that cloudflared, in token mode with `--no-autoupdate`, never writes to its filesystem. That matches the documented token-mode behavior, but it has not been tested against every cloudflared release. If a release fails with a filesystem write error, add an `emptyDir` volume mounted at the path in the error. Do not disable the read-only root.

======

### DEPLOYMENT ###

======

# CREATE THE TUNNEL

In the Cloudflare Zero Trust dashboard, go to Networks > Tunnels and create a tunnel with the "Cloudflared" connector type. Copy the tunnel token it shows. Set the public hostnames and their origin Services (for example `http://my-app.my-namespace.svc.cluster.local:8080`) on the tunnel's Public Hostname tab. With a remotely-managed tunnel, those ingress rules live in Cloudflare, not in this repository.

# CREATE THE NAMESPACE AND TOKEN SECRET

Create the token Secret imperatively, or through the cluster's existing secrets tooling. Do not commit the token to git.

```sh
kubectl create namespace cloudflared
kubectl -n cloudflared create secret generic cloudflared-tunnel-token --from-literal=token='<TUNNEL_TOKEN>'
```

# APPLY THE DEPLOYMENT

```sh
kubectl apply -f deployment.yaml
kubectl -n cloudflared rollout status deployment/cloudflared
```

# CONFIRM THE CONNECTORS ARE UP

```sh
kubectl -n cloudflared get pods -l app.kubernetes.io/name=cloudflared
kubectl -n cloudflared logs deployment/cloudflared | grep -i "registered tunnel connection"
```

The tunnel status in the Cloudflare dashboard should read "Healthy" and list one connector per replica.

======

### OPERATIONS ###

======

# UPGRADING

Mirror the new release, then change the `image:` tag in `deployment.yaml` and re-apply. The rolling update strategy replaces one connector at a time and always keeps at least one live.

# ROTATING THE TOKEN

Rotate the token in the Cloudflare dashboard, update the Secret, then restart the pods so they read the new value. Environment variables sourced from Secrets are only read at container start.

```sh
kubectl -n cloudflared create secret generic cloudflared-tunnel-token --from-literal=token='<NEW_TOKEN>' --dry-run=client -o yaml | kubectl apply -f -
kubectl -n cloudflared rollout restart deployment/cloudflared
```

# SCALING

Change `replicas` to add or remove connectors. All replicas share the same token and tunnel. Cloudflare spreads traffic across the connected replicas.

# METRICS

Port 2000 is named `metrics` on the container. To have Prometheus scrape it, add a Service and a ServiceMonitor (or PodMonitor) that select `app.kubernetes.io/name: cloudflared`. This manifest does not include either one.

# RESOURCE SIZING

The requests (50m CPU, 64Mi memory) and the limit (256Mi memory) are starting values for a low-traffic tunnel, not measured figures. Adjust them based on what the metrics show under real load. There is deliberately no CPU limit, to avoid throttling during traffic spikes.

# NETWORK POLICY

If the namespace enforces default-deny NetworkPolicies, the pods need egress to:

- cluster DNS
- Cloudflare edge on 7844 UDP and TCP
- each origin Service the tunnel routes to

They also need ingress on 2000/TCP from the monitoring namespace if metrics are scraped.

# TROUBLESHOOTING

- **Pods crash-loop with an authentication or token error**: the Secret is missing, the key is not named `token`, or the value has extra whitespace or a trailing newline.
- **Liveness probe fails and pods restart repeatedly**: the pods cannot reach the Cloudflare edge. Check egress firewall rules for 7844 UDP and TCP, and check DNS. If only UDP is blocked, cloudflared falls back to HTTP/2 automatically. You can also force it with `--protocol http2` in `args`, placed before `run`.
- **Tunnel is healthy but requests return 502**: the origin URL set in the Cloudflare dashboard does not resolve or is not reachable from the `cloudflared` namespace. Check the Service DNS name, the port, and any NetworkPolicy on the origin side.
