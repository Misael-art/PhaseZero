"""Dependências opcionais do PhaseZero: diagnóstico e instalação assistida."""
from .engine import SCHEMA, DepsError, distro_family, install, inspect, status

__all__ = ["SCHEMA", "DepsError", "distro_family", "install", "inspect", "status"]
