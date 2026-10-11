"""Shared lock for config read-check-write operations across HTTP and RPC."""

from threading import RLock

CONFIG_MUTATION_LOCK = RLock()
