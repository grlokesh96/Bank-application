# Kubernetes Microservices

Each microservice has its own manifest file under `k8s/services/`.

## Structure
- `k8s/services/<service-name>.yaml` — contains Deployment + Service for that microservice

## Benefits
- Easier to review and maintain individual services
- Clear ownership per microservice
- Simpler CI/CD per-service updates

All 30 services were extracted from the previous single `20-services.yaml` file.

