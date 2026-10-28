# SRE / DevOps Lab

A small, interview-ready project for a DevOps or SRE internship.

The goal is not to install more software. The goal is to demonstrate a complete loop:

`code -> CI image build -> GHCR -> Kubernetes deployment -> health checks -> observability -> rollback -> incident notes`

## What is included

- Flask demo API with `/healthz`, `/readyz`, `/metrics`, `/api/orders`
- Failure endpoints for controlled drills: `/simulate/error`, `/simulate/slow`
- Multi-stage Dockerfile running as a non-root user
- Kubernetes Deployment and Service with probes, resource limits and security context
- GitHub Actions workflow that validates the app and publishes an image to GHCR
- `scripts/opsctl.py`, a small operations CLI for inventory, health checks, log collection, deploy and rollback

## Architecture

```text
GitHub Actions
    |
    | build + push
    v
GHCR image
    |
    v
Kubernetes namespace sre-lab
    +-- Deployment demo-api (2 replicas)
    +-- Service demo-api (ClusterIP)
```

The lab cluster uses one control-plane node and one worker node. The worker has about 3.6 GiB RAM, so keep monitoring components small and set resource requests.

## Quick start

1. Create a GitHub repository named `sre-devops-lab`.
2. Push this directory to the repository.
3. The `ci` workflow runs on pull requests and pushes to `main`.
4. On `main`, it publishes:

```text
ghcr.io/<github-owner>/sre-devops-lab:latest
ghcr.io/<github-owner>/sre-devops-lab:<commit-sha>
```

Make the GHCR package public for the simplest lab setup. For a private package, create an image pull secret and reference it in the Deployment.

## Deploy manually

On the master node:

```bash
kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/app.yaml
kubectl -n sre-lab set image deployment/demo-api demo-api=ghcr.io/<github-owner>/sre-devops-lab:<commit-sha>
kubectl -n sre-lab rollout status deployment/demo-api --timeout=120s
kubectl -n sre-lab get pods -o wide
```

Verify inside the cluster:

```bash
kubectl -n sre-lab run curl --rm -it --image=curlimages/curl --restart=Never -- \
  curl -s http://demo-api/healthz
```

If the image cannot be pulled, inspect the pod first:

```bash
kubectl -n sre-lab describe pod <pod-name>
kubectl -n sre-lab get events --sort-by=.lastTimestamp
kubectl -n sre-lab get pod <pod-name> -o yaml
```

## Operations CLI

Copy `scripts/opsctl.py` to the master node or run it from the repository on the master:

```bash
python3 scripts/opsctl.py inventory
python3 scripts/opsctl.py health
python3 scripts/opsctl.py logs <pod-name>
python3 scripts/opsctl.py deploy ghcr.io/<owner>/sre-devops-lab:<sha>
python3 scripts/opsctl.py rollback
```

The CLI exits non-zero when health checks fail, so it can later be used in CI or a cron job.

## Controlled failure drills

Use a disposable lab cluster only.

### Image pull failure

```bash
kubectl -n sre-lab set image deployment/demo-api demo-api=ghcr.io/<owner>/sre-devops-lab:missing-tag
kubectl -n sre-lab get pods -w
kubectl -n sre-lab describe pod <pod-name>
kubectl -n sre-lab rollout undo deployment/demo-api
```

Record: symptom, pod events, hypothesis, command output, fix, verification.

### Application error

```bash
kubectl -n sre-lab port-forward svc/demo-api 8080:80
curl -i http://127.0.0.1:8080/simulate/error
curl -i http://127.0.0.1:8080/simulate/slow
```

### Pod self-healing

```bash
kubectl -n sre-lab delete pod <pod-name>
kubectl -n sre-lab get pods -w
```

## Next milestone

Add Prometheus, Grafana and Alertmanager with a small resource footprint, then create these alerts:

- target down
- 5xx ratio too high
- p95 latency too high
- pod restarts too frequent
- deployment unavailable replicas
- node disk or memory pressure

Do not call it a monitoring system until an alert has actually fired and been investigated.

## Interview talking points

- Why use Deployment instead of a bare Pod
- How readiness differs from liveness
- How the Service finds Pods through labels and selectors
- How rolling updates and `kubectl rollout undo` work
- How GitHub Actions authenticates to GHCR with `GITHUB_TOKEN`
- How to diagnose `ImagePullBackOff` from Pod status, Events and describe output
- Why the image tag uses a commit SHA instead of only `latest`
- What `opsctl.py` automates and what it deliberately does not do

## Security notes

- Never commit registry passwords or kubeconfig files.
- Use a dedicated deploy identity and least privilege.
- Do not expose the Kubernetes API publicly for a lab.
- Use commit SHA tags for reproducible deployments.
- Review AI-generated YAML and scripts before applying them.
