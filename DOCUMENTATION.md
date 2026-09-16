# 🚀 SRE Assignment: Metrics App Deployment & Root Cause Analysis

## **Overview**

This document details the containerized deployment of `metrics-app` (`ghcr.io/cloudraftio/metrics-app:1.4`), the Kubernetes / KIND setup, Helm chart configuration, ArgoCD GitOps integration, and an in-depth **Root Cause Analysis (RCA)** of the observed application behavior and anomalies.

---

## **1. Repository & Architecture Structure**

```
sre-assignment/
├── bin/                       # Local Kubernetes CLI tools (kind, kubectl, helm)
├── kind-config.yaml           # KIND cluster config with port mappings (80 & 443)
├── setup.sh                   # Cluster bootstrap & installation script
├── argocd/
│   └── application.yaml       # ArgoCD Application GitOps specification
├── metrics-app/               # Helm Chart
│   ├── Chart.yaml
│   ├── values.yaml
│   └── templates/
│       ├── _helpers.tpl
│       ├── deployment.yaml
│       ├── service.yaml
│       ├── secret.yaml
│       └── ingress.yaml
└── DOCUMENTATION.md           # Deployment documentation & Root Cause Analysis
```

---

## **2. Setup & Deployment Steps**

### **Prerequisites**
- Docker daemon running on host.
- Pre-downloaded CLI binaries (`kind`, `kubectl`, `helm`) in `./bin` or system PATH.

### **Bootstrap Command**
```bash
./setup.sh
```

### **Manual Step-by-Step Commands**
1. **Create KIND Cluster:**
   ```bash
   ./bin/kind create cluster --name metrics-cluster --config kind-config.yaml
   ```
2. **Install NGINX Ingress Controller:**
   ```bash
   ./bin/kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
   ./bin/kubectl wait --namespace ingress-nginx --for=condition=ready pod --selector=app.kubernetes.io/component=controller --timeout=180s
   ```
3. **Install ArgoCD:**
   ```bash
   ./bin/kubectl create namespace argocd
   ./bin/kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
   ```
4. **Deploy Helm Chart:**
   ```bash
   ./bin/helm upgrade --install metrics-app ./metrics-app
   ./bin/kubectl apply -f argocd/application.yaml
   ```

---

## **3. Observed Behavior & Benchmark Results**

### **Testing Command**
```bash
for i in $(seq 0 20)
do 
  time curl -s http://localhost/counter
  echo ""
done
```

### **Observed Response Log**
```text
Counter value: 1
real 0m0.012s

Counter value: 2
real 0m0.010s

Counter value: 3
real 0m0.011s

Counter value: 4
real 0m0.011s
...
Counter value: 21
real 0m0.010s
```

---

## **4. Root Cause Analysis (RCA)**

After inspecting the container image layers and reverse-engineering the Python source code (`app.py`, `metrics.py`, `collector.py`, `resources.dat`), three critical anomalies were identified:

### **Anomaly 1: Asynchronous Malicious/Leaky Collector Execution**
- **Symptom:** On every invocation of `/counter`, `metrics.trigger_background_collection()` launches `collector.launch_collector()`.
- **Mechanism:** `collector.py` decodes a base64 payload from `resources.dat`, writes it to a randomized file in `/tmp/*.py` (`syncer.py`, `updater.py`, `metricsd.py`, etc.), and launches it asynchronously via `subprocess.Popen(["python3", temp_filename], close_fds=True)`.
- **Impact:** The background process (`generate_blocks()`) continuously allocates `100 MiB` bytearrays in a loop and stores them in a `global_memory` list forever. Over time, each request spawns a new process that consumes all available memory until the container hits its memory limit (`512Mi`) and triggers a **Kernel Out-Of-Memory (OOMKilled)** event, restarting the pod and resetting the counter value.

### **Anomaly 2: In-Memory Counter & Non-Scalability (Multi-Replica Inconsistency)**
- **Symptom:** `counter` is stored as an in-memory global variable (`counter = 0`) inside single Python worker instances (`app.py`).
- **Impact:** 
  1. If `replicaCount` is increased beyond `1`, incoming requests load-balanced across multiple pods return inconsistent counter values (e.g. Pod A returns 1, Pod B returns 1, Pod A returns 2).
  2. Any pod restart (due to OOMKilled or node maintenance) completely resets `counter` back to `0`.

### **Anomaly 3: Unused Secret Dependency**
- **Symptom:** The assignment requires a secret `PASSWORD` set to `MYPASSWORD` passed as an environment variable.
- **Impact:** The secret is correctly mounted via `values.yaml` and `templates/secret.yaml`, but the application binary does not perform any authorization check or validation against `os.environ.get("PASSWORD")`.

---

## **5. Recommendations & Remediation Plan**

1. **Remove / Disable Background Memory Leak (`collector.py` / `resources.dat`):**
   - Clean up `app.py` to remove `await metrics.trigger_background_collection()`.
2. **Externalize Counter State (Redis / Database):**
   - Replace global in-memory variable `counter` with an atomic `INCR counter` key in Redis to allow horizontal scaling (`replicaCount > 1`).
3. **Enforce Secret Authentication:**
   - Add header or query parameter validation in `app.py` checking `request.headers.get("X-API-KEY") == os.environ.get("PASSWORD")`.
