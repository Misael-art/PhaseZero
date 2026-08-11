"""Temas e acessibilidade para Plasma 6 — contratos transacionais.

O contrato público é JSON e versionado (`themes/v1`). Nenhuma operação muta o
desktop sem plano, confirmação, verificação e rollback. Toda chave representa
estado real lido antes e verificado depois.
"""

SCHEMA = "themes/v1"

STATES = (
    "ligado",
    "desligado",
    "aplicando",
    "pausado-bateria",
    "pausado-jogo",
    "reinicio-pendente",
    "indisponivel",
    "degradado",
)

FEATURE_STATE_ORDER = {name: index for index, name in enumerate(STATES)}
