# 🏥 CuraCloud | Patient Management Microservices

## 📖 Overview

CuraCloud is a state-of-the-art containerized patient management microservices suite designed to simulate a production-grade distributed system. The architecture revolves around resilient inter-service communication using synchronous gRPC calls and asynchronous event-driven messaging via Apache Kafka. 

The application is fully integrated with a Kubernetes (Kind) cluster and equipped with Istio Service Mesh to enforce robust mTLS, advanced traffic routing, and cluster-wide observability via the Kiali dashboard.

## 🚀 Key Features
*   **Microservices Suite:** Modular design splitting concerns into `patient-service`, `auth-service`, `billing-service`, `analytics-service`, and `api-gateway`.
*   **API Gateway & Security:** Spring Cloud API Gateway with custom JWT validation filters that securely route authenticated traffic while isolating internal services.
*   **Resilient Communication:**
    *   **gRPC:** Used for synchronous, low-latency cross-service operations (e.g., fast, real-time billing operations).
    *   **Apache Kafka:** Powers asynchronous, event-driven data streaming (e.g., patient data analytics processing).
*   **Istio Service Mesh Setup (Multi-cluster ready):** 
    *   Implements fine-grained traffic routing, telemetry, and distributed tracing.
    *   Secures internal traffic with zero-trust mTLS.
    *   *Includes scripts to recover cross-cluster network setups post-reboot.*
*   **Advanced Observability:** Comprehensive insight into network topology, latency, and service health using the **Kiali Dashboard**, alongside Prometheus/Grafana integrations.
*   **Kubernetes-Native Infrastructure:** Utilizes Deployments, NodePort Services, ConfigMaps, and PersistentVolumes for stateless apps and stateful data stores (PostgreSQL, Zookeeper) reliably.

## 🛠️ Technology Stack
*   **Backend:** Java, Spring Boot 3.x, gRPC
*   **Message Broker:** Apache Kafka (with Zookeeper)
*   **Database:** PostgreSQL
*   **Containerization & Orchestration:** Docker, Kubernetes (Kind)
*   **Service Mesh & Observability:** Istio, Kiali, Prometheus, Jaeger, Grafana

---

## 🏗️ Architecture

1.  **Patient Service:** Manages patient records and operations.
2.  **Auth Service:** Handles user authentication and generates JWTs.
3.  **Billing Service:** Submits and calculates billing info securely using gRPC.
4.  **Analytics Service:** Consumes Kafka streams for patient health analytics.
5.  **API Gateway:** Secure edge proxy handling JWT checks and traffic routing.

---

## 🐳 Kubernetes (Kind) Deployment & Service Mesh Validation

The core focus of this deployment is modeling a real-world multi-node or multi-cluster architecture using **Kind** (Kubernetes in Docker). The integration with **Istio Service Mesh** enables zero-downtime deployments, canary rollouts, strict mTLS security policies, and network-level observability.

### Prerequisites
- Docker & Docker Compose
- `kind` CLI
- `kubectl` configured
- `istioctl` installed

### 1. Spinning up the Kind Clusters
The project defines configurations for kind clusters. You can deploy them utilizing the provided setup scripts inside `k8s/kind/`:

```bash
cd k8s/kind/
# Example cluster setup scripts depending on topology requirements
./create-kind-cluster.sh
```

*(Note: There are specific configurations located at `kind-cluster1-config.yaml` and `kind-cluster2-config.yaml` for advanced multi-cluster setups.)*

### 2. Deploying Services & Data Stores
Deploy the database, message broker, and microservices via Kubernetes manifests located in the `k8s/manifest/` directory:

```bash
kubectl apply -f k8s/manifest/
```

This commands sets up your ConfigMaps, PersistentVolumes, Deployments, and Services infrastructure.

### 3. Istio Service Mesh Setup
Apply the Istio topology and patch for mesh networks handling cross-cluster interactions (if utilizing the multi-cluster setup):
```bash
./k8s/istio/mesh-networks-patch.sh
```

Ensure Istio components have been effectively injected (`istioctl kube-inject` or namespace labels) and pods are running correctly throughout the mesh.

### 4. Handling Reboots (Cross-Cluster Restoration)
If your host machine restarts, IP dynamics might break the multi-cluster remote secrets or east/west gateways. Use the provided restoration script to dynamically patch gateway IPs, rebuild remote secrets, and restart `istiod` across clusters:

```bash
./k8s/kind/restart-clusters.sh
```

---

## 📈 Kiali Dashboard & Observability

One of the project's standout features is its tight integration with **Kiali**. By running the Istio mesh, Kiali gives you powerful visual insights into the service-to-service communication graph without any code changes required in the services themselves.

To access the Kiali dashboard and observe live traffic routing and mTLS enforcement:

```bash
istioctl dashboard kiali
```

### What to look for in Kiali:
- **Graph Topology:** Observe how the `api-gateway` routes traffic sequentially to `patient`, `auth`, `billing` and `analytics` services.
- **Traffic Animation & Metrics:** Check Request Rates (RPS) and latency directly on the edges connecting your microservice nodes.
- **Security Check:** Verify the padlock icon indicates mTLS is active between gRPC services (like Billing) and Kafka consumers.
- **Istio Configurations:** Quickly debug missing Gateway or VirtualService misconfigurations natively in the Kiali UI validations.

*(You can similarly run `istioctl dashboard grafana` or `istioctl dashboard jaeger` to dive deep into custom metrics and distributed trace spans.)*
