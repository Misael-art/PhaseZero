"""Declarative capability management for PhaseZero Linux.

The public contract is JSON and versioned.  Package managers and Flatpak are
the only executable source kinds; arbitrary remote shell installers are
intentionally rejected.
"""

SCHEMA = "pz.capabilities/v1"

