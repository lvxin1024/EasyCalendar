"""Application-layer errors independent of HTTP and concrete storage."""


class ApplicationError(RuntimeError):
    """Base error for use-case failures safe to expose through adapters."""


class InvalidCommandError(ApplicationError):
    """Raised when a command violates domain or use-case rules."""


class ItemNotFoundError(ApplicationError):
    """Raised when an Item is absent or hidden by its lifecycle state."""


class CollectionNotFoundError(ApplicationError):
    """Raised when a command targets an unavailable Collection."""


class ReadonlyCollectionError(ApplicationError):
    """Raised when a local edit targets externally owned data."""


class IdempotencyConflictError(ApplicationError):
    """Raised when an idempotency key is reused for a different command."""


class InvalidCursorError(ApplicationError):
    """Raised when a list cursor is malformed or unsupported."""
