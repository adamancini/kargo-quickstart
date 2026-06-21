.PHONY: apply apply-argocd apply-kargo commit push pf pf-dev pf-staging pf-prod pf-soju pf-stop pf-status

## ── Apply ────────────────────────────────────────────────────────────────────

apply: apply-argocd apply-kargo

apply-argocd:
	akuity argocd apply -f akuity

apply-kargo:
	kargo apply -f kargo
	kargo apply -f kargo/akkoma
	kargo apply -f kargo/soju

## ── Git ──────────────────────────────────────────────────────────────────────

MSG ?= chore: update configuration

commit:
	git add -A
	git commit -m "$(MSG)"

push:
	git push

sync: apply commit push

## ── Port forwarding ──────────────────────────────────────────────────────────

# Port assignments
# akkoma-dev      → :4000
# akkoma-staging  → :4001
# akkoma-prod     → :4002
# soju gamja      → :8080 (web IRC client)

# Exclude postgres pods via label selector
AKKOMA_POD = $(shell kubectl get pod -n akkoma-$(1) \
	-l 'app.kubernetes.io/name=akkoma,app.kubernetes.io/component!=database' \
	-o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

pf: pf-dev pf-staging pf-prod pf-soju
	@echo ""
	@echo "Port forwards active:"
	@echo "  akkoma dev     → http://localhost:4000"
	@echo "  akkoma staging → http://localhost:4001"
	@echo "  akkoma prod    → http://localhost:4002"
	@echo "  soju (gamja)   → http://localhost:8080"

pf-dev:
	@POD=$(call AKKOMA_POD,dev); \
	if [ -z "$$POD" ]; then echo "akkoma-dev pod not found"; exit 1; fi; \
	echo "Forwarding akkoma-dev ($$POD) → localhost:4000"; \
	kubectl port-forward -n akkoma-dev pod/$$POD 4000:4000 >/dev/null 2>&1 &

pf-staging:
	@POD=$(call AKKOMA_POD,staging); \
	if [ -z "$$POD" ]; then echo "akkoma-staging pod not found"; exit 1; fi; \
	echo "Forwarding akkoma-staging ($$POD) → localhost:4001"; \
	kubectl port-forward -n akkoma-staging pod/$$POD 4001:4000 >/dev/null 2>&1 &

pf-prod:
	@POD=$(call AKKOMA_POD,prod); \
	if [ -z "$$POD" ]; then echo "akkoma-prod pod not found"; exit 1; fi; \
	echo "Forwarding akkoma-prod ($$POD) → localhost:4002"; \
	kubectl port-forward -n akkoma-prod pod/$$POD 4002:4000 >/dev/null 2>&1 &

pf-soju:
	@echo "Forwarding soju-dev gamja → localhost:8080"; \
	kubectl port-forward -n soju-dev svc/soju-dev-gamja 8080:80 >/dev/null 2>&1 &

pf-stop:
	@echo "Stopping all port forwards..."
	@pkill -f "kubectl port-forward" 2>/dev/null || true
	@echo "Done."

pf-status:
	@echo "Active port forwards:"
	@pgrep -a -f "kubectl port-forward" 2>/dev/null || echo "  none"
