"""Adapters de features.

M2 entrega o registro e o estado `indisponivel` com motivo para features cujo
adapter real chega com a camada de aparência/acessibilidade. Nenhuma feature
reporta sucesso sem adapter.

Contrato de adapter:
- `effective(facts, session) -> dict {state, reason, params?}`
- `apply(facts, session, action) -> dict {status, ...}`  (status em
  ligado/desligado/ok)
- `verify(facts, session) -> bool`
- `rollback(facts, session, action) -> dict`
"""

from __future__ import annotations

from .models import FeatureSpec


class FeatureAdapter:
    """Base com estados honestos quando não há implementação real."""

    def effective(self, facts, session) -> dict:  # noqa: ARG002 - interface estável
        return {"state": "indisponivel", "reason": "adapter ainda não integrado"}

    def apply(self, facts, session, action) -> dict:  # noqa: ARG002
        return {"status": "failed", "error": "adapter ainda não integrado"}

    def verify(self, facts, session) -> bool:  # noqa: ARG002
        return False

    def rollback(self, facts, session, action) -> dict:  # noqa: ARG002
        return {"status": "ok"}


class _Registry:
    def __init__(self) -> None:
        self._adapters: dict[str, FeatureAdapter] = {}

    def register(self, feature_id: str, adapter: FeatureAdapter) -> None:
        self._adapters[feature_id] = adapter

    def get(self, feature_id: str) -> FeatureAdapter | None:
        return self._adapters.get(feature_id)


REGISTRY = _Registry()


def adapter_for(spec: FeatureSpec) -> FeatureAdapter | None:
    if spec.kind == "internal":
        return None
    return REGISTRY.get(spec.id)
