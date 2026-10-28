# GitHub push SOP

Repository: https://github.com/0tinna/sre-devops-lab

Master working copy: `/opt/sre-devops-lab`

Deployment key on master: `/root/.ssh/github_sre_lab_ed25519`

The private key stays on the master node. Only the public key below is safe to paste into GitHub.

## 1. Add the deploy key with write access

1. Open https://github.com/0tinna/sre-devops-lab/settings/keys
2. Click `Add deploy key`.
3. Title: `sre-lab-master`
4. Key:

```text
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINGBoz2mz3enY7/WJwWQ5WdQs3ZwlLQJD2yWdWRKBbXk sre-lab-master
```

5. Check `Allow write access`.
6. Click `Add key`.

If write access is not checked, `git push` will fail with `Permission denied (publickey)` or a read-only error.

## 2. Verify authentication from master

Run on master:

```bash
ssh -i /root/.ssh/github_sre_lab_ed25519 -o IdentitiesOnly=yes -T git@github.com
```

Expected result is similar to:

```text
Hi 0tinna/sre-devops-lab! You've successfully authenticated, but GitHub does not provide shell access.
```

Common failures:

- `Permission denied (publickey)`: the public key was not added, the wrong key was added, or write access is unchecked.
- `Repository not found`: check the repository URL and whether the deploy key belongs to the correct repository.

## 3. Push the first commit

The repository is already initialized, committed and configured on master:

```bash
cd /opt/sre-devops-lab
git status
git push -u origin main
```

Expected result:

```text
branch 'main' set up to track 'origin/main'
```

Do not use `git push --force` if the remote already has commits. Inspect the remote first:

```bash
git ls-remote origin
git log --oneline --decorate -3
```

If the remote has a README commit, use a normal merge or rebase instead of force push.

## 4. Verify GitHub Actions

1. Open https://github.com/0tinna/sre-devops-lab/actions
2. Open the `ci` workflow.
3. Confirm the `validate` job is green.
4. Confirm the `image` job is green after a push to `main`.
5. Confirm the package appears at https://github.com/0tinna?tab=packages

The workflow publishes:

```text
ghcr.io/0tinna/sre-devops-lab:latest
ghcr.io/0tinna/sre-devops-lab:<commit-sha>
```

The `image` job is intentionally skipped for pull requests.

## 5. Make the image pullable by the cluster

For the lab, the simplest option is to make the GHCR package public:

1. Open the package page.
2. Open `Package settings`.
3. Change visibility to `Public`.

For a private package, create an image pull secret instead:

```bash
kubectl -n sre-lab create secret docker-registry ghcr-secret \
  --docker-server=ghcr.io \
  --docker-username=0tinna \
  --docker-password=<PAT-with-read-packages>
```

Then add this to the Deployment pod template:

```yaml
imagePullSecrets:
  - name: ghcr-secret
```

Do not commit the PAT to Git.

## 6. Deploy after the image exists

Run on master:

```bash
cd /opt/sre-devops-lab
kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/app.yaml
kubectl -n sre-lab set image deployment/demo-api \
  demo-api=ghcr.io/0tinna/sre-devops-lab:<commit-sha>
kubectl -n sre-lab rollout status deployment/demo-api --timeout=120s
kubectl -n sre-lab get pods -o wide
```

Verify the service:

```bash
kubectl -n sre-lab port-forward svc/demo-api 8080:80
curl -i http://127.0.0.1:8080/healthz
curl -i http://127.0.0.1:8080/readyz
curl -s http://127.0.0.1:8080/metrics | head
```

## 7. Troubleshooting checklist

### ImagePullBackOff

```bash
kubectl -n sre-lab get pods
kubectl -n sre-lab describe pod <pod-name>
kubectl -n sre-lab get events --sort-by=.lastTimestamp
```

Check image name, tag, package visibility, registry authentication, DNS and network.

### Rollout does not become ready

```bash
kubectl -n sre-lab get deploy demo-api -o yaml
kubectl -n sre-lab get rs
kubectl -n sre-lab describe pod <pod-name>
kubectl -n sre-lab logs deploy/demo-api --tail=100
```

Check readiness probe, resource limits and application startup logs.

### Rollback

```bash
kubectl -n sre-lab rollout undo deployment/demo-api
kubectl -n sre-lab rollout status deployment/demo-api --timeout=120s
```

## 8. Interview explanation

I used a repository-scoped SSH deploy key rather than a personal password. The private key stays on the master node, and the public key is added to GitHub with write access. The first push triggers GitHub Actions, which validates the application and publishes a commit-tagged image to GHCR. The Kubernetes Deployment references the commit SHA, and I verify rollout status, pod health and the metrics endpoint after deployment.
